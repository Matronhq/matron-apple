import SwiftUI
import MatronEvents

/// "Approved by the Coordinator — <reason>" on a spawn card the Coordinator
/// answered, with **Stop session** once the session it let start is
/// running: the tap that overrules the Coordinator. The tap only asks; the
/// chat screen confirms (`stopSessionConfirmation`) before anything is sent.
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

/// The confirmation a Stop session tap opens. `/stop` is queued through the
/// outbox and cannot be taken back, so a mis-tap on the badge must not stop
/// a running session. Hung on the chat screen rather than on the badge: the
/// badge draws inside a timeline cell, which has no view controller to
/// present from.
public enum StopSessionConfirmation {
    public static let title = "Stop this session?"
    public static let message = "It stops right away, even in the middle of a task. Its conversation stays, and you can resume it later."
    public static let confirm = "Stop Session"
}

extension View {
    /// Asks "Stop this session?" while `pendingConvoID` is set; Stop Session
    /// calls `onConfirm` with that conversation, Cancel or dismissing it
    /// calls `onCancel` and sends nothing.
    public func stopSessionConfirmation(pendingConvoID: String?,
                                        onConfirm: @escaping (String) -> Void,
                                        onCancel: @escaping () -> Void) -> some View {
        confirmationDialog(StopSessionConfirmation.title,
                           isPresented: Binding(get: { pendingConvoID != nil },
                                                set: { if !$0 { onCancel() } }),
                           titleVisibility: .visible,
                           presenting: pendingConvoID) { convoID in
            Button(StopSessionConfirmation.confirm, role: .destructive) { onConfirm(convoID) }
                .accessibilityIdentifier("stopSession.confirm")
            Button("Cancel", role: .cancel) { onCancel() }
        } message: { _ in
            Text(StopSessionConfirmation.message)
        }
    }
}
