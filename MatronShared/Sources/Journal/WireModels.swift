import Foundation

/// String constants for journal event `type`s (spec §7). Use these, not
/// literals, so renames are compile-checked.
public enum JournalEventType {
    public static let text = "text"
    public static let prompt = "prompt"
    public static let promptReply = "prompt_reply"
    public static let toolOutput = "tool_output"
    public static let diff = "diff"
    public static let permissionRequest = "permission_request"
    public static let sessionStatus = "session_status"
    public static let file = "file"
    public static let image = "image"
    public static let readMarker = "read_marker"
    public static let edit = "edit"
    /// Conversation metadata (title, etc.). Carries no message body — it
    /// updates the conversation row and is skipped in the timeline.
    public static let convoMeta = "convo_meta"

    /// Types that bump unread counts and set the conversation snippet —
    /// mirrors the server's MESSAGE_TYPES (src/journal.js).
    public static let messageTypes: Set<String> = [
        text, toolOutput, diff, prompt, permissionRequest, file, image,
    ]
}

/// One durable journal row. `payloadData` keeps the raw JSON object bytes so
/// arbitrary payload shapes survive round-trips; `payload` decodes on access.
public struct JournalEvent: Equatable, Sendable {
    public let seq: Int64
    public let convoID: String
    public let ts: Date
    public let sender: String
    public let type: String
    public let payloadData: Data

    public var payload: [String: Any] {
        (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] ?? [:]
    }

    public init(seq: Int64, convoID: String, ts: Date, sender: String, type: String, payloadData: Data) {
        self.seq = seq
        self.convoID = convoID
        self.ts = ts
        self.sender = sender
        self.type = type
        self.payloadData = payloadData
    }

    /// Builds from a decoded `{seq, convo_id, ts, sender, type, payload}`
    /// object (shared shape of WS journal frames and HTTP pagination rows).
    public init?(frameObject obj: [String: Any]) {
        guard let seq = (obj["seq"] as? NSNumber)?.int64Value,
              let convoID = obj["convo_id"] as? String,
              let ts = (obj["ts"] as? NSNumber)?.doubleValue,
              let sender = obj["sender"] as? String,
              let type = obj["type"] as? String
        else { return nil }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        self.init(
            seq: seq, convoID: convoID, ts: Date(timeIntervalSince1970: ts / 1000),
            sender: sender, type: type, payloadData: payloadData
        )
    }
}

/// A streaming-output update. Never persisted; lost updates are harmless
/// (the finalize journal row supersedes them).
public struct EphemeralUpdate: Equatable, Sendable {
    public let convoID: String
    public let messageRef: String
    public let textDelta: String?
    public let replaceText: String?

    public init(convoID: String, messageRef: String, textDelta: String?, replaceText: String?) {
        self.convoID = convoID
        self.messageRef = messageRef
        self.textDelta = textDelta
        self.replaceText = replaceText
    }
}

/// A transient activity indicator (typing / tool-use). Per-conversation and
/// not tied to any message; `state == .idle` clears whatever indicator is
/// showing. Never persisted; delivered only while the client is `viewing`
/// the conversation, so a missed update is harmless.
public struct ActivityUpdate: Equatable, Sendable {
    public enum State: String, Sendable {
        /// Agent is composing/thinking — a bare "working" indicator.
        case thinking
        /// Agent is running a tool; `detail` carries the tool name.
        case tool
        /// Nothing in flight — clears any showing indicator.
        case idle
    }

    public let convoID: String
    public let state: State
    public let detail: String?

    public init(convoID: String, state: State, detail: String?) {
        self.convoID = convoID
        self.state = state
        self.detail = detail
    }
}

/// Server → client frames. Unknown `kind`s decode to nil (skip); unknown
/// control ops decode to `.unknownControl` so the protocol can grow.
public enum ServerFrame: Equatable, Sendable {
    case journal(JournalEvent)
    case ephemeral(EphemeralUpdate)
    case activity(ActivityUpdate)
    case helloOK(headSeq: Int64)
    case error(code: String, ref: String?)
    case snapshotRequired
    case unknownControl(op: String)

    public static func decode(_ text: String) -> ServerFrame? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let kind = obj["kind"] as? String
        else { return nil }
        switch kind {
        case "journal":
            return JournalEvent(frameObject: obj).map(ServerFrame.journal)
        case "ephemeral":
            guard let convoID = obj["convo_id"] as? String else { return nil }
            // Two shapes share `kind: "ephemeral"`: a streaming-text update
            // (keyed by `message_ref`) and an activity indicator (an
            // `activity` object, no `message_ref`). Branch on the `activity`
            // key so a valid activity frame isn't dropped by a `message_ref`
            // guard meant only for the streaming case.
            if let activity = obj["activity"] as? [String: Any] {
                guard let stateRaw = activity["state"] as? String,
                      let state = ActivityUpdate.State(rawValue: stateRaw) else { return nil }
                return .activity(ActivityUpdate(
                    convoID: convoID, state: state,
                    detail: activity["detail"] as? String
                ))
            }
            guard let ref = obj["message_ref"] as? String else { return nil }
            return .ephemeral(EphemeralUpdate(
                convoID: convoID, messageRef: ref,
                textDelta: obj["text"] as? String,
                replaceText: obj["replace_text"] as? String
            ))
        case "control":
            guard let op = obj["op"] as? String else { return nil }
            switch op {
            case "hello_ok":
                return .helloOK(headSeq: (obj["seq"] as? NSNumber)?.int64Value ?? 0)
            case "error":
                return .error(code: obj["code"] as? String ?? "unknown", ref: obj["ref"] as? String)
            case "snapshot_required":
                return .snapshotRequired
            default:
                return .unknownControl(op: op)
            }
        default:
            return nil
        }
    }
}

/// Client → server operations.
public enum ClientOp: Equatable, Sendable {
    case hello(token: String, cursor: Int64?)
    case send(convoID: String, body: String, localID: String)
    case promptReply(convoID: String, targetSeq: Int64, choice: String?, text: String?)
    case readMarker(convoID: String, upToSeq: Int64)
    case ack(cursor: Int64)
    case viewing(convoID: String?)

    public func encoded() -> String {
        let obj: [String: Any]
        switch self {
        case let .hello(token, cursor):
            obj = ["op": "hello", "token": token, "cursor": cursor.map(NSNumber.init(value:)) ?? NSNull()]
        case let .send(convoID, body, localID):
            obj = ["op": "send", "convo_id": convoID, "type": "text",
                   "payload": ["body": body], "local_id": localID]
        case let .promptReply(convoID, targetSeq, choice, text):
            obj = ["op": "prompt_reply", "convo_id": convoID,
                   "target_seq": NSNumber(value: targetSeq),
                   "choice": choice ?? NSNull(), "text": text ?? NSNull()]
        case let .readMarker(convoID, upToSeq):
            obj = ["op": "read_marker", "convo_id": convoID, "up_to_seq": NSNumber(value: upToSeq)]
        case let .ack(cursor):
            obj = ["op": "ack", "cursor": NSNumber(value: cursor)]
        case let .viewing(convoID):
            obj = ["op": "viewing", "convo_id": convoID ?? NSNull()]
        }
        // Dictionaries above are always valid JSON objects.
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
