import SwiftUI
import MatronModels

/// A compact card for a running session on no mission (spec §3.3).
public struct LooseSessionCardView: View {
    let session: DashboardSession
    let onOpen: () -> Void

    public init(session: DashboardSession, onOpen: @escaping () -> Void) {
        self.session = session; self.onOpen = onOpen
    }

    public var body: some View {
        Button(action: onOpen) {
            DashboardSessionRow(session: session, showsNeedsYou: true)
                .padding(12)
                .modifier(DashboardCardChrome())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .accessibilityIdentifier("missions.loose.\(session.id)")
    }
}
