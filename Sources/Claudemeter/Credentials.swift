import Foundation

/// The `claudeAiOauth` section of the Claude Code Keychain item.
struct ClaudeCredentials: Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var refreshTokenExpiresAt: Date?
    var subscriptionType: String?
    var rateLimitTier: String?
    var scopes: [String]

    func isExpired(at now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < leeway
    }

    func isRefreshTokenExpired(at now: Date = Date()) -> Bool {
        guard let refreshTokenExpiresAt else { return false }
        return refreshTokenExpiresAt <= now
    }

    /// "Max 20x", "Max", "Pro", ... derived from `rateLimitTier` / `subscriptionType`.
    var planLabel: String? {
        let base = subscriptionType.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        if let tier = rateLimitTier,
           let range = tier.range(of: #"max_(\d+)x"#, options: .regularExpression) {
            let multiplier = tier[range].dropFirst("max_".count)
            return "Max \(multiplier)"
        }
        return base
    }
}

enum CredentialsError: LocalizedError {
    case notFound
    case keychain(String)
    case malformed(String)
    case reauthRequired(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Keychain に「Claude Code-credentials」がありません。`claude` でログインしてください"
        case .keychain(let message):
            return "Keychain エラー: \(message)"
        case .malformed(let detail):
            return "認証情報の形式が想定外です: \(detail)"
        case .reauthRequired(let detail):
            return "再ログインが必要です（\(detail)）。ターミナルで `claude` を実行してください"
        }
    }

    /// True when `security` itself failed (access denied, locked keychain, ...), as opposed to a missing or malformed item.
    var isKeychainAccessFailure: Bool {
        if case .keychain = self { return true }
        return false
    }
}

/// Pure JSON handling for the Keychain item payload. Kept free of Security.framework for testability.
enum CredentialsJSON {
    static let rootKey = "claudeAiOauth"

    static func parse(_ data: Data) throws -> ClaudeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialsError.malformed("JSON オブジェクトではありません")
        }
        guard let oauth = root[rootKey] as? [String: Any] else {
            throw CredentialsError.malformed("\(rootKey) がありません")
        }
        guard let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else {
            throw CredentialsError.malformed("accessToken がありません")
        }
        return ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: epochMillis(oauth["expiresAt"]),
            refreshTokenExpiresAt: epochMillis(oauth["refreshTokenExpiresAt"]),
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String,
            scopes: (oauth["scopes"] as? [String]) ?? [])
    }

    /// Returns `original` with only the token fields replaced; every other key is preserved verbatim.
    /// When the refresh token rotated, the old `refreshTokenExpiresAt` no longer describes a real token and is dropped.
    static func merge(into original: Data, accessToken: String, refreshToken: String?, expiresAt: Date) throws -> Data {
        guard var root = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
              var oauth = root[rootKey] as? [String: Any] else {
            throw CredentialsError.malformed("書き戻し対象の JSON を読めません")
        }
        oauth["accessToken"] = accessToken
        if let refreshToken, !refreshToken.isEmpty {
            if (oauth["refreshToken"] as? String) != refreshToken {
                oauth.removeValue(forKey: "refreshTokenExpiresAt")
            }
            oauth["refreshToken"] = refreshToken
        }
        oauth["expiresAt"] = Int64((expiresAt.timeIntervalSince1970 * 1000).rounded())
        root[rootKey] = oauth
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func epochMillis(_ value: Any?) -> Date? {
        let millis: Double?
        switch value {
        case let d as Double: millis = d
        case let i as Int: millis = Double(i)
        case let n as NSNumber: millis = n.doubleValue
        default: millis = nil
        }
        guard let millis, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}

/// The raw Keychain payload plus the attribute needed to address that exact item again.
struct KeychainItem: Equatable {
    let data: Data
    let account: String?
}

/// Reads and updates the generic-password item that Claude Code writes on login.
///
/// Every access goes through `/usr/bin/security`, the Apple-signed tool the `claude` CLI itself uses for this
/// item, so the Keychain always sees one and the same code identity touching it. Modifying the item from this
/// app's own signature (`SecItemUpdate`) rewrites the item's partition list to this app alone; from then on every
/// `security` call Claude Code makes raises a "security wants to access ... enter the login keychain password"
/// dialog (anthropics/claude-code#62213 describes the mechanism). As a side effect no "Always Allow" grant is
/// tied to this app's signature, so rebuilding an ad-hoc signed app does not prompt again.
struct KeychainCredentialStore {
    static let service = "Claude Code-credentials"
    static let defaultTool = "/usr/bin/security"
    /// `security` exits with the low byte of the OSStatus: errSecItemNotFound (-25300) becomes 44.
    static let notFoundExitStatus: Int32 = 44

    /// Executable to run; tests point it at a stub to exercise failure handling.
    var tool = defaultTool
    /// Keychain file to operate on; nil means the default search list (the login keychain). Tests use a scratch file.
    /// Must exist: `security` silently falls back to the default keychain when the file is missing.
    var keychainPath: String? = nil

    func readItem() async throws -> KeychainItem {
        // Attribute lookup does not decrypt anything, so it never prompts; it tells us which account the item has.
        let attributes = try await run(["find-generic-password", "-s", Self.service])
        let account = Self.account(fromAttributes: attributes)
        var arguments = ["find-generic-password", "-s", Self.service, "-w"]
        if let account { arguments += ["-a", account] }
        let secret = try await run(arguments)
        return KeychainItem(data: Self.secret(fromOutput: secret), account: account)
    }

    /// Updates only the item that `readItem()` returned (matched by account), never every item of the service.
    func write(_ data: Data, to item: KeychainItem) async throws {
        guard let account = item.account else {
            throw CredentialsError.malformed("Keychain 項目に account がありません")
        }
        guard let secret = String(data: data, encoding: .utf8) else {
            throw CredentialsError.malformed("書き戻すデータが UTF-8 ではありません")
        }
        _ = try await run(["add-generic-password", "-U", "-a", account, "-s", Self.service, "-w", secret])
    }

    // MARK: - Output parsing (pure, unit-tested)

    /// Extracts the account from `find-generic-password` attribute output, e.g.
    /// `    "acct"<blob>="user"` or `    "acct"<blob>=0x7573... "user"`; `<NULL>` and absence yield nil.
    static func account(fromAttributes output: Data) -> String? {
        let prefix = "\"acct\"<blob>="
        for rawLine in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else { continue }
            let value = line.dropFirst(prefix.count)
            if value.hasPrefix("0x") {
                let hex = value.dropFirst(2).prefix { $0.isHexDigit }
                return Self.data(fromHex: hex).flatMap { String(data: $0, encoding: .utf8) }
            }
            guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
            return String(value.dropFirst().dropLast())
        }
        return nil
    }

    /// `find-generic-password -w` prints the secret followed by one newline: verbatim when it is printable ASCII,
    /// otherwise as a bare hex string (no `0x`). A JSON payload can never be all hex digits, so the two are
    /// distinguishable.
    static func secret(fromOutput output: Data) -> Data {
        let body = output.last == UInt8(ascii: "\n") ? output.dropLast() : output
        let text = String(decoding: body, as: UTF8.self)
        guard !text.isEmpty, text.count % 2 == 0, text.allSatisfy(\.isHexDigit),
              let decoded = data(fromHex: Substring(text)) else {
            return Data(body)
        }
        return decoded
    }

    /// First line of `security`'s stderr without the `security: ` prefix, or the exit status if it said nothing.
    static func errorMessage(stderr: String, status: Int32) -> String {
        let line = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        guard var message = line else { return "security が終了コード \(status) で失敗しました" }
        if message.hasPrefix("security: ") { message.removeFirst("security: ".count) }
        return message
    }

    private static func data(fromHex hex: Substring) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    // MARK: - Process

    private struct Outcome {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    /// Runs `security` off the main thread (a Keychain dialog can keep it waiting for minutes) and maps its exit
    /// status: 0 → stdout, 44 → `.notFound`, anything else → `.keychain(message)`.
    private func run(_ arguments: [String]) async throws -> Data {
        var arguments = arguments
        if let keychainPath { arguments.append(keychainPath) }
        let outcome: Outcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Outcome(status: -1, stdout: Data(), stderr: error.localizedDescription))
                    return
                }
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Outcome(
                    status: process.terminationStatus, stdout: out, stderr: String(decoding: err, as: UTF8.self)))
            }
        }
        switch outcome.status {
        case 0:
            return outcome.stdout
        case Self.notFoundExitStatus:
            throw CredentialsError.notFound
        default:
            throw CredentialsError.keychain(Self.errorMessage(stderr: outcome.stderr, status: outcome.status))
        }
    }
}
