import Foundation

/// Decoded form of a structured bot question, from either of the two
/// wire protocols:
///
/// - `chat.matron.ask_user` custom events (spec §4.2) via `parse` —
///   the forward-looking contract this plan defines for the bridge.
/// - `chat.matron.buttons` content keys on ordinary `m.room.message`
///   events via `parseButtons` — the protocol the claude-matrix-bridge
///   emits today and Matron X ships (byte-compatible with matron-web
///   `src/matron/EventTypes.ts`).
///
/// Both drive the same `AskUserSheet` (iOS half-sheet) /
/// `MacAskUserSheet` (Mac fixed-size sheet) UI in Phase 5 Task 9.
/// `replyChannel` records which protocol the prompt arrived on so the
/// sheet's send path can answer in kind — plain-text `m.in_reply_to`
/// reply for `ask_user`, `chat.matron.button_response` for buttons.
///
/// `expiresAt` is optional: bots can omit it for indefinitely-valid
/// prompts; when present, the sheet should grey out the submit
/// button + show "expired" copy past the deadline. (The buttons
/// protocol has no expiry field — always `nil` there.)
public struct AskUserEvent: Equatable, Sendable {
    public enum InputKind: Equatable, Sendable {
        case text
        case choice(options: [Option], allowOther: Bool)
        case multiChoice(options: [Option], allowOther: Bool)
        case boolean
    }

    /// How the user's answer must be sent back so the bot can
    /// correlate it with this prompt.
    public enum ReplyChannel: Equatable, Sendable {
        /// Ordinary text message with `m.relates_to.m.in_reply_to`
        /// pointing at the prompt event (`ask_user` contract, spec §4.2).
        case textReply
        /// `chat.matron.button_response: { selected_values }` content
        /// key + `m.relates_to: { rel_type: chat.matron.button_answer }`
        /// relation (Matron X buttons contract).
        case buttonResponse
    }

    public struct Option: Equatable, Sendable {
        public let id: String
        public let label: String
        /// The string sent back when this option is chosen. For
        /// `ask_user` options this equals `label` (the spec's reply
        /// body is the label text); for buttons it's the wire `value`
        /// field, which can differ from the label (e.g. label
        /// "Cancel message 1", value "cancel:0").
        public let value: String

        public init(id: String, label: String, value: String? = nil) {
            self.id = id
            self.label = label
            self.value = value ?? label
        }
    }

    public let prompt: String
    public let kind: InputKind
    public let expiresAt: Date?
    public let replyChannel: ReplyChannel

    public init(
        prompt: String,
        kind: InputKind,
        expiresAt: Date?,
        replyChannel: ReplyChannel = .textReply
    ) {
        self.prompt = prompt
        self.kind = kind
        self.expiresAt = expiresAt
        self.replyChannel = replyChannel
    }

    /// Parse a JSON `content` dictionary from a `chat.matron.ask_user`
    /// event. Returns `nil` if `prompt` / `input.kind` are missing or
    /// `kind` is an unknown string — graceful-degradation contract
    /// (callers fall back to plain-text rendering).
    public static func parse(content: [String: Any]) -> AskUserEvent? {
        guard let prompt = content["prompt"] as? String,
              let inputDict = content["input"] as? [String: Any],
              let kindRaw = inputDict["kind"] as? String else {
            return nil
        }
        let allowOther = inputDict["allow_other"] as? Bool ?? false
        let optionsArr = (inputDict["options"] as? [[String: Any]]) ?? []
        let options = optionsArr.compactMap { dict -> Option? in
            guard let id = dict["id"] as? String,
                  let label = dict["label"] as? String else {
                return nil
            }
            return Option(id: id, label: label)
        }
        let kind: InputKind
        switch kindRaw {
        case "text":
            kind = .text
        case "choice":
            kind = .choice(options: options, allowOther: allowOther)
        case "multi_choice":
            kind = .multiChoice(options: options, allowOther: allowOther)
        case "boolean":
            kind = .boolean
        default:
            return nil
        }
        let expiresAt = (content["expires_at"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        return AskUserEvent(prompt: prompt, kind: kind, expiresAt: expiresAt)
    }

    /// Parse the content dictionary of an `m.room.message` carrying a
    /// `chat.matron.buttons` key (the bridge's live protocol). Field
    /// requirements mirror Matron X's `MatronButtonsContent.parse`
    /// exactly: `mode` must be `pick_one`/`pick_many`, `prompt` must be
    /// present, and at least one button must parse with all three of
    /// `id`/`label`/`value` — otherwise `nil`, and the message falls
    /// back to its plaintext `body` rendering.
    public static func parseButtons(content: [String: Any]) -> AskUserEvent? {
        guard let buttonsData = content[MatronEventType.buttons] as? [String: Any],
              let mode = buttonsData["mode"] as? String,
              let prompt = buttonsData["prompt"] as? String,
              let buttonsArr = buttonsData["buttons"] as? [[String: Any]] else {
            return nil
        }
        let options = buttonsArr.compactMap { dict -> Option? in
            guard let id = dict["id"] as? String,
                  let label = dict["label"] as? String,
                  let value = dict["value"] as? String else {
                return nil
            }
            return Option(id: id, label: label, value: value)
        }
        guard !options.isEmpty else { return nil }
        let kind: InputKind
        switch mode {
        case "pick_one":
            kind = .choice(options: options, allowOther: false)
        case "pick_many":
            kind = .multiChoice(options: options, allowOther: false)
        default:
            return nil
        }
        return AskUserEvent(
            prompt: prompt,
            kind: kind,
            expiresAt: nil,
            replyChannel: .buttonResponse
        )
    }
}
