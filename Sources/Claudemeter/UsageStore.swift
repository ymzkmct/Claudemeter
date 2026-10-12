import AppKit
import Foundation
import Observation
import os

/// Owns the usage snapshot and decides when to re-fetch:
/// periodic timer, session-transcript activity, wake from sleep, menu open, manual.
@MainActor
@Observable
final class UsageStore {
    enum RefreshReason: String {
        case startup, timer, sessionActivity, wake, menuOpened, manual
    }

    enum Status: Equatable {
        case idle
        case refreshing
        case ok
        case error(String)
    }

    static let minimumFetchInterval: TimeInterval = 15
    static let activityDebounce: TimeInterval = 3
    static let pollIntervalOptions: [TimeInterval] = [30, 60, 300]
    static let warningThreshold: Double = 80
    /// After a failed Keychain read (typically a dismissed dialog) wait this long before trying again.
    static let keychainRetryInterval: TimeInterval = 300

    private(set) var snapshot: UsageSnapshot?
    private(set) var status: Status = .idle
    private(set) var planLabel: String?
    private(set) var needsReauth = false
    private(set) var writeBackWarning: String?
    private(set) var lastRefreshReason: RefreshReason?
    private(set) var nextAllowedFetch: Date = .distantPast
    var pollInterval: TimeInterval {
        didSet {
            defaults.set(pollInterval, forKey: Keys.pollInterval)
            restartTimer()
        }
    }

    private let defaults: UserDefaults
    private let keychain = KeychainCredentialStore()
    private let client = UsageClient()
    private let refresher = TokenRefresher()
    private let log = Logger(subsystem: "jp.ymzkmct.Claudemeter", category: "usage")

    private var watcher: SessionLogWatcher?
    private var timerTask: Task<Void, Never>?
    private var pendingTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    /// A refresh requested while one was in flight; run once the current fetch finishes.
    private var queuedReason: RefreshReason?
    private var lastFetchStarted: Date = .distantPast
    private var wakeObserver: NSObjectProtocol?
    /// Hash of the Keychain payload whose refresh token was rejected; no retry until the payload changes.
    private var rejectedCredentialHash: Int?

    private enum Keys {
        static let snapshot = "cachedSnapshot"
        static let pollInterval = "pollInterval"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Keys.pollInterval)
        self.pollInterval = Self.pollIntervalOptions.contains(stored) ? stored : 60
        if let data = defaults.data(forKey: Keys.snapshot),
           let cached = try? JSONDecoder().decode(UsageSnapshot.self, from: data) {
            self.snapshot = cached
        }
    }

    // MARK: - Lifecycle

    func start() {
        refresh(reason: .startup)
        restartTimer()

        let watcher = SessionLogWatcher { [weak self] in
            Task { @MainActor in self?.sessionActivityDetected() }
        }
        watcher.start()
        self.watcher = watcher
        log.info("session log watcher running=\(watcher.isRunning)")

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                self?.refresh(reason: .wake)
            }
        }
    }

    private func restartTimer() {
        timerTask?.cancel()
        let interval = pollInterval
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self?.refresh(reason: .timer)
            }
        }
    }

    private func sessionActivityDetected() {
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.activityDebounce))
            guard !Task.isCancelled else { return }
            self?.refresh(reason: .sessionActivity)
        }
    }

    // MARK: - Refresh

    func refresh(reason: RefreshReason) {
        guard inFlight == nil else {
            queuedReason = reason == .manual ? .manual : (queuedReason ?? reason)
            return
        }

        let now = Date()
        var wait: TimeInterval = max(0, nextAllowedFetch.timeIntervalSince(now))
        if reason != .manual {
            wait = max(wait, Self.minimumFetchInterval - now.timeIntervalSince(lastFetchStarted))
        }
        if wait > 0 {
            // Too soon: coalesce into a single deferred fetch.
            pendingTask?.cancel()
            pendingTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.refresh(reason: reason)
            }
            return
        }

        lastFetchStarted = now
        lastRefreshReason = reason
        status = .refreshing
        inFlight = Task { [weak self] in
            await self?.performRefresh(reason: reason)
            guard let self else { return }
            self.inFlight = nil
            if let queued = self.queuedReason {
                self.queuedReason = nil
                self.refresh(reason: queued)
            }
        }
    }

    private func performRefresh(reason: RefreshReason) async {
        log.info("refresh start reason=\(reason.rawValue, privacy: .public)")
        do {
            let item = try await keychain.readItem()
            var credentials = try CredentialsJSON.parse(item.data)
            planLabel = credentials.planLabel

            var refreshedThisCycle = false
            if credentials.isExpired() {
                credentials = try await refreshCredentials(item: item, credentials: credentials)
                refreshedThisCycle = true
            }

            let response: UsageClient.Response
            do {
                response = try await client.fetch(accessToken: credentials.accessToken)
            } catch UsageClient.Error.unauthorized where !refreshedThisCycle {
                // Token was rejected although not expired by our clock: refresh once and retry.
                // (Re-read the Keychain in case `claude` rotated the token meanwhile.)
                let latest = try await keychain.readItem()
                let latestCredentials = try CredentialsJSON.parse(latest.data)
                let refreshed = try await refreshCredentials(item: latest, credentials: latestCredentials)
                response = try await client.fetch(accessToken: refreshed.accessToken)
            }

            apply(response.snapshot)
            needsReauth = false
            status = .ok
            log.info("refresh ok windows=\(response.snapshot.windows.count)")
        } catch UsageClient.Error.rateLimited(let retryAfter) {
            nextAllowedFetch = retryAfter ?? Date(timeIntervalSinceNow: 300)
            status = .error(UsageClient.Error.rateLimited(retryAfter: retryAfter).localizedDescription)
            log.error("refresh rate limited until \(self.nextAllowedFetch)")
        } catch let error as CredentialsError where error.isKeychainAccessFailure {
            // Most likely a Keychain dialog the user dismissed: wait before raising it again.
            nextAllowedFetch = Date(timeIntervalSinceNow: Self.keychainRetryInterval)
            status = .error(error.localizedDescription)
            log.error("keychain access failed, next attempt at \(self.nextAllowedFetch): \(error.localizedDescription)")
        } catch {
            status = .error(error.localizedDescription)
            log.error("refresh failed: \(error.localizedDescription)")
        }
    }

    private func refreshCredentials(item: KeychainItem, credentials: ClaudeCredentials) async throws -> ClaudeCredentials {
        let raw = item.data
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            needsReauth = true
            throw CredentialsError.reauthRequired("refreshToken がありません")
        }
        if credentials.isRefreshTokenExpired() {
            needsReauth = true
            throw CredentialsError.reauthRequired("refresh token の期限切れ")
        }
        if rejectedCredentialHash == raw.hashValue {
            needsReauth = true
            throw CredentialsError.reauthRequired("前回のトークン更新が拒否されました")
        }

        let result: TokenRefresher.Result
        do {
            result = try await refresher.refresh(refreshToken: refreshToken)
        } catch TokenRefresher.Error.rejected(let status, let code) {
            rejectedCredentialHash = raw.hashValue
            needsReauth = true
            throw CredentialsError.reauthRequired("HTTP \(status)\(code.map { " \($0)" } ?? "")")
        }

        var updated = credentials
        updated.accessToken = result.accessToken
        updated.expiresAt = result.expiresAt
        if let newRefresh = result.refreshToken, !newRefresh.isEmpty, newRefresh != credentials.refreshToken {
            // Rotated: the stored expiry belonged to the old refresh token.
            updated.refreshToken = newRefresh
            updated.refreshTokenExpiresAt = nil
        }

        // Write back so the `claude` CLI keeps working even if the refresh token rotated.
        do {
            let merged = try CredentialsJSON.merge(
                into: raw,
                accessToken: result.accessToken,
                refreshToken: result.refreshToken,
                expiresAt: result.expiresAt)
            try await keychain.write(merged, to: item)
            writeBackWarning = nil
            log.info("token refreshed and written back to keychain")
        } catch {
            writeBackWarning = "更新したトークンを Keychain に書き戻せませんでした: \(error.localizedDescription)"
            log.error("keychain write-back failed: \(error.localizedDescription)")
        }
        return updated
    }

    private func apply(_ snapshot: UsageSnapshot) {
        self.snapshot = snapshot
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Keys.snapshot)
        }
    }

    // MARK: - Presentation helpers

    var isStale: Bool {
        if case .error = status { return true }
        return false
    }

    var errorMessage: String? {
        if case .error(let message) = status { return message }
        return nil
    }

    var showsWarning: Bool {
        guard let snapshot else { return needsReauth || isStale }
        return snapshot.maxUtilization >= Self.warningThreshold || needsReauth
    }

    /// Always shown first in the menu bar so this app is distinguishable from
    /// sibling meters (e.g. a Codex one) that use the same layout.
    static let menuBarPrefix = "Claude"

    /// Text shown next to the menu bar icon, e.g. "Claude 5h 8% · 7d 41%".
    var menuBarTitle: String {
        guard let snapshot else {
            return "\(Self.menuBarPrefix) \(status == .refreshing ? "…" : "–")"
        }
        var parts: [String] = []
        if let five = snapshot.fiveHour { parts.append("5h \(five.percentText)") }
        if let week = snapshot.sevenDay { parts.append("7d \(week.percentText)") }
        if parts.isEmpty, let first = snapshot.windows.first {
            parts.append("\(first.shortLabel) \(first.percentText)")
        }
        return "\(Self.menuBarPrefix) " + parts.joined(separator: " · ")
    }
}
