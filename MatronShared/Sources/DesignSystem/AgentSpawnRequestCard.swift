import SwiftUI
import MatronEvents

/// The spawn consent card, inline in the timeline — one agent asking to
/// start a session on another box, and the two buttons that answer it.
///
/// Deliberately its own card rather than an `AskUserCard`, same as
/// `AgentChatRequestCard`: the decision rests on facts (who is asking, which
/// box, which folder, what the child session would do) a generic prompt has
/// nowhere to put, and its answer leaves over HTTP rather than into the
/// conversation — hence the explicit `state`.
///
/// Pure: plain values and closures only, so it stays in MatronDesignSystem
/// and snapshots directly.
public struct AgentSpawnRequestCard: View {
    public let request: AgentSpawnRequest
    public let state: AgentChatCardState
    /// Answers this one request. There is no standing consent to grant: the
    /// next ask gets its own card.
    public let onApprove: () -> Void
    public let onDeny: () -> Void

    public init(
        request: AgentSpawnRequest,
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
                Text("New session request").font(.callout.weight(.semibold))
            } icon: {
                Image(systemName: "macbook.and.iphone").foregroundStyle(.tint)
            }

            Text(request.headline).font(.body)

            // The facts the approval actually grants: which session is
            // asking, which box would run it, in which folder, doing what.
            // Degrades to device ids against an older journal rather than
            // vanishing — the ends and the task are the point of the card.
            detail(label: "From", value: request.fromLabel)
            detail(label: "On", value: request.targetLabel)
            detail(label: "Folder", value: request.workdir)
            detail(label: "Task", value: request.task)
            if let topic = request.topic {
                detail(label: "About", value: topic)
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
