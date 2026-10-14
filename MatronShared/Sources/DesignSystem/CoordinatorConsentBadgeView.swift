import SwiftUI
import MatronEvents

/// "Approved by the Coordinator — <reason>" on a spawn card the Coordinator
/// answered, with **Stop session** once the session it let start is
/// running: the one tap that overrules the Coordinator.
///
/// Pure: plain values and closures only, so it snapshots directly.
public struct CoordinatorConsentBadgeView: View {
    let badge: CoordinatorConsentBadge
    let onStopSession: ((String) -> Void)?

    public init(badge: CoordinatorConsentBadge, onStopSession: ((String) -> Void)?) {
        self.badge = badge
        self.onStopSession = onStopSession
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(badge.text, systemImage: badge.decision.decision == .approve ? "checkmark.shield" : "xmark.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            if let convoID = badge.stoppableConvoID, let onStopSession {
                stopControl(convoID: convoID, onStopSession: onStopSession)
            }
        }
    }

    @ViewBuilder
    private func stopControl(convoID: String, onStopSession: @escaping (String) -> Void) -> some View {
        switch badge.stop {
        case .idle, .failed:
            VStack(alignment: .leading, spacing: 4) {
                Button("Stop session", role: .destructive) { onStopSession(convoID) }
                    .buttonStyle(.bordered)
                    .font(.callout)
                if case .failed(let message) = badge.stop {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        case .sending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Stopping…").font(.callout).foregroundStyle(.secondary)
            }
        case .sent:
            Label("Stop sent to the session", systemImage: "stop.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
