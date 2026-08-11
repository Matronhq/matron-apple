import Foundation

/// How one agent-spawn request ended — the journal's durable `spawn_outcome`
/// event (matron-journal `src/spawns.js` `emitSpawnOutcome`), appended into
/// the SAME conversation the consent card was published into.
///
/// This type is why the spawn card needs no local answered-state: unlike an
/// agent-chat answer, a spawn resolution IS an event in the timeline, so
/// every device that syncs the room learns it, in the same order, across
/// restarts. `ChatViewModel` derives the card's resolved state from these
/// rows rather than remembering anything itself.
public struct SpawnOutcome: Equatable, Sendable {
    /// The four terminal states the server reports. Kept separate from the
    /// raw `outcome` string so an outcome minted by a newer server renders
    /// neutrally instead of crashing or being mistaken for one of these.
    public enum Kind: String, Equatable, Sendable {
        case started
        case declined
        case expired
        case failed
    }

    /// The request this resolves — the key the card is matched on. The card
    /// carries no seq of the outcome and the outcome carries no seq of the
    /// card; `request_id` is the only link between them.
    public let requestID: String
    /// The wire string, kept verbatim so an unknown value survives round
    /// trips and can be logged as what it actually was.
    public let outcome: String
    /// The room the started child talks in — what "Open" navigates to.
    /// Present on `started` only.
    public let roomID: String?
    /// The child conversation's id, when the server reported one.
    public let childConvoID: String?
    /// Machine-readable reason on `failed` (e.g. "target_unreachable").
    public let errorCode: String?

    public init(requestID: String, outcome: String, roomID: String? = nil,
                childConvoID: String? = nil, errorCode: String? = nil) {
        self.requestID = requestID
        self.outcome = outcome
        self.roomID = roomID
        self.childConvoID = childConvoID
        self.errorCode = errorCode
    }

    /// The synthetic outcome the client mints when the server answers a tap
    /// with 409: the row stopped awaiting an answer (decided on another
    /// device, or 24h expired). Nothing is persisted — the real
    /// `spawn_outcome` event replaces it the moment it syncs.
    public static func expired(requestID: String) -> SpawnOutcome {
        SpawnOutcome(requestID: requestID, outcome: Kind.expired.rawValue)
    }

    /// Parses a `spawn_outcome` payload, or `nil` when it carries neither of
    /// the two fields that make it meaningful. A `nil` here falls back to
    /// the mapper's existing unknown-event handling.
    public static func parse(payload: [String: Any]) -> SpawnOutcome? {
        guard let requestID = payload["request_id"] as? String, !requestID.isEmpty,
              let outcome = payload["outcome"] as? String, !outcome.isEmpty
        else { return nil }
        return SpawnOutcome(
            requestID: requestID,
            outcome: outcome,
            roomID: nonEmpty(payload["room_id"]),
            childConvoID: nonEmpty(payload["child_convo_id"]),
            errorCode: nonEmpty(payload["error_code"])
        )
    }

    private static func nonEmpty(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The known outcome, or `nil` for a value this client doesn't know.
    public var kind: Kind? { Kind(rawValue: outcome) }

    /// The room "Open" should navigate to, or `nil` when there is nothing to
    /// open. Only a `started` outcome has a room: a declined/expired/failed
    /// spawn never produced one, and offering to open it would push an empty
    /// conversation.
    public var openableRoomID: String? {
        guard kind == .started else { return nil }
        return roomID
    }

    /// One line for the user, matching the server's own `snippetOf`
    /// (matron-journal `src/journal.js`) so a chat-list row and the timeline
    /// row it summarises never say different things. An unknown outcome
    /// renders neutrally rather than leaking the raw wire value.
    public var displayLine: String {
        guard let kind else { return "Spawn request resolved" }
        switch kind {
        case .started: return "🚀 Spawned session started"
        case .declined: return "🚫 Spawn declined"
        case .expired: return "⌛ Spawn request expired"
        case .failed:
            guard let errorCode else { return "❌ Spawn failed" }
            return "❌ Spawn failed — \(errorCode)"
        }
    }
}

/// Where one spawn consent card is in its short life.
///
/// Lives in MatronEvents so the view model that owns it and the card that
/// renders it agree on one type. Deliberately has NO `answered` case: a spawn
/// answer resolves into the journal as a `spawn_outcome` event, so `resolved`
/// carries that event rather than a remembered local decision — the card is
/// restart-proof and cross-device consistent for free, and there is nothing
/// to persist.
public enum AgentSpawnCardState: Equatable, Sendable {
    case idle
    case sending
    case resolved(SpawnOutcome)
    case failed(String)
}
