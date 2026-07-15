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
    /// 409 — currently only `POST /pair/approve`: the code was already
    /// approved (exactly-once semantics).
    case conflict
    case http(status: Int, message: String)
    case transport(String)
}

/// One row of `GET /devices` — a client (app) or agent (headless box)
/// enrolled on the signed-in user's account. Timestamps are epoch ms;
/// `lastSeenAt` is nil for a device that has never connected.
public struct DeviceDTO: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let kind: String   // "client" | "agent"
    public let name: String
    public let createdAt: Int64
    public let cursor: Int64
    /// User's head seq minus this device's cursor — how far behind its
    /// journal sync is. 0 = up to date.
    public let lag: Int64
    public let lastSeenAt: Int64?
    public let isSelf: Bool
    /// Whether the device has a live journal connection right now (agent
    /// RPC would reach it). Defaults false when the server predates the
    /// flag.
    public let connected: Bool

    public init(id: Int64, kind: String, name: String, createdAt: Int64,
                cursor: Int64, lag: Int64, lastSeenAt: Int64?, isSelf: Bool,
                connected: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.createdAt = createdAt
        self.cursor = cursor
        self.lag = lag
        self.lastSeenAt = lastSeenAt
        self.isSelf = isSelf
        self.connected = connected
    }
}

/// `POST /pair/preview` — who is asking to join, shown to the user before
/// approve is offered (anti-phish requirement of the pairing design).
public struct PairPreview: Equatable, Sendable {
    public let requesterIP: String
    /// Seconds of TTL remaining on the pair code (codes live 10 minutes).
    public let expiresIn: Int

    public init(requesterIP: String, expiresIn: Int) {
        self.requesterIP = requesterIP
        self.expiresIn = expiresIn
    }
}

/// Thin HTTP surface of the journal server: login, snapshot, pagination,
/// push registration, plus the still-dormant media endpoint (spec'd; the
/// server lands it later in v1-completion — callers must tolerate
/// `.notFound` until then).
public actor JournalAPI {
    public nonisolated let serverURL: URL
    private let urlSession: URLSession
    private var token: String?

    public init(serverURL: URL, urlSession: URLSession = .shared, token: String? = nil) {
        self.serverURL = serverURL
        self.urlSession = urlSession
        self.token = token
    }

    public nonisolated var wsURL: URL {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.percentEncodedPath = Self.basePath(of: components) + "/ws"
        return components.url!
    }

    /// The server URL's own path, normalized so endpoint paths can be
    /// appended: "" or "/" → "", "/prefix/" → "/prefix". Assigning an
    /// endpoint path directly used to REPLACE this prefix, so a server
    /// hosted under a subpath got every request at the host root (bugbot
    /// "Homeserver path prefix dropped").
    private nonisolated static func basePath(of components: URLComponents) -> String {
        var base = components.percentEncodedPath
        while base.hasSuffix("/") { base.removeLast() }
        return base
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
                createdAt: (c["created_at"] as? NSNumber)?.int64Value ?? 0,
                lastTS: (c["last_ts"] as? NSNumber)?.int64Value,
                // null for a normal conversation, the parent's id for a
                // subagent child. Absent on servers predating sub-chats.
                parentConvoID: c["parent_convo_id"] as? String
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
        let escaped = Self.pathSegment(convoID)
        let obj = try await request(path: "/convo/\(escaped)/messages", query: query)
        return (obj["events"] as? [[String: Any]] ?? []).compactMap(JournalEvent.init(frameObject:))
    }

    /// Dormant until the server lands `GET /media/:id` (v1-completion).
    public func mediaData(blobRef: String) async throws -> Data {
        let escaped = Self.pathSegment(blobRef)
        let (data, response) = try await rawRequest(path: "/media/\(escaped)", method: "GET", body: nil)
        guard response.statusCode == 200 else { throw Self.error(status: response.statusCode, data: data) }
        return data
    }

    /// Uploads raw media bytes (POST /media, Bearer, `data` as the raw
    /// request body under `contentType`) and returns the server's
    /// `media_id`, which callers pass back as the `blob_ref` on a
    /// subsequent media `send`. Mirrors `mediaData(blobRef:)`'s request
    /// style and `error(status:data:)` mapping.
    public func uploadMedia(_ data: Data, contentType: String) async throws -> String {
        let (respData, response) = try await rawRequest(path: "/media", method: "POST", body: nil,
                                                        rawBody: data, rawContentType: contentType)
        guard response.statusCode == 200 else { throw Self.error(status: response.statusCode, data: respData) }
        guard let obj = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any],
              let mediaID = obj["media_id"] as? String
        else { throw JournalAPIError.transport("malformed media upload response") }
        return mediaID
    }

    // MARK: Devices + pairing (journal PR #19 spec)

    /// The signed-in user's device roster. Order is not guaranteed by the
    /// server — callers sort. Pull-based: refresh on screen enter and after
    /// mutations; roster changes are not journal events.
    public func devices() async throws -> [DeviceDTO] {
        let obj = try await request(path: "/devices")
        return (obj["devices"] as? [[String: Any]] ?? []).compactMap { d -> DeviceDTO? in
            guard let id = (d["device_id"] as? NSNumber)?.int64Value else { return nil }
            return DeviceDTO(
                id: id,
                kind: d["kind"] as? String ?? "client",
                name: d["name"] as? String ?? "",
                createdAt: (d["created_at"] as? NSNumber)?.int64Value ?? 0,
                cursor: (d["cursor"] as? NSNumber)?.int64Value ?? 0,
                lag: (d["lag"] as? NSNumber)?.int64Value ?? 0,
                lastSeenAt: (d["last_seen_at"] as? NSNumber)?.int64Value,
                isSelf: d["is_self"] as? Bool ?? false,
                connected: d["connected"] as? Bool ?? false
            )
        }
    }

    /// Immediate, permanent revocation — no undo; re-enrollment is the
    /// recovery path. Self-revocation is legal and means "sign out this
    /// device". 404 (`.notFound`) means already revoked elsewhere — callers
    /// treat it as success.
    public func revokeDevice(id: Int64) async throws {
        _ = try await request(path: "/devices/\(id)/revoke", method: "POST", body: [:])
    }

    /// Previews a pairing code before approval. 404 = unknown, expired, or
    /// already approved (deliberately indistinguishable server-side).
    public func pairPreview(code: String) async throws -> PairPreview {
        let obj = try await request(path: "/pair/preview", method: "POST", body: ["pair_code": code])
        guard let ip = obj["requester_ip"] as? String,
              let expiresIn = (obj["expires_in"] as? NSNumber)?.intValue
        else { throw JournalAPIError.transport("malformed pair preview response") }
        return PairPreview(requesterIP: ip, expiresIn: expiresIn)
    }

    /// Approves a pairing code, binding the (future) agent to this user
    /// under `agentName`. Exactly-once: `.conflict` = already approved.
    /// Approval does NOT create the device — it appears in the roster only
    /// once the box claims its token.
    public func pairApprove(code: String, agentName: String) async throws {
        _ = try await request(path: "/pair/approve", method: "POST",
                              body: ["pair_code": code, "agent_name": agentName])
    }

    public enum PushEnvironment: String, Sendable {
        case sandbox
        case prod
    }

    /// Registers this device for APNs pushes. Server: POST /push/register
    /// (client devices only). Xcode debug builds register sandbox tokens;
    /// TestFlight/App Store builds are prod.
    public func registerPush(tokenHex: String, environment: PushEnvironment) async throws {
        _ = try await request(path: "/push/register", method: "POST",
                              body: ["apns_token": tokenHex, "environment": environment.rawValue])
    }

    /// Clears this device's push registration (apns_token: null per protocol).
    public func unregisterPush() async throws {
        _ = try await request(path: "/push/register", method: "POST",
                              body: ["apns_token": NSNull()])
    }

    // MARK: Internals

    /// Escapes one path segment: everything but unreserved characters is
    /// percent-encoded, including "/" (which .urlPathAllowed would let through).
    private static func pathSegment(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

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
        query: [URLQueryItem] = [], authenticated: Bool = true,
        rawBody: Data? = nil, rawContentType: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = Self.basePath(of: components) + path
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if authenticated, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // A raw body (media upload) sends `data` verbatim under its own
        // content type; the JSON `body` path is mutually exclusive with it.
        if let rawBody {
            request.setValue(rawContentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = rawBody
        } else if let body {
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
        case (409, _): return .conflict
        default: return .http(status: status, message: obj?["message"] as? String ?? code ?? "")
        }
    }
}
