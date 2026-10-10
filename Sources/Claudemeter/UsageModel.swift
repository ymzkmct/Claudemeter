import Foundation

/// One rate-limit window as shown in the menu (5-hour, weekly, per-model weekly, ...).
struct UsageWindow: Equatable, Identifiable, Codable {
    /// Stable key: "five_hour", "seven_day", "seven_day_<x>", or "limit:<model id>".
    let id: String
    /// Full title for the dropdown, e.g. "Weekly · All models".
    let title: String
    /// Short label for the menu bar, e.g. "5h", "7d", "Fable".
    let shortLabel: String
    /// Percent used, 0...100 (may exceed 100 when over the limit).
    let utilization: Double
    let resetsAt: Date?

    var percentText: String { "\(Int(utilization.rounded()))%" }
}

struct ExtraUsage: Equatable, Codable {
    let isEnabled: Bool
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?
}

struct UsageSnapshot: Equatable, Codable {
    let windows: [UsageWindow]
    let extraUsage: ExtraUsage?
    let fetchedAt: Date

    var fiveHour: UsageWindow? { windows.first { $0.id == "five_hour" } }
    var sevenDay: UsageWindow? { windows.first { $0.id == "seven_day" } }
    var maxUtilization: Double { windows.map(\.utilization).max() ?? 0 }
}

enum UsageParseError: LocalizedError {
    case notAnObject
    case missingWindows

    var errorDescription: String? {
        switch self {
        case .notAnObject: return "利用状況レスポンスが JSON オブジェクトではありません"
        case .missingWindows: return "利用状況レスポンスに five_hour / seven_day がありません"
        }
    }
}

/// Parses the `GET /api/oauth/usage` response body.
///
/// Known shape (from the CodexBar implementation; to be confirmed against a real dump):
/// - `five_hour`, `seven_day`, `seven_day_<model>`: `{ "utilization": 0...100, "resets_at": ISO8601 }`
/// - `limits`: `[ { "kind": "weekly_scoped", "group": "weekly", "percent", "resets_at",
///              "scope": { "model": { "id", "display_name" } } } ]`
/// - `extra_usage`: `{ "is_enabled", "monthly_limit", "used_credits", "utilization", "currency" }`
enum UsageResponseParser {
    static func parse(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageParseError.notAnObject
        }

        var windows: [UsageWindow] = []

        if let w = window(from: root["five_hour"], id: "five_hour", title: "5時間枠", short: "5h") {
            windows.append(w)
        }
        if let w = window(from: root["seven_day"], id: "seven_day", title: "週次 · 全モデル", short: "7d") {
            windows.append(w)
        }

        // Model-scoped weekly windows published as top-level `seven_day_<name>` keys.
        var others: [UsageWindow] = []
        for key in root.keys.sorted() where key.hasPrefix("seven_day_") {
            let name = humanize(String(key.dropFirst("seven_day_".count)))
            if let w = window(from: root[key], id: key, title: "週次 · \(name)", short: name) {
                others.append(w)
            }
        }

        // Model-scoped weekly windows from `limits[]`.
        if let limits = root["limits"] as? [[String: Any]] {
            for entry in limits {
                guard (entry["kind"] as? String) == "weekly_scoped" else { continue }
                guard let percent = number(entry["percent"]), percent.isFinite else { continue }
                let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
                let modelID = (model?["id"] as? String) ?? ""
                let display = (model?["display_name"] as? String) ?? modelID
                guard !display.isEmpty, !isAllModels(id: modelID, name: display) else { continue }
                // Skip when a `seven_day_<x>` key already covers the same model.
                guard !others.contains(where: { $0.shortLabel.caseInsensitiveCompare(display) == .orderedSame }) else { continue }
                others.append(UsageWindow(
                    id: "limit:" + (modelID.isEmpty ? display : modelID),
                    title: "週次 · \(display)",
                    shortLabel: display,
                    utilization: percent,
                    resetsAt: date(entry["resets_at"])))
            }
        }
        windows.append(contentsOf: others.sorted { $0.title < $1.title })

        guard !windows.isEmpty else { throw UsageParseError.missingWindows }

        var extra: ExtraUsage?
        if let e = root["extra_usage"] as? [String: Any] {
            extra = ExtraUsage(
                isEnabled: (e["is_enabled"] as? Bool) ?? false,
                monthlyLimit: number(e["monthly_limit"]),
                usedCredits: number(e["used_credits"]),
                utilization: number(e["utilization"]),
                currency: e["currency"] as? String)
        }

        return UsageSnapshot(windows: windows, extraUsage: extra, fetchedAt: fetchedAt)
    }

    // MARK: - Helpers

    private static func window(from value: Any?, id: String, title: String, short: String) -> UsageWindow? {
        guard let dict = value as? [String: Any], let util = number(dict["utilization"]), util.isFinite else { return nil }
        return UsageWindow(id: id, title: title, shortLabel: short, utilization: util, resetsAt: date(dict["resets_at"]))
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ value: Any?) -> Date? {
        if let s = value as? String {
            return isoFractional.date(from: s) ?? isoPlain.date(from: s)
        }
        if let n = number(value) {
            // Epoch seconds (or milliseconds when implausibly large).
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        return nil
    }

    private static func humanize(_ raw: String) -> String {
        raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func isAllModels(id: String, name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("all models") || n == "all" || id.lowercased() == "all"
    }
}
