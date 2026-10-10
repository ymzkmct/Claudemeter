import AppKit
import Combine
import SwiftUI

struct MenuContentView: View {
    @Bindable var store: UsageStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    @State private var now = Date()

    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let snapshot = store.snapshot {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshot.windows) { window in
                        WindowRow(window: window, now: now)
                    }
                    if let extra = snapshot.extraUsage, extra.isEnabled {
                        ExtraUsageRow(extra: extra)
                    }
                }
            } else {
                Text(store.status == .refreshing ? "取得中…" : "まだデータがありません")
                    .foregroundStyle(.secondary)
            }
            statusLines
            Divider()
            controls
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { store.refresh(reason: .menuOpened) }
        .onReceive(clock) { now = $0 }
    }

    private var header: some View {
        HStack {
            Text("Claude 利用状況").font(.headline)
            Spacer()
            if let plan = store.planLabel {
                Text(plan)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        }
    }

    @ViewBuilder
    private var statusLines: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if store.status == .refreshing {
                    ProgressView().controlSize(.mini)
                }
                Text(lastUpdatedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if store.needsReauth {
                Text("再ログインが必要です。ターミナルで `claude` を実行してログインしてください。")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let error = store.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            if let warning = store.writeBackWarning {
                Text(warning).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            if let launchAtLoginError {
                Text(launchAtLoginError).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }

    private var lastUpdatedText: String {
        guard let fetched = store.snapshot?.fetchedAt else { return "最終更新: なし" }
        let age = now.timeIntervalSince(fetched)
        let suffix = store.isStale ? "（古いデータ）" : ""
        return "最終更新: \(TimeText.ago(age))\(suffix)"
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("今すぐ更新") { store.refresh(reason: .manual) }
                    .disabled(store.status == .refreshing)
                Spacer()
                Picker("更新間隔", selection: $store.pollInterval) {
                    ForEach(UsageStore.pollIntervalOptions, id: \.self) { seconds in
                        Text(TimeText.interval(seconds)).tag(seconds)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            Toggle("ログイン時に起動", isOn: $launchAtLogin)
                .disabled(!LaunchAtLogin.isAvailable)
                .onChange(of: launchAtLogin) { _, enabled in
                    guard enabled != LaunchAtLogin.isEnabled else { return }
                    do {
                        try LaunchAtLogin.setEnabled(enabled)
                        launchAtLoginError = nil
                    } catch {
                        launchAtLoginError = "ログイン時起動の設定に失敗: \(error.localizedDescription)"
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                }
            HStack {
                Spacer()
                Button("終了") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
    }
}

private struct WindowRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title)
                Spacer()
                Text(window.percentText).monospacedDigit().bold()
            }
            ProgressView(value: min(window.utilization, 100), total: 100)
                .tint(tint)
            if let resetsAt = window.resetsAt {
                Text("リセット: \(TimeText.remaining(until: resetsAt, from: now)) 後（\(TimeText.clock(resetsAt))）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tint: Color {
        switch window.utilization {
        case ..<50: return .green
        case ..<80: return .yellow
        default: return .red
        }
    }
}

private struct ExtraUsageRow: View {
    let extra: ExtraUsage

    var body: some View {
        HStack {
            Text("追加利用")
            Spacer()
            Text(amountText).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var amountText: String {
        let currency = extra.currency ?? ""
        let used = extra.usedCredits.map { String(format: "%.2f", $0) } ?? "–"
        if let limit = extra.monthlyLimit {
            return "\(used) / \(String(format: "%.0f", limit)) \(currency)"
        }
        return "\(used) \(currency)"
    }
}

enum TimeText {
    static func remaining(until date: Date, from now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)日\(hours)時間" }
        if hours > 0 { return "\(hours)時間\(minutes)分" }
        return "\(minutes)分"
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)秒前" }
        if s < 3_600 { return "\(s / 60)分前" }
        if s < 86_400 { return "\(s / 3_600)時間前" }
        return "\(s / 86_400)日前"
    }

    static func interval(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds))秒" : "\(Int(seconds / 60))分"
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: date)
    }
}
