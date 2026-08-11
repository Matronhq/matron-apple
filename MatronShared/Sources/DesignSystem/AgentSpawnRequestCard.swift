import SwiftUI
import MatronEvents

/// The agent-spawn consent card, inline in the timeline — one agent asking to
/// start another on a box, in a folder, on a task — and the two buttons that
/// answer it.
///
/// Its own card rather than an `AskUserCard` for the same reasons as
/// `AgentChatRequestCard`: the facts a consent decision rests on (who, where,
/// what) have nowhere to live in a generic prompt, and the answer leaves over
/// HTTP rather than into the conversation.
///
/// Unlike the agent-chat card, `resolved` is not a remembered local decision:
/// it carries the journal's own `spawn_outcome`, which is why a started spawn
/// can offer to open the room it created.
///
/// Pure: plain values and closures only, so it stays in MatronDesignSystem
/// and snapshots directly.
public struct AgentSpawnRequestCard: View {
    public let request: AgentSpawnRequest
    public let state: AgentSpawnCardState
    /// Answers this one request. There is no standing consent to grant: the
    /// next spawn from the same agent gets its own card.
    public let onApprove: () -> Void
    public let onDeny: () -> Void
    /// Opens the room a started spawn talks in. `nil` in contexts with
    /// nowhere to navigate (previews, tests) — the button is then omitted
    /// rather than drawn dead.
    public let onOpen: ((String) -> Void)?

    public init(
        request: AgentSpawnRequest,
        state: AgentSpawnCardState,
        onApprove: @escaping () -> Void,
        onDeny: @escaping () -> Void,
        onOpen: ((String) -> Void)? = nil
    ) {
        self.request = request
        self.state = state
        self.onApprove = onApprove
        self.onDeny = onDeny
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Agent spawn request").font(.callout.weight(.semibold))
            } icon: {
                Image(systemName: "sparkles.rectangle.stack").foregroundStyle(.tint)
            }

            Text(request.headline).font(.body)

            // Who is asking, where it would run, and in which folder — the
            // three facts that make this a decision rather than a formality.
            detail(label: "From", value: request.fromLabel)
            detail(label: "Target", value: request.targetLabel)
            if !request.workdir.isEmpty {
                detail(label: "Folder", value: request.workdir)
            }

            // The seed prompt, verbatim and monospaced: approving this card
            // is approving these exact words, so they are never summarised.
            Text(request.task)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))

            switch state {
            case .idle, .sending, .failed:
                controls
            case .resolved(let outcome):
                resolution(outcome)
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

    /// How it ended, in the journal's own words — plus a way into the room
    /// when a session actually started.
    ///
    /// No SF Symbol beside the text: `displayLine` already opens with the
    /// server's emoji, and pairing the two makes every resolved row read
    /// twice. The expired case is the exception, and it borrows the
    /// agent-chat card's sentence verbatim — a 409 and a swept 24h ask are
    /// the same fact to the user.
    @ViewBuilder
    private func resolution(_ outcome: SpawnOutcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if outcome.kind == .expired {
                Text("This request is no longer waiting for an answer.")
            } else {
                Text(outcome.displayLine)
            }
            if let roomID = outcome.openableRoomID, let onOpen {
                Button("Open") { onOpen(roomID) }
                    .buttonStyle(.bordered)
                    .font(.callout)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func detail(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
        }
    }
}
