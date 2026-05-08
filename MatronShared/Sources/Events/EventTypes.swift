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
}
