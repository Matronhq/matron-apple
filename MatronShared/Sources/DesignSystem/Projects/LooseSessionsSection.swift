import SwiftUI
import MatronModels

/// "Not on a mission (n)" at the top of the Chats list (spec §6: the loose
/// sessions group moved off the Projects home). Collapsed by default; a
/// plain button header so it works in every list style.
public struct LooseSessionsSection: View {
    let sessions: [DashboardSession]
    @Binding var isExpanded: Bool
    let onOpen: (String) -> Void
    public init(sessions: [DashboardSession], isExpanded: Binding<Bool>, onOpen: @escaping (String) -> Void) {
        self.sessions = sessions; self._isExpanded = isExpanded; self.onOpen = onOpen
    }

    public var body: some View {
        if !sessions.isEmpty {
            Section {
                if isExpanded {
                    ForEach(sessions) { session in
                        Button { onOpen(session.id) } label: { DashboardSessionRow(session: session, showsNeedsYou: true) }
                            .buttonStyle(.plain).foregroundStyle(Color.primary)
                    }
                }
            } header: {
                Button { isExpanded.toggle() } label: {
                    HStack {
                        Text("Not on a mission (\(sessions.count))")
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chats.looseToggle")
            }
        }
    }
}
