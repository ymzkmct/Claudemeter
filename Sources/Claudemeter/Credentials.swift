import Foundation
import Security

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
    case keychain(OSStatus)
    case malformed(String)
    case reauthRequired(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Keychain に「Claude Code-credentials」がありません。`claude` でログインしてください"
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain エラー: \(message)"
        case .malformed(let detail):
            return "認証情報の形式が想定外です: \(detail)"
        case .reauthRequired(let detail):
            return "再ログインが必要です（\(detail)）。ターミナルで `claude` を実行してください"
        }
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
struct KeychainCredentialStore {
    static let service = "Claude Code-credentials"

    private func query(account: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    func readItem() throws -> KeychainItem {
        var q = query(account: nil)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let dict = result as? [String: Any], let data = dict[kSecValueData as String] as? Data else {
                throw CredentialsError.malformed("Keychain の値を読めません")
            }
            return KeychainItem(data: data, account: dict[kSecAttrAccount as String] as? String)
        case errSecItemNotFound:
            throw CredentialsError.notFound
        default:
            throw CredentialsError.keychain(status)
        }
    }

    /// Updates only the item that `readItem()` returned (matched by account), never every item of the service.
    func write(_ data: Data, to item: KeychainItem) throws {
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(account: item.account) as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else { throw CredentialsError.keychain(status) }
    }
}
