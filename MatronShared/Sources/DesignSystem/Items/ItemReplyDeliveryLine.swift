import SwiftUI
import MatronModels

/// The line under a reply of yours that the agent hasn't got yet
/// ("a queued one is marked as queued and has a Send now button,
/// so he never thinks it was sent when it wasn't"; 2026-10-06: "we should
/// also have cancel there"). A reply that reached the agent draws nothing
/// here — it looks like every other comment.
///
/// `onSendNow` answers the reply's queue card (`send_one`, or `send` where
/// the card can only release the whole queue); `onCancel` answers it with
/// `cancel`, which withdraws just this reply. `onEditAndResend` puts a reply
/// that never reached the agent back in the reply box. A `nil` handler draws
/// no button: a button wired to nothing would look like it acted and do
/// nothing.
struct ItemReplyDeliveryLine: View {
    let state: QueuedReplyState
    let onSendNow: (() -> Void)?
    var onCancel: (() -> Void)? = nil
    var onEditAndResend: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(Self.text(for: state), systemImage: Self.symbol(for: state))
                .font(.caption)
                .foregroundStyle(Self.isFailure(state) ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            Spacer(minLength: 0)
            if Self.isAwaitingBridge(state) {
                ProgressView().controlSize(.small)
            } else if Self.canSendNow(state) {
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityHint("Withdraws this reply before the agent sees it. It stays here, marked as not sent")
                }
                if let onSendNow {
                    Button("Send now", action: onSendNow)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityHint(Self.sendNowHint(state))
                }
            } else if Self.canResend(state), let onEditAndResend {
                Button("Edit and resend", action: onEditAndResend)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("Puts this reply's text in the reply box to send again")
            }
        }
        // Each button stays its own element: combined, Cancel and Send now
        // would merge into one ambiguous action.
        .accessibilityElement(children: .contain)
    }

    /// A tap made here is waiting on the bridge's release.
    static func isAwaitingBridge(_ state: QueuedReplyState) -> Bool {
        switch state {
        case .sending, .cancelling: return true
        default: return false
        }
    }

    /// Still on the busy queue, so Send now and Cancel both apply.
    static func canSendNow(_ state: QueuedReplyState) -> Bool {
        switch state {
        case .queued, .sendFailed: return true
        case .sending, .cancelling, .cancelled, .notDelivered: return false
        }
    }

    /// Never reached the agent and never will: worth sending again.
    static func canResend(_ state: QueuedReplyState) -> Bool {
        switch state {
        case .cancelled, .notDelivered: return true
        case .queued, .sending, .cancelling, .sendFailed: return false
        }
    }

    /// Honest about the card's reach: one that can't release a single
    /// reply sends everything queued for the agent, as in the conversation.
    static func sendNowHint(_ state: QueuedReplyState) -> String {
        switch state {
        case .queued(_, _, false), .sendFailed(_, _, false, _):
            return "Delivers this reply to the agent now, with anything else queued for it, interrupting its current turn"
        default:
            return "Delivers this reply to the agent now, interrupting its current turn"
        }
    }

    static func isFailure(_ state: QueuedReplyState) -> Bool {
        switch state {
        case .sendFailed, .cancelled, .notDelivered: return true
        case .queued, .sending, .cancelling: return false
        }
    }

    static func text(for state: QueuedReplyState) -> String {
        switch state {
        case .queued: return "Queued: the agent is mid-turn and hasn't seen this yet"
        case .sending: return "Sending now…"
        case .cancelling: return "Cancelling…"
        case .sendFailed(_, _, _, let reason): return "Still queued. \(reason)"
        case .cancelled: return "Cancelled: not sent to the agent"
        case .notDelivered: return "Not delivered: the session ended before the agent got it"
        }
    }

    static func symbol(for state: QueuedReplyState) -> String {
        switch state {
        case .queued, .sending: return "clock"
        case .sendFailed, .notDelivered: return "exclamationmark.circle"
        case .cancelling, .cancelled: return "xmark.circle"
        }
    }
}
