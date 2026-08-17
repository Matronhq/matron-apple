import Foundation

public struct LoginResponse: Equatable, Sendable {
    public let token: String
    public let deviceID: Int64
    public let userID: Int64
}

/// One of the user's agent boxes, as listed by `GET /snapshot`. Just
/// identity and label — the full device row (lag, cursor, last seen) is
/// `DeviceDTO` from `GET /devices`.
public struct AgentDTO: Equatable, Sendable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

public struct SnapshotResponse: Equatable, Sendable {
    public let conversations: [ConvoSummaryDTO]
    /// The user's agent boxes, id → name. Empty on a server predating the
    /// field, which simply means no chips.
    public let agents: [AgentDTO]
    public let seq: Int64
}

public enum JournalAPIError: Error, Equatable, Sendable {
    case badCredentials
    case lockedOut(retryAfterSeconds: Int)
    case rateLimited
    case unauthenticated
    case forbidden
    case notFound
    /// 409 — exactly-once semantics: `pair/approve` (already approved),
    /// `link/claim` (code already claimed), `link/approve` (nothing to
    /// approve yet, or already resolved).
    case conflict
    case http(status: Int, message: String)
    case transport(String)
}

/// Human-readable descriptions: these errors surface verbatim in UI banners
/// via `error.localizedDescription` (chat error overlay, composer send
/// error, sign-in form). Without this conformance Foundation renders the
/// gibberish "MatronJournal.JournalAPIError error 2." (Dan's 2026-07-30
/// screenshot — a rate-limit on a flaky link shown as an enum dump).
extension JournalAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .badCredentials:
            return "Invalid credentials."
        case .lockedOut(let retryAfterSeconds):
            return "Too many attempts — try again in \(retryAfterSeconds)s."
        case .rateLimited:
            return "The server is busy — trying again shortly."
        case .unauthenticated:
            return "Signed out by the server — please sign in again."
        case .forbidden:
            return "The server refused the request."
        case .notFound:
            return "Not found on the server."
        case .conflict:
            return "Already handled — possibly on another device."
        case .http(let status, let message):
            return message.isEmpty ? "Server error (HTTP \(status))." : message
        case .transport(let detail):
            return detail.isEmpty ? "Couldn't reach the server." : "Couldn't reach the server — \(detail)"
        }
    }
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

/// The user's answer to an agent-chat consent card. Mirrors the `decision`
/// field of `POST /agent-chat/answer`. Lives here rather than beside
/// `AgentChatRequest` in MatronEvents because it is a wire argument, not an
/// event — and MatronJournal is a leaf that does not depend on MatronEvents.
public enum AgentChatDecision: String, Equatable, Sendable, Codable {
    case approve
    case deny
}

/// The user's answer to an agent-spawn consent card. Mirrors the `decision`
/// field of `POST /agent-spawn/answer`. Its own type rather than a shared one
/// with `AgentChatDecision`: the two cards answer different endpoints with
/// different keys, and a single enum would make it easy to hand one card's
/// decision to the other's call.
public enum AgentSpawnDecision: String, Equatable, Sendable, Codable {
    case approve
    case deny
}

/// One row of `GET /agent-chat/pending` — an agent's request to chat that is
/// parked waiting on this user. The durable form of the consent card, for
/// asks that arrived while no client was connected.
///
/// `roomID` + `targetDeviceID` are the answer key; the two names are the
/// devices', already sanitised server-side and nil when a device has since
/// been revoked.
public struct AgentChatPendingDTO: Equatable, Sendable, Identifiable {
    public let roomID: String
    public let targetDeviceID: Int64
    public let initiatorDeviceID: Int64
    public let initiatorName: String?
    public let targetName: String?
    public let topic: String?
    public let justification: String?
    public let roomTitle: String
    public let createdAt: Int64

    /// Unique per parked row: the server's own primary key for one
    /// (`convo_agents.convo_id`, `agent_device_id`).
    public var id: String { "\(roomID)/\(targetDeviceID)" }

    public init(roomID: String, targetDeviceID: Int64, initiatorDeviceID: Int64,
                initiatorName: String?, targetName: String?, topic: String?,
                justification: String?, roomTitle: String, createdAt: Int64) {
        self.roomID = roomID
        self.targetDeviceID = targetDeviceID
        self.initiatorDeviceID = initiatorDeviceID
        self.initiatorName = initiatorName
        self.targetName = targetName
        self.topic = topic
        self.justification = justification
        self.roomTitle = roomTitle
        self.createdAt = createdAt
    }

    /// Who to name on the card. Falls back to the device id rather than
    /// going blank when the requesting device has been revoked mid-ask.
    public var requesterLabel: String {
        let name = initiatorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Device \(initiatorDeviceID)" : name
    }

    /// Who is being asked. Meaningful only for an invite: a join row
    /// self-targets, so on a join this names the requester again.
    public var targetLabel: String {
        let name = targetName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Device \(targetDeviceID)" : name
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

/// `POST /link/start` — a fresh device-link session for QR sign-in.
public struct LinkStart: Equatable, Sendable {
    /// Display form (`XXXX-XXXX`) — rendered under the QR and embedded in
    /// the payload verbatim.
    public let code: String
    public let expiresIn: Int

    public init(code: String, expiresIn: Int) {
        self.code = code
        self.expiresIn = expiresIn
    }
}

/// `POST /link/status` — what the show side's poll sees.
public enum LinkStatus: Equatable, Sendable {
    case waiting(expiresIn: Int)
    /// Someone claimed the code: show the approve card. The name is
    /// claimant-supplied; the IP is what the server saw — both go on
    /// screen before the user may approve (anti-phish, like PairPreview).
    case claimed(deviceName: String, requesterIP: String, expiresIn: Int)
}

/// `POST /link/claim` — the claimant's secret poll credential.
public struct LinkClaim: Equatable, Sendable {
    public let claimToken: String
    public let expiresIn: Int

    public init(claimToken: String, expiresIn: Int) {
        self.claimToken = claimToken
        self.expiresIn = expiresIn
    }
}

/// The identity minted at the approved `link/poll`. `username` exists
/// because the apps store the typed username as `UserSession.userID` and a
/// link claimant never types one.
public struct LinkApproval: Equatable, Sendable {
    public let token: String
    public let deviceID: Int64
    public let userID: Int64
    public let username: String

    public init(token: String, deviceID: Int64, userID: Int64, username: String) {
        self.token = token
        self.deviceID = deviceID
        self.userID = userID
        self.username = username
    }
}

/// `POST /link/poll` — pending until the starter acts; `denied` and
/// `approved` each arrive at most once (the server deletes the session).
public enum LinkPollResult: Equatable, Sendable {
    case pending
    case denied
    case approved(LinkApproval)
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
                parentConvoID: c["parent_convo_id"] as? String,
                // Which box manages this conversation. Absent on older
                // servers -> nil -> no chip.
                agentDeviceID: (c["agent_device_id"] as? NSNumber)?.int64Value,
                // Multi-agent room membership (owner + joined). Absent for
                // solo conversations and on older servers -> nil.
                participants: (c["participants"] as? [NSNumber]).map { $0.map(\.int64Value) }
            )
        }
        let agents = (obj["agents"] as? [[String: Any]] ?? []).compactMap { a -> AgentDTO? in
            guard let id = (a["device_id"] as? NSNumber)?.int64Value,
                  let name = a["name"] as? String else { return nil }
            return AgentDTO(id: id, name: name)
        }
        return SnapshotResponse(conversations: conversations, agents: agents,
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
        try await uploadMedia(data, contentType: contentType, progress: nil)
    }

    /// Progress-reporting variant: `progress` receives the fraction of the
    /// request body sent (0…1), delivered off the main thread. Built on a
    /// URLSessionUploadTask (rather than `rawRequest`'s `data(for:)`)
    /// because only a task exposes byte-level progress — the whole point on
    /// a slow uplink, where a multi-MB screenshot otherwise looks frozen.
    /// The timeout is raised well past the 60s default for the same
    /// reason: a legitimate slow upload must not die mid-body.
    public func uploadMedia(
        _ data: Data, contentType: String,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> String {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = Self.basePath(of: components) + "/media"
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (respData, response): (Data, HTTPURLResponse) = try await withCheckedThrowingContinuation { continuation in
            // Declared before the completion closure so it can invalidate
            // the observation; assigned after the task exists. The strong
            // capture in the completion closure is also what keeps the
            // observation alive for the task's lifetime.
            var observation: NSKeyValueObservation?
            let task = urlSession.uploadTask(with: request, from: data) { body, resp, error in
                observation?.invalidate()
                if let error {
                    continuation.resume(throwing: JournalAPIError.transport(error.localizedDescription))
                    return
                }
                guard let http = resp as? HTTPURLResponse else {
                    continuation.resume(throwing: JournalAPIError.transport("non-HTTP response"))
                    return
                }
                continuation.resume(returning: (body ?? Data(), http))
            }
            if let progress {
                observation = task.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                    progress(p.fractionCompleted)
                }
            }
            task.resume()
        }
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

    /// Renames a device. Client tokens only (the server 403s an agent), and
    /// 404 covers both "not yours" and "gone".
    public func renameDevice(id: Int64, name: String) async throws -> DeviceDTO {
        let obj = try await request(path: "/devices/\(id)/rename", method: "POST", body: ["name": name])
        guard let d = obj["device"] as? [String: Any],
              let deviceID = (d["device_id"] as? NSNumber)?.int64Value,
              let newName = d["name"] as? String
        else { throw JournalAPIError.transport("malformed rename response") }
        // Partial DTO: the rename response carries only identity and the new
        // name. Callers re-fetch the roster for the full row rather than
        // trusting these zeros — see DevicesViewModel.rename.
        return DeviceDTO(id: deviceID, kind: "", name: newName, createdAt: 0,
                         cursor: 0, lag: 0, lastSeenAt: nil, isSelf: false)
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

    // MARK: Agent chat consent

    /// Asks parked waiting on this user, across every room. The durable
    /// counterpart to the live consent card — an ask minted while no client
    /// was connected is only ever visible here.
    public func agentChatPending() async throws -> [AgentChatPendingDTO] {
        let obj = try await request(path: "/agent-chat/pending")
        return (obj["pending"] as? [[String: Any]] ?? []).compactMap { p in
            guard let roomID = p["convo_id"] as? String,
                  let target = (p["agent_device_id"] as? NSNumber)?.int64Value,
                  let initiator = (p["initiator_device_id"] as? NSNumber)?.int64Value
            else { return nil }
            return AgentChatPendingDTO(
                roomID: roomID,
                targetDeviceID: target,
                initiatorDeviceID: initiator,
                initiatorName: p["initiator_name"] as? String,
                targetName: p["agent_name"] as? String,
                topic: Self.nonEmpty(p["topic"]),
                justification: Self.nonEmpty(p["justification"]),
                roomTitle: p["title"] as? String ?? "",
                createdAt: (p["created_at"] as? NSNumber)?.int64Value ?? 0
            )
        }
    }

    /// Answers one parked ask. The ONLY path that resolves a consent card —
    /// a `prompt_reply` into the room never touches the parked row.
    ///
    /// One answer, one request: there is no standing consent to grant, so
    /// approving here says nothing about the next ask from the same pair.
    ///
    /// Returns the server's `delivered` flag: whether the approved invite
    /// reached the target's socket right now, or is still owed to it. Throws
    /// `.conflict` if the row is no longer awaiting an answer (already
    /// answered here or elsewhere, or expired) and `.notFound` if the room
    /// isn't this user's.
    @discardableResult
    public func answerAgentChat(
        roomID: String, targetDeviceID: Int64, decision: AgentChatDecision
    ) async throws -> Bool {
        let obj = try await request(
            path: "/agent-chat/answer", method: "POST",
            body: [
                "room_id": roomID, "target_device_id": targetDeviceID,
                "decision": decision.rawValue,
            ])
        return obj["delivered"] as? Bool ?? false
    }

    /// Answers one parked agent-spawn ask. The ONLY path that resolves a
    /// spawn consent card — and it takes just the request id, because the
    /// server keys the parked row on nothing else.
    ///
    /// The body is EXACTLY `{request_id, decision}`. There is no standing
    /// consent to grant and never has been: the server rejects an
    /// `always_allow` key with a 400 rather than ignoring it, so sending one
    /// would break the card's primary action outright.
    ///
    /// Throws `.conflict` (409) if the row is no longer awaiting an answer
    /// (already answered here or elsewhere, or 24h expired) and `.notFound`
    /// (404) if the request isn't this user's. The resolution itself arrives
    /// separately, as a `spawn_outcome` event in the journal.
    public func answerAgentSpawn(requestID: String, decision: AgentSpawnDecision) async throws {
        _ = try await request(
            path: "/agent-spawn/answer", method: "POST",
            body: ["request_id": requestID, "decision": decision.rawValue])
    }

    /// The journal defaults an absent topic/justification to `""` rather than
    /// omitting the key, so "absent" and "empty" arrive identically.
    private static func nonEmpty(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Device link (QR sign-in)

    /// Starts (or replaces) this device's link session. `.notFound` means
    /// the server predates /link/* — callers surface "doesn't support
    /// device linking yet".
    public func linkStart() async throws -> LinkStart {
        let obj = try await request(path: "/link/start", method: "POST", body: [:])
        guard let code = obj["link_code"] as? String,
              let expiresIn = (obj["expires_in"] as? NSNumber)?.intValue
        else { throw JournalAPIError.transport("malformed link start response") }
        return LinkStart(code: code, expiresIn: expiresIn)
    }

    /// This device's active session state. `.notFound` = no active session
    /// (expired or resolved) — the show side regenerates on it.
    public func linkStatus() async throws -> LinkStatus {
        let obj = try await request(path: "/link/status", method: "POST", body: [:])
        let expiresIn = (obj["expires_in"] as? NSNumber)?.intValue ?? 0
        switch obj["status"] as? String {
        case "waiting":
            return .waiting(expiresIn: expiresIn)
        case "claimed":
            guard let name = obj["device_name"] as? String,
                  let ip = obj["requester_ip"] as? String
            else { throw JournalAPIError.transport("malformed link status response") }
            return .claimed(deviceName: name, requesterIP: ip, expiresIn: expiresIn)
        default:
            throw JournalAPIError.transport("malformed link status response")
        }
    }

    /// Approves this device's claimed session. `.conflict` = nothing
    /// claimed yet or already resolved; `.notFound` = expired/gone.
    public func linkApprove(code: String) async throws {
        _ = try await request(path: "/link/approve", method: "POST", body: ["link_code": code])
    }

    public func linkDeny(code: String) async throws {
        _ = try await request(path: "/link/deny", method: "POST", body: ["link_code": code])
    }

    /// Claimant side: claims a scanned/typed code. Unauthenticated — this
    /// API instance belongs to the *target* server and has no token yet.
    /// `.conflict` = code already used; `.notFound` = unknown/expired.
    public func linkClaim(code: String, deviceName: String) async throws -> LinkClaim {
        let obj = try await request(path: "/link/claim", method: "POST",
                                    body: ["link_code": code, "device_name": deviceName],
                                    authenticated: false)
        guard let token = obj["claim_token"] as? String,
              let expiresIn = (obj["expires_in"] as? NSNumber)?.intValue
        else { throw JournalAPIError.transport("malformed link claim response") }
        return LinkClaim(claimToken: token, expiresIn: expiresIn)
    }

    /// Claimant poll loop body. `.notFound` after a successful claim means
    /// the session expired (or was replaced) — surface "Sign-in expired".
    public func linkPoll(claimToken: String) async throws -> LinkPollResult {
        let obj = try await request(path: "/link/poll", method: "POST",
                                    body: ["claim_token": claimToken], authenticated: false)
        switch obj["status"] as? String {
        case "pending": return .pending
        case "denied": return .denied
        case "approved":
            guard let token = obj["token"] as? String,
                  let deviceID = (obj["device_id"] as? NSNumber)?.int64Value,
                  let userID = (obj["user_id"] as? NSNumber)?.int64Value,
                  let username = obj["username"] as? String
            else { throw JournalAPIError.transport("malformed link poll response") }
            return .approved(LinkApproval(token: token, deviceID: deviceID, userID: userID, username: username))
        default:
            throw JournalAPIError.transport("malformed link poll response")
        }
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
