import Foundation

/// Namespace for the three Matron-specific Matrix event types defined
/// in spec §4. Each constant matches the wire-format `type` string the
/// bridge / bots emit; the parsers in this module then turn the
/// matching event content into typed DTOs.
///
/// Use the constants (not string literals) at call sites so a future
/// rename catches every reference at compile time.
public enum MatronEventType {
    /// Tool invocation by an agent — args, status, result. Renders as
    /// a collapsible card in the timeline (`ToolCallCard`).
    public static let toolCall = "chat.matron.tool_call"

    /// Bot asking the user a structured question. Renders as a half-
    /// sheet on iOS / fixed-size sheet on Mac (`AskUserSheet` /
    /// `MacAskUserSheet`); user's reply correlates back via
    /// `m.in_reply_to`.
    public static let askUser = "chat.matron.ask_user"

    /// Session-level metadata (model, project name, started-at, etc.)
    /// pinned to the room state. Renders as the chat header
    /// (`SessionMetaHeader`).
    public static let sessionMeta = "chat.matron.session_meta"

    // MARK: Matron X buttons protocol
    //
    // The three constants below are CONTENT KEYS / relation types, not
    // event `type` strings — a buttons prompt is an ordinary
    // `m.room.message` (msgtype `m.text`, plaintext fallback in `body`)
    // carrying the `chat.matron.buttons` key in its content. This is
    // the protocol the claude-matrix-bridge emits TODAY and Matron X
    // ships; canonical definitions live in matron-web
    // `src/matron/EventTypes.ts` — stay byte-compatible with that file
    // (HANDOVER 2026-06-12 note).

    /// Content key on an `m.room.message`: `{ mode: "pick_one" |
    /// "pick_many", prompt, buttons: [{id, label, value}] }`. Parsed by
    /// `AskUserEvent.parseButtons` onto the same sheet UI as
    /// `ask_user`.
    public static let buttons = "chat.matron.buttons"

    /// Content key on the user's reply: `{ selected_values: [String] }`.
    /// The bridge prefers `selected_values` over the plaintext `body`.
    public static let buttonResponse = "chat.matron.button_response"

    /// `rel_type` of the `m.relates_to` block on a button response,
    /// pointing at the originating buttons event's ID.
    public static let buttonAnswer = "chat.matron.button_answer"
}
