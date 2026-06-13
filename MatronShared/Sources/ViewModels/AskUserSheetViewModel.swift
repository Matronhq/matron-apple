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
    /// The Matrix event ID of the prompt — the reply's correlation
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
    /// messaging app — and the SDK's FFI send isn't cooperatively
    /// cancellable mid-flight anyway, so a cancellation check here
    /// could only skip `onClose()`, not stop the wire write.
    /// "Dismissal = declining" applies to prompts dismissed WITHOUT
    /// Send. The view-layer `closeAskUserSheet` carries a same-prompt
    /// guard so this late `onClose()` can't tear down a successor
    /// prompt's sheet.
    public func send() async {
        guard !isExpired, !isSending, !hasSent else { return }
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
