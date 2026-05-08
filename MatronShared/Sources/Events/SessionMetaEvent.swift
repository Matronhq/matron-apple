import Foundation

/// Decoded form of a `chat.matron.session_meta` Matrix state event
/// content blob. Pinned to the room state by the bot (or the bridge
/// on the bot's behalf) so a single state-event read on chat-open
/// gives the client enough context to render the session header
/// (`SessionMetaHeader`, Phase 5 Task 10) without scanning the
/// timeline.
///
/// `sessionID` + `startedAt` are required (a session has to have a
/// stable ID and a wall-clock start time); `model` + `workdir` are
/// optional so older bots can land partial events without breaking
/// the parser. Newer bots may add fields — callers that need them
/// should extend this struct + parser, not pull from a parallel
/// dict.
public struct SessionMetaEvent: Equatable, Sendable {
    public let sessionID: String
    public let model: String?
    public let workdir: String?
    public let startedAt: Date

    public init(sessionID: String, model: String?, workdir: String?, startedAt: Date) {
        self.sessionID = sessionID
        self.model = model
        self.workdir = workdir
        self.startedAt = startedAt
    }

    /// Parse a JSON `content` dictionary from a `chat.matron.session_meta`
    /// event. Returns `nil` if `session_id` or `started_at` are
    /// missing — graceful-degradation contract (header just won't
    /// render).
    public static func parse(content: [String: Any]) -> SessionMetaEvent? {
        guard let sessionID = content["session_id"] as? String,
              let startedMs = content["started_at"] as? Double else {
            return nil
        }
        return SessionMetaEvent(
            sessionID: sessionID,
            model: content["model"] as? String,
            workdir: content["workdir"] as? String,
            startedAt: Date(timeIntervalSince1970: startedMs / 1000)
        )
    }
}
