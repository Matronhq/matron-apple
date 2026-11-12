import Foundation
import MatronChat
import MatronEvents

/// Drives the ask-user sheet (iOS half-sheet `AskUserSheet`, Mac
/// fixed-size `MacAskUserSheet`) for one prompt. Target-agnostic —
/// both wrappers bind the same instance against the shared
/// `AskUserSheetBody` from MatronDesignSystem.
///
/// The send path answers on the wire protocol the prompt arrived on
/// (`event.replyChannel`): plain text + `m.in_reply_to` for
/// `chat.matron.ask_user` events (spec §4.2), or a
/// `chat.matron.button_response` raw event for the bridge's live
/// buttons protocol.
@Observable
@MainActor
public final class AskUserSheetViewModel {
    public let event: AskUserEvent
    /// The prompt's journal seq — the reply's correlation
    /// target, and the View's `.task(id:)` key for the expiry timer.
    public let promptEventID: String
    public var textInput: String = ""
    public var selectedChoiceIDs: Set<String> = []
    public var booleanAnswer: Bool?
    public private(set) var isSending = false
    public private(set) var error: String?
    /// Set once a send has reached the wire successfully. Together with
    /// `isSending` it makes `send()` idempotent: a second Send tap while
    /// the first is suspended on the timeline call, or after success but
    /// before the dismiss animation lands, must not answer the same
    /// prompt twice (bugbot PR #6 finding "double submit sends
    /// duplicate answers"). Errors leave it false so retry stays open.
    private var hasSent = false

    private let timeline: TimelineService
    private let onClose: () -> Void

    public init(
        event: AskUserEvent,
        promptEventID: String,
        timeline: TimelineService,
        onClose: @escaping () -> Void
    ) {
        self.event = event
        self.promptEventID = promptEventID
        self.timeline = timeline
        self.onClose = onClose
    }

    /// True once `expiresAt` has passed. UI uses this to disable Send;
    /// `awaitExpiry` auto-dismisses the sheet at the same moment.
    public var isExpired: Bool {
        guard let expiresAt = event.expiresAt else { return false }
        return Date.now >= expiresAt
    }

    /// Deliberate semantics (bugbot PR #6 finding "dismissed sheet
    /// still sends answer", resolved as by-design): tapping Send is a
    /// commitment. Dismissing the sheet while the send is suspended on
    /// the timeline call does NOT revoke the in-flight answer — same
    /// convention as closing a composer after hitting send in any
    /// messaging app — and a send already handed to the sync engine
    /// isn't cancellable mid-flight anyway, so a cancellation check here
    /// could only skip `onClose()`, not stop the wire write.
    /// "Dismissal = declining" applies to prompts dismissed WITHOUT
    /// Send. The view-layer `closeAskUserSheet` carries a same-prompt
    /// guard so this late `onClose()` can't tear down a successor
    /// prompt's sheet.
    public func send() async {
        // Not while an edit holds the message, or is on its way to: Send now
        // would deliver the original the edit is replacing.
        guard !isExpired, !isSending, !hasSent, !isEditing, !isSendingEdit else { return }
        isSending = true
        defer { isSending = false }
        do {
            switch event.replyChannel {
            case .textReply:
                let body = constructReplyBody()
                guard !body.isEmpty else { return }
                // Spec §4.2: `m.in_reply_to` correlates the answer back
                // to the originating ask_user prompt event.
                try await timeline.sendText(body, inReplyTo: promptEventID)
            case .buttonResponse:
                let values = selectedValues()
                guard !values.isEmpty else { return }
                try await timeline.sendButtonResponse(
                    selectedValues: values,
                    inReplyTo: promptEventID
                )
            }
            hasSent = true
            onClose()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Editing a queued message

    /// The editor's text while a queued message is being edited.
    public var editText: String = ""
    /// The message is held on the bridge's queue and the editor is open.
    public private(set) var isEditing = false
    /// An Edit, Save or Cancel edit is on its way to the journal.
    public private(set) var isSendingEdit = false
    public private(set) var editError: String?

    /// Whether this card offers Edit at all (`AskUserEvent.QueuedEdit`).
    public var offersEdit: Bool { event.queuedEdit != nil && !hasSent && !isExpired }

    /// Save is pointless on an empty editor: the bridge refuses an empty edit.
    public var canSaveEdit: Bool {
        !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Edit: hold the message on the bridge's queue, then open the editor
    /// with its text. The editor only opens once the hold has reached the
    /// journal, so an edit never runs while the message can still go out.
    public func beginEdit() async {
        guard let edit = event.queuedEdit, !isEditing, !isSendingEdit, !hasSent else { return }
        isSendingEdit = true
        defer { isSendingEdit = false }
        do {
            try await timeline.sendQueuedEdit(choice: AskUserEvent.QueuedEdit.holdChoice, text: nil,
                                              inReplyTo: promptEventID)
            editText = edit.text
            editError = nil
            isEditing = true
        } catch {
            editError = "Couldn't hold the message for editing. \(error.localizedDescription)"
        }
    }

    /// Save: the edited text takes the message's place in the queue (or
    /// goes at once if the agent finished its turn meanwhile). An unchanged
    /// text just releases the hold.
    public func saveEdit() async {
        guard isEditing, !isSendingEdit, !hasSent else { return }
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text == event.queuedEdit?.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            await cancelEdit()
            return
        }
        isSendingEdit = true
        defer { isSendingEdit = false }
        do {
            try await timeline.sendQueuedEdit(choice: AskUserEvent.QueuedEdit.saveChoice, text: text,
                                              inReplyTo: promptEventID)
            hasSent = true
            isEditing = false
            editError = nil
            onClose()
        } catch {
            editError = "Couldn't save the edit. \(error.localizedDescription)"
        }
    }

    /// Cancel edit: release the hold; the message keeps its original text.
    /// The editor closes either way: a release that doesn't reach the
    /// bridge still ends when the hold times out.
    public func cancelEdit() async {
        guard isEditing, !isSendingEdit else { return }
        isSendingEdit = true
        defer { isSendingEdit = false }
        isEditing = false
        do {
            try await timeline.sendQueuedEdit(choice: AskUserEvent.QueuedEdit.cancelChoice, text: nil,
                                              inReplyTo: promptEventID)
            editError = nil
        } catch {
            let minutes = max(1, (event.queuedEdit?.holdSeconds ?? 600) / 60)
            editError = "Couldn't release the message. It goes with its original text within \(minutes) minutes."
        }
    }

    /// Sleeps until `event.expiresAt`, then calls `onExpire` (unless
    /// cancelled). Driven by the View's `.task(id: promptEventID)`
    /// modifier; no-op for prompts without an expiry.
    public func awaitExpiry(onExpire: @escaping () -> Void) async {
        guard let expiresAt = event.expiresAt else { return }
        let interval = max(0, expiresAt.timeIntervalSinceNow)
        try? await Task.sleep(for: .seconds(interval))
        if !Task.isCancelled { onExpire() }
    }

    /// Reply body for the `.textReply` channel: the chosen option's
    /// label per spec §4.2, the free-text input, or Yes/No.
    private func constructReplyBody() -> String {
        switch event.kind {
        case .text:
            return textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        case .choice(let options, _):
            guard let id = selectedChoiceIDs.first,
                  let opt = options.first(where: { $0.id == id }) else {
                // No option picked — fall back to the "Other…" field
                // (rendered when `allowOther`; empty otherwise).
                return textInput.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return opt.label
        case .multiChoice(let options, _):
            var chosen = options.filter { selectedChoiceIDs.contains($0.id) }.map(\.label)
            let other = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !other.isEmpty { chosen.append(other) }
            return chosen.joined(separator: ", ")
        case .boolean:
            switch booleanAnswer {
            case true?: return "Yes"
            case false?: return "No"
            case nil: return ""
            }
        }
    }

    /// Wire `value`s for the `.buttonResponse` channel, in option
    /// order. The buttons protocol only produces choice/multiChoice
    /// kinds and has no "Other" affordance; the remaining kinds return
    /// empty (send() then refuses), defensive only.
    private func selectedValues() -> [String] {
        switch event.kind {
        case .choice(let options, _), .multiChoice(let options, _):
            return options.filter { selectedChoiceIDs.contains($0.id) }.map(\.value)
        case .text, .boolean:
            return []
        }
    }
}
