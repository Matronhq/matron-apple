import SwiftUI
import MatronModels
import MatronViewModels

/// Settings → Device → Coordinator (app shell, spec §5b): shows the current
/// coordinator chat's title with Change and Clear, and the Routines screen.
/// Reads and writes the per-user key through `@AppStorage`, so the shell's
/// tab updates live.
struct CoordinatorSettingRow: View {
    let session: UserSession
    let deps: AppDependencies
    @AppStorage private var convoID: String?
    @State private var showingChooser = false
    @State private var saveError: String?
    @State private var consent: CoordinatorConsentStore
    /// The coordinator chat's stored title, loaded by the `.task` below.
    /// Never read from the store in `body`: a read on the main thread
    /// waits behind whatever else holds the database, and the screen
    /// cannot scroll meanwhile.
    @State private var storedTitle: (convoID: String, title: String?)?

    init(session: UserSession, deps: AppDependencies) {
        self.session = session
        self.deps = deps
        _convoID = AppStorage(CoordinatorSetting.defaultsKey(for: session.userID))
        _consent = State(initialValue: CoordinatorConsentStore(api: deps.coordinatorConsentService(for: session)))
    }

    /// The title once loaded, the conversation id until then.
    private var title: String? {
        guard let convoID else { return nil }
        guard let storedTitle, storedTitle.convoID == convoID else { return convoID }
        return storedTitle.title ?? convoID
    }

    private func save(_ id: String?) {
        Task { @MainActor in saveError = await deps.setCoordinator(id, for: session) }
    }

    var body: some View {
        Section("Coordinator") {
            if let title {
                LabeledContent("Conversation", value: title)
                Button("Change…") { showingChooser = true }
                Button("Clear", role: .destructive) { save(nil) }
            } else {
                Text("No coordinator conversation yet.").foregroundStyle(.secondary)
                Button("Choose…") { showingChooser = true }
            }
            consentToggle
            NavigationLink {
                RoutinesScreen(viewModel: deps.makeRoutinesViewModel(for: session))
            } label: {
                Label("Routines", systemImage: "clock.arrow.circlepath")
            }
            .accessibilityIdentifier("settings.routines")
        }
        .task { await consent.load() }
        .task(id: convoID) {
            guard let convoID else { return }
            let title = try? await deps.journalStore(for: session).conversationTitle(id: convoID)
            // A read for a conversation the user has since changed away
            // from finishes anyway; its title must not land.
            guard !Task.isCancelled else { return }
            storedTitle = (convoID, title.flatMap { $0.isEmpty ? nil : $0 })
        }
        .sheet(isPresented: $showingChooser) {
            CoordinatorChooserSheet(deps: deps, session: session) { id in
                showingChooser = false
                save(id)
            }
        }
        .alert("Coordinator", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    /// The journal's consent-approval switch, under the picker: on, the
    /// Coordinator may answer chat and spawn cards for the user (each card
    /// then says so, with its reason). Hidden until the journal answers,
    /// and for a journal without the switch.
    @ViewBuilder
    private var consentToggle: some View {
        if let enabled = consent.isEnabled {
            Toggle("Let the Coordinator approve chats and spawns", isOn: Binding(
                get: { enabled },
                set: { value in Task { await consent.set(value) } }))
            if let message = consent.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
