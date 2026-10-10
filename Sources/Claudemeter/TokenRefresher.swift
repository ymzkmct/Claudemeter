import Foundation

/// Exchanges the stored refresh token for a new access token (OAuth refresh_token grant).
struct TokenRefresher {
    static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Public OAuth client id used by Claude Code (same value CodexBar uses as its default).
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    struct Result: Equatable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
    }

    enum Error: LocalizedError {
        /// The refresh token was rejected (invalid_grant etc.). Retrying with the same token is pointless.
        case rejected(status: Int, code: String?)
        case http(status: Int, body: String)
        case network(Swift.Error)
        case malformed

        var errorDescription: String? {
            switch self {
            case .rejected(let status, let code):
                return "トークン更新が拒否されました (HTTP \(status)\(code.map { ", \($0)" } ?? ""))"
            case .http(let status, _):
                return "トークン更新に失敗しました (HTTP \(status))"
            case .network(let error):
                return "トークン更新の通信エラー: \(error.localizedDescription)"
            case .malformed:
                return "トークン更新レスポンスを解釈できません"
            }
        }
    }

    var session: URLSession = SecureSession.shared

    func refresh(refreshToken: String) async throws -> Result {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formBody([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", Self.clientID),
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Error.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw Error.malformed }

        switch http.statusCode {
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
                throw Error.malformed
            }
            let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
            return Result(
                accessToken: accessToken,
                refreshToken: json["refresh_token"] as? String,
                expiresAt: Date(timeIntervalSinceNow: expiresIn))
        case 400, 401, 403:
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Error.rejected(status: http.statusCode, code: code)
        default:
            throw Error.http(status: http.statusCode, body: "")
        }
    }

    static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        return Data(encoded.joined(separator: "&").utf8)
    }
}
