import SwiftUI
import MatronEvents

/// The agent-chat consent card, inline in the timeline — one agent asking to
/// talk to another, and the two buttons that answer it.
///
/// Deliberately its own card rather than an `AskUserCard`: a consent decision
/// rests on facts (who is asking, about what, and why) that a generic prompt
/// has nowhere to put, and its answer leaves over HTTP rather than into the
/// conversation, so there is no timeline echo to read the outcome back from —
/// hence the explicit `state`.
///
/// Pure: plain values and closures only, so it stays in MatronDesignSystem
/// and snapshots directly.
public struct AgentChatRequestCard: View {
    public let request: AgentChatRequest
    public let state: AgentChatCardState
    /// Answers this one request. There is no standing consent to grant: the
    /// next ask from the same pair gets its own card.
    public let onApprove: () -> Void
    public let onDeny: () -> Void

    public init(
        request: AgentChatRequest,
        state: AgentChatCardState,
        onApprove: @escaping () -> Void,
        onDeny: @escaping () -> Void
    ) {
        self.request = request
        self.state = state
        self.onApprove = onApprove
        self.onDeny = onDeny
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Agent chat request").font(.callout.weight(.semibold))
            } icon: {
                Image(systemName: "person.2.wave.2.fill").foregroundStyle(.tint)
            }

            Text(request.headline).font(.body)

            // Which session on each side, in the form the conversation list
            // uses, so the user can match the ask against a chat they know.
            // Against an older journal that names no sessions these degrade
            // to the device alone rather than vanishing — the two ends are
            // the point of the card, so they always get a row.
            detail(label: "From", value: request.fromLabel)
            detail(label: "To", value: request.toLabel)

            if let topic = request.topic {
                detail(label: "About", value: topic)
            }
            if let justification = request.justification {
                detail(label: "Why", value: justification)
            }

            switch state {
            case .idle, .sending, .failed:
                controls
            case .answered(let approved):
                Label {
                    Text(approved ? "Approved" : "Declined")
                } icon: {
                    Image(systemName: approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(approved ? .green : .secondary)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            case .expired:
                // The row stopped awaiting an answer: it timed out (24h), or
                // the decision was already made on another device. Either
                // way there is nothing left to press.
                Text("This request is no longer waiting for an answer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if case .failed(let message) = state {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.matronBubbleBot)
                .shadow(color: .matronBubbleShadow, radius: 2, y: 1)
        )
    }

    @ViewBuilder
    private var controls: some View {
        // The peer's own words, quoted above; below, only the user's choice.
        HStack(spacing: 8) {
            Button("Decline", action: onDeny)
                .buttonStyle(.bordered)
            Button("Approve", action: onApprove)
                .buttonStyle(.borderedProminent)
            if state == .sending {
                ProgressView().controlSize(.small)
            }
        }
        .disabled(state == .sending)
    }

    private func detail(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }
}
