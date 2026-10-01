import SwiftUI
import MatronModels

/// The line under a reply of yours that the agent hasn't got yet (Dan,
/// 2026-10-01: "a queued one is marked as queued and has a Send now button,
/// so he never thinks it was sent when it wasn't"). A reply that reached the
/// agent draws nothing here — it looks like every other comment.
///
/// `onSendNow` answers the reply's queue card (`send_one`, or `send` where
/// the card can only release the whole queue). `nil` draws no button: a
/// button wired to nothing would look like a send and do none.
struct ItemReplyDeliveryLine: View {
    let state: QueuedReplyState
    let onSendNow: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(Self.text(for: state), systemImage: Self.symbol(for: state))
                .font(.caption)
                .foregroundStyle(Self.isFailure(state) ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            Spacer(minLength: 0)
            if case .sending = state {
                ProgressView().controlSize(.small)
            } else if Self.canSendNow(state), let onSendNow {
                Button("Send now", action: onSendNow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityHint("Delivers this reply to the agent now, interrupting its current turn")
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func canSendNow(_ state: QueuedReplyState) -> Bool {
        switch state {
        case .queued, .sendFailed: return true
        case .sending, .cancelled, .notDelivered: return false
        }
    }

    static func isFailure(_ state: QueuedReplyState) -> Bool {
        switch state {
        case .sendFailed, .cancelled, .notDelivered: return true
        case .queued, .sending: return false
        }
    }

    static func text(for state: QueuedReplyState) -> String {
        switch state {
        case .queued: return "Queued: the agent is mid-turn and hasn't seen this yet"
        case .sending: return "Sending now…"
        case .sendFailed(_, _, _, let reason): return "Still queued. \(reason)"
        case .cancelled: return "Not sent: cancelled from the conversation"
        case .notDelivered: return "Not delivered: the session ended before the agent got it"
        }
    }

    static func symbol(for state: QueuedReplyState) -> String {
        switch state {
        case .queued, .sending: return "clock"
        case .sendFailed, .notDelivered: return "exclamationmark.circle"
        case .cancelled: return "xmark.circle"
        }
    }
}
