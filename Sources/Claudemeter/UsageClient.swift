import Foundation

/// Calls the OAuth usage endpoint that backs `/usage` in Claude Code.
struct UsageClient {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"

    enum Error: LocalizedError {
        case unauthorized(String)
        case rateLimited(retryAfter: Date?)
        case http(status: Int, body: String)
        case network(Swift.Error)
        case decoding(Swift.Error)

        var errorDescription: String? {
            switch self {
            case .unauthorized(let message):
                return "認証エラー: \(message)"
            case .rateLimited:
                return "利用状況 API がレート制限中です。しばらく待って再試行します"
            case .http(let status, let body):
                return "利用状況 API エラー (HTTP \(status)) \(body.prefix(200))"
            case .network(let error):
                return "通信エラー: \(error.localizedDescription)"
            case .decoding(let error):
                return error.localizedDescription
            }
        }
    }

    struct Response {
        let snapshot: UsageSnapshot
        let raw: Data
    }

    var session: URLSession = SecureSession.shared

    func fetch(accessToken: String) async throws -> Response {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Error.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Error.http(status: -1, body: "HTTP 応答ではありません")
        }

        switch http.statusCode {
        case 200:
            do {
                return Response(snapshot: try UsageResponseParser.parse(data), raw: data)
            } catch {
                throw Error.decoding(error)
            }
        case 401:
            throw Error.unauthorized(Self.errorMessage(in: data) ?? "HTTP 401")
        case 429:
            throw Error.rateLimited(retryAfter: Self.retryAfter(http))
        default:
            throw Error.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }

    private static func errorMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) {
            return Date(timeIntervalSinceNow: seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}
