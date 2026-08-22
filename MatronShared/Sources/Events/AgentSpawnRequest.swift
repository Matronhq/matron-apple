import Foundation

/// One agent asking the user's permission to START ANOTHER AGENT — the
/// journal's server-minted spawn consent card (matron-journal `src/ws.js`,
/// the `spawn_request` park path).
///
/// It arrives as a `permission_request` event whose payload carries
/// `kind: "agent_spawn"`, published into the REQUESTING agent's own
/// conversation, and it is *client-only*: `isClientOnlyEvent` keeps it out of
/// every agent-facing replay, because the card carries the child's seed
/// prompt as task text the user has not yet approved. Nothing in the timeline
/// answers it — the answer is `POST /agent-spawn/answer`, over HTTP, keyed on
/// `request_id` alone.
///
/// Deliberately NOT modelled as an `AskUserEvent`, for the same reason
/// `AgentChatRequest` isn't: that type's generic Allow/Deny buttons answer
/// over `prompt_reply`, a channel that never reaches the parked row, and the
/// facts a consent decision rests on — who is asking, on which box, in which
/// folder, to run what — have nowhere to live in a generic prompt.
public struct AgentSpawnRequest: Equatable, Sendable {
    /// The server's own id for the parked row — the ONLY key
    /// `POST /agent-spawn/answer` takes, and the key the resolving
    /// `spawn_outcome` event is filed under.
    public let requestID: String
    public let fromDeviceID: Int64
    /// The requesting agent's device name, already sanitised and capped
    /// server-side. Empty if the journal had no name for it.
    public let fromName: String
    /// The requester's conversation — id and title, exactly as the
    /// conversation list shows it. Empty when the journal named none.
    public let fromConvoID: String
    public let fromConvoTitle: String
    /// The box the child would be started on.
    public let targetDeviceID: Int64
    public let targetName: String
    /// The working directory the child would run in. The single most
    /// consequential fact on the card after the task itself.
    public let workdir: String
    /// The child's seed prompt, verbatim. Never elided in the card body —
    /// approving this is approving these words.
    public let task: String
    public let topic: String?

    public init(
        requestID: String, fromDeviceID: Int64, fromName: String = "",
        fromConvoID: String = "", fromConvoTitle: String = "",
        targetDeviceID: Int64, targetName: String = "",
        workdir: String = "", task: String, topic: String? = nil
    ) {
        self.requestID = requestID
        self.fromDeviceID = fromDeviceID
        self.fromName = fromName
        self.fromConvoID = fromConvoID
        self.fromConvoTitle = fromConvoTitle
        self.targetDeviceID = targetDeviceID
        self.targetName = targetName
        self.workdir = workdir
        self.task = task
        self.topic = topic
    }

    /// Parses a `permission_request` payload, or `nil` if this is not an
    /// agent-spawn card. Strict about the two things a card needs to be
    /// worth answering — the `request_id` the answer call is keyed on and a
    /// non-empty `task` for the user to consent to: a card we cannot answer
    /// (or cannot describe) must fall back to the generic permission
    /// rendering rather than draw buttons that would 400.
    ///
    /// The device ids are display-only here (unlike agent-chat, where they
    /// are half the answer key), so a payload missing them still yields an
    /// answerable card — just a less specific one.
    public static func parse(payload: [String: Any]) -> AgentSpawnRequest? {
        guard payload["kind"] as? String == "agent_spawn",
              let requestID = payload["request_id"] as? String, !requestID.isEmpty,
              let task = payload["task"] as? String,
              !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return AgentSpawnRequest(
            requestID: requestID,
            fromDeviceID: (payload["from_device_id"] as? NSNumber)?.int64Value ?? 0,
            fromName: payload["from_name"] as? String ?? "",
            fromConvoID: payload["from_convo_id"] as? String ?? "",
            fromConvoTitle: payload["from_convo_title"] as? String ?? "",
            targetDeviceID: (payload["target_device_id"] as? NSNumber)?.int64Value ?? 0,
            targetName: payload["target_name"] as? String ?? "",
            workdir: payload["workdir"] as? String ?? "",
            task: task,
            topic: nonEmpty(payload["topic"])
        )
    }

    /// The journal defaults `topic` to `""` rather than omitting it, so
    /// "absent" and "empty" arrive identically — collapse both to nil so the
    /// card can fall back to the task's first line instead of showing a
    /// blank headline.
    private static func nonEmpty(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The name to show for the requester, falling back to the device id
    /// when the journal had no name (a revoked device mid-ask).
    public var requesterLabel: String {
        fromName.isEmpty ? "Device \(fromDeviceID)" : fromName
    }

    /// The name to show for the box the child would run on, same fallback.
    public var targetLabel: String {
        targetName.isEmpty ? "Device \(targetDeviceID)" : targetName
    }

    /// "dev-2 — 68 · Syncing bridge services", or just the device name when
    /// the journal named no conversation. Uses the agent-chat card's session
    /// labelling verbatim (same module, same rule) so both consent cards
    /// name a session the way the conversation list does.
    public var fromLabel: String {
        guard let session = AgentChatRequest.sessionLabel(id: fromConvoID, title: fromConvoTitle)
        else { return requesterLabel }
        return "\(requesterLabel) — \(session)"
    }

    /// Longest headline the card will draw before eliding. A task is free
    /// text with no server-side length cap worth trusting as a title, and a
    /// 4,000-character single line would push the buttons off the screen.
    static let headlineMaxChars = 120

    /// One line stating what is being asked, in the user's terms: the
    /// requesting agent's own topic when it wrote one, else the opening line
    /// of the task itself. Never empty — `parse` guarantees a non-blank
    /// task.
    public var headline: String {
        if let topic { return Self.elided(topic) }
        let firstLine = task.split(whereSeparator: \.isNewline)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? task
        return Self.elided(firstLine.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func elided(_ text: String) -> String {
        text.count <= headlineMaxChars ? text : String(text.prefix(headlineMaxChars)) + "…"
    }
}
