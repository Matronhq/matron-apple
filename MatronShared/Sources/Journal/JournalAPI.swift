import Foundation

public struct LoginResponse: Equatable, Sendable {
    public let token: String
    public let deviceID: Int64
    public let userID: Int64
}

public struct SnapshotResponse: Equatable, Sendable {
    public let conversations: [ConvoSummaryDTO]
    public let seq: Int64
}

public enum JournalAPIError: Error, Equatable, Sendable {
    case badCredentials
    case lockedOut(retryAfterSeconds: Int)
    case rateLimited
    case unauthenticated
    case forbidden
    case notFound
    case http(status: Int, message: String)
    case transport(String)
}

/// Thin HTTP surface of the journal server: login, snapshot, pagination,
/// plus the dormant media/APNs endpoints (spec'd; server lands them in
/// v1-completion — callers must tolerate `.notFound` until then).
public actor JournalAPI {
    public nonisolated let serverURL: URL
    private let urlSession: URLSession
    private var token: String?

    public init(serverURL: URL, urlSession: URLSession = .shared) {
        self.serverURL = serverURL
        self.urlSession = urlSession
    }

    public nonisolated var wsURL: URL {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/ws"
        return components.url!
    }

    public func setToken(_ token: String?) {
        self.token = token
    }

    public func login(username: String, password: String, deviceName: String) async throws -> LoginResponse {
        let body = ["username": username, "password": password, "device_name": deviceName]
        let obj = try await request(path: "/login", method: "POST", body: body, authenticated: false)
        guard let token = obj["token"] as? String,
              let deviceID = (obj["device_id"] as? NSNumber)?.int64Value,
              let userID = (obj["user_id"] as? NSNumber)?.int64Value
        else { throw JournalAPIError.transport("malformed login response") }
        self.token = token
        return LoginResponse(token: token, deviceID: deviceID, userID: userID)
    }

    public func snapshot() async throws -> SnapshotResponse {
        let obj = try await request(path: "/snapshot")
        let conversations = (obj["conversations"] as? [[String: Any]] ?? []).compactMap { c -> ConvoSummaryDTO? in
            guard let id = c["id"] as? String else { return nil }
            return ConvoSummaryDTO(
                id: id,
                title: c["title"] as? String ?? "",
                sessionState: c["session_state"] as? String ?? "running",
                lastSeq: (c["last_seq"] as? NSNumber)?.int64Value ?? 0,
                snippet: c["snippet"] as? String ?? "",
                createdAt: (c["created_at"] as? NSNumber)?.int64Value ?? 0
            )
        }
        return SnapshotResponse(conversations: conversations,
                                seq: (obj["seq"] as? NSNumber)?.int64Value ?? 0)
    }

    public func messages(convoID: String, beforeSeq: Int64?, limit: Int) async throws -> [JournalEvent] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let beforeSeq {
            query.append(URLQueryItem(name: "before_seq", value: String(beforeSeq)))
        }
        let escaped = convoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? convoID
        let obj = try await request(path: "/convo/\(escaped)/messages", query: query)
        return (obj["events"] as? [[String: Any]] ?? []).compactMap(JournalEvent.init(frameObject:))
    }

    /// Dormant until the server lands `GET /media/:id` (v1-completion).
    public func mediaData(blobRef: String) async throws -> Data {
        let escaped = blobRef.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? blobRef
        let (data, response) = try await rawRequest(path: "/media/\(escaped)", method: "GET", body: nil)
        guard response.statusCode == 200 else { throw Self.error(status: response.statusCode, data: data) }
        return data
    }

    /// Dormant until the server lands APNs registration (v1-completion).
    /// A 404 (endpoint missing today) is swallowed as a no-op.
    public func registerAPNsToken(_ tokenHex: String) async throws {
        do {
            _ = try await request(path: "/devices/apns", method: "POST", body: ["apns_token": tokenHex])
        } catch JournalAPIError.notFound {
            // Server doesn't support push registration yet.
        }
    }

    // MARK: Internals

    private func request(
        path: String, method: String = "GET", body: [String: Any]? = nil,
        query: [URLQueryItem] = [], authenticated: Bool = true
    ) async throws -> [String: Any] {
        let (data, response) = try await rawRequest(path: path, method: method, body: body,
                                                    query: query, authenticated: authenticated)
        guard response.statusCode == 200 else { throw Self.error(status: response.statusCode, data: data) }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw JournalAPIError.transport("non-JSON response for \(path)")
        }
        return obj
    }

    private func rawRequest(
        path: String, method: String, body: [String: Any]?,
        query: [URLQueryItem] = [], authenticated: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if authenticated, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw JournalAPIError.transport("non-HTTP response")
            }
            return (data, http)
        } catch let error as JournalAPIError {
            throw error
        } catch {
            throw JournalAPIError.transport(error.localizedDescription)
        }
    }

    private static func error(status: Int, data: Data) -> JournalAPIError {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = obj?["error"] as? String
        switch (status, code) {
        case (403, "bad_credentials"): return .badCredentials
        case (429, "locked_out"):
            return .lockedOut(retryAfterSeconds: (obj?["retry_after"] as? NSNumber)?.intValue ?? 60)
        case (429, _): return .rateLimited
        case (401, _): return .unauthenticated
        case (403, _): return .forbidden
        case (404, _): return .notFound
        default: return .http(status: status, message: obj?["message"] as? String ?? code ?? "")
        }
    }
}
