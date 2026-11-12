import Foundation

/// A structured question from an agent: a journal prompt, a permission
/// request or a busy-queue card, as `JournalTimelineMapper` decodes it.
///
/// Drives the `AskUserSheet` (iOS half-sheet) / `MacAskUserSheet` (Mac
/// fixed-size sheet) UI and the inline ask cards. `replyChannel` records
/// how the answer goes back so the send path can answer in kind.
///
/// `expiresAt` is optional: `nil` for prompts that stay valid until
/// answered; when present, the sheet greys out the submit button and
/// shows "expired" copy past the deadline.
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
    /// The bridge-owned prompt id (`pr_<uuid>`) of a busy-queue
    /// `queued_release` card, `nil` for every other prompt. The bridge's
    /// durable release frames name cards by this id (not by seq), so it's
    /// what lets a "Send all" on one card retire the buttons on the rest —
    /// see `ChatViewModel.queuedReleaseAnswer(for:)`.
    public let queuedReleasePromptID: String?
    /// How a busy-queue card's message can be edited before the agent gets
    /// it, `nil` when it can't (or for any other prompt). See `QueuedEdit`.
    public let queuedEdit: QueuedEdit?

    /// A queued message the user can still edit. Tapping Edit answers the
    /// card with `edit`, which holds the message on the bridge's queue so
    /// it isn't delivered half-edited when the agent's turn ends; saving
    /// answers `edit_save` with the new text, which takes the message's
    /// place in the queue; cancelling answers `edit_cancel`, which releases
    /// the hold with the original text. The bridge releases a hold left
    /// open after `holdSeconds` and sends the original.
    public struct QueuedEdit: Equatable, Sendable {
        /// The queued message as the bridge holds it: the editor's start.
        public let text: String
        public let holdSeconds: Int

        public init(text: String, holdSeconds: Int) {
            self.text = text
            self.holdSeconds = holdSeconds
        }

        /// The card choices an edit sends.
        public static let holdChoice = "edit"
        public static let saveChoice = "edit_save"
        public static let cancelChoice = "edit_cancel"
    }

    public init(
        prompt: String,
        kind: InputKind,
        expiresAt: Date?,
        replyChannel: ReplyChannel = .textReply,
        queuedReleasePromptID: String? = nil,
        queuedEdit: QueuedEdit? = nil
    ) {
        self.prompt = prompt
        self.kind = kind
        self.expiresAt = expiresAt
        self.replyChannel = replyChannel
        self.queuedReleasePromptID = queuedReleasePromptID
        self.queuedEdit = queuedEdit
    }
}
