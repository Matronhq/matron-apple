import Foundation

/// One agent asking the user's permission to start a session on another box —
/// the journal's spawn consent card (matron-journal `src/ws.js`, the
/// `spawn_request` park path).
///
/// It arrives as a `permission_request` event whose payload carries
/// `kind: "agent_spawn"`, published into the *requesting* session's
/// conversation — where the user is already talking to the agent that is
/// asking. Like the agent-chat card it is client-only and nothing in the
/// timeline answers it: the answer is `POST /agent-spawn/answer`, over HTTP,
/// keyed on `requestID` alone.
///
/// Deliberately NOT modelled as an `AskUserEvent`, for the same reason
/// `AgentChatRequest` isn't: the generic Allow/Deny buttons answer over
/// `prompt_reply`, which never reaches the parked row — the tap earned
/// "Nothing to answer right now" from the bridge and the ask expired 24h
/// later. That dead-generic fallback is the bug this type exists to close.
public struct AgentSpawnRequest: Equatable, Sendable {
    /// The parked row's id — the whole key `POST /agent-spawn/answer` needs.
    public let requestID: String
    public let fromDeviceID: Int64
    /// The requesting agent's device name, sanitised and capped server-side.
    /// Empty if the journal had no name for it.
    public let fromName: String
    /// The box the session would start on.
    public let targetDeviceID: Int64
    public let targetName: String
    /// The requesting session, id and title each, rendered the way the
    /// conversation list renders it. Empty when the journal named none.
    public let fromConvoID: String
    public let fromConvoTitle: String
    /// Where on the target box the session would run.
    public let workdir: String
    /// What the child session would be asked to do — the agent's own words.
    public let task: String
    public let topic: String?

    public init(
        requestID: String, fromDeviceID: Int64, fromName: String,
        targetDeviceID: Int64, targetName: String = "",
        fromConvoID: String = "", fromConvoTitle: String = "",
        workdir: String, task: String, topic: String?
    ) {
        self.requestID = requestID
        self.fromDeviceID = fromDeviceID
        self.fromName = fromName
        self.targetDeviceID = targetDeviceID
        self.targetName = targetName
        self.fromConvoID = fromConvoID
        self.fromConvoTitle = fromConvoTitle
        self.workdir = workdir
        self.task = task
        self.topic = topic
    }

    /// Parses a `permission_request` payload, or `nil` if this is not a
    /// spawn card. Strict about the fields a decision rests on (`request_id`
    /// to answer; the device ids, `workdir` and `task` to know what is being
    /// approved): a card missing any of them must fall back to the generic
    /// permission rendering rather than draw buttons that would 400 — or
    /// worse, approve something the user couldn't see.
    public static func parse(payload: [String: Any]) -> AgentSpawnRequest? {
        guard payload["kind"] as? String == "agent_spawn",
              let requestID = requiredText(payload["request_id"]),
              let from = integral(payload["from_device_id"]),
              let target = integral(payload["target_device_id"]),
              let workdir = requiredText(payload["workdir"]),
              let task = requiredText(payload["task"])
        else { return nil }
        return AgentSpawnRequest(
            requestID: requestID,
            fromDeviceID: from,
            fromName: payload["from_name"] as? String ?? "",
            targetDeviceID: target,
            // Display-only and optional, same stance as the chat card: an
            // older journal still yields an answerable card.
            targetName: payload["target_name"] as? String ?? "",
            fromConvoID: payload["from_convo_id"] as? String ?? "",
            fromConvoTitle: payload["from_convo_title"] as? String ?? "",
            workdir: workdir,
            task: task,
            topic: nonEmpty(payload["topic"])
        )
    }

    /// The journal defaults `topic` to `""` rather than omitting it, so
    /// "absent" and "empty" arrive identically — collapse both to nil.
    private static func nonEmpty(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A required text field: trimmed, and whitespace-only rejected — a
    /// card whose answer key or facts are blank is unanswerable, so it
    /// falls back rather than rendering an empty row.
    private static func requiredText(_ raw: Any?) -> String? {
        nonEmpty(raw)
    }

    /// A device id must be an integral JSON number. JSON booleans bridge to
    /// `NSNumber` too — `true` must not become device id 1 — and a
    /// fractional value must not silently truncate to a different device.
    private static func integral(_ raw: Any?) -> Int64? {
        guard let n = raw as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(n)
        else { return nil }
        return n.int64Value
    }

    /// The name to show for the requester, falling back to the device id
    /// when the journal had no name (a revoked device mid-ask).
    public var requesterLabel: String {
        fromName.isEmpty ? "Device \(fromDeviceID)" : fromName
    }

    /// The box the session would start on, same fallback.
    public var targetLabel: String {
        targetName.isEmpty ? "Device \(targetDeviceID)" : targetName
    }

    /// The requesting end with its session named, chat-list style —
    /// "dan-mac — 2:69 text carry and fitting parity" — or the device alone
    /// when the journal named no session.
    public var fromLabel: String {
        guard let session = AgentChatRequest.sessionLabel(
            id: fromConvoID, title: fromConvoTitle) else { return requesterLabel }
        return "\(requesterLabel) — \(session)"
    }

    /// One line stating what is being asked, in the user's terms. Names the
    /// box: "another box" is not something a user can consent to.
    public var headline: String {
        "\(requesterLabel) wants to start a new session on \(targetLabel)."
    }
}
