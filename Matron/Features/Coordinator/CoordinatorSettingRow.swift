import SwiftUI
import MatronModels

/// Settings → Device → Coordinator (app shell, spec §5b): shows the current
/// coordinator chat's title with Change and Clear. Reads and writes the
/// per-user key through `@AppStorage`, so the shell's tab updates live.
struct CoordinatorSettingRow: View {
    let session: UserSession
    let deps: AppDependencies
    @AppStorage private var convoID: String?
    @State private var showingChooser = false

    init(session: UserSession, deps: AppDependencies) {
        self.session = session
        self.deps = deps
        _convoID = AppStorage(CoordinatorSetting.defaultsKey(for: session.userID))
    }

    private var title: String? {
        guard let convoID else { return nil }
        let stored = (try? deps.journalStore(for: session).conversation(id: convoID))?.title
        return (stored?.isEmpty == false) ? stored : convoID
    }

    var body: some View {
        Section("Coordinator") {
            if let title {
                LabeledContent("Conversation", value: title)
                Button("Change…") { showingChooser = true }
                Button("Clear", role: .destructive) { convoID = nil }
            } else {
                Text("No coordinator conversation yet.").foregroundStyle(.secondary)
                Button("Choose…") { showingChooser = true }
            }
        }
        .sheet(isPresented: $showingChooser) {
            CoordinatorChooserSheet(deps: deps, session: session) { id in
                convoID = id
                showingChooser = false
            }
        }
    }
}
