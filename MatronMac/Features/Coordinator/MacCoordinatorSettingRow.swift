import SwiftUI
import MatronModels
import MatronViewModels

/// Settings → General → Coordinator (app shell, spec §5b): current chat's
/// title with Change and Clear, through `@AppStorage` on the per-user key.
struct MacCoordinatorSettingRow: View {
    let session: UserSession
    let deps: AppDependencies
    @AppStorage private var convoID: String?
    @State private var showingChooser = false
    @State private var saveError: String?
    @State private var consent: CoordinatorConsentStore

    init(session: UserSession, deps: AppDependencies) {
        self.session = session
        self.deps = deps
        _convoID = AppStorage(CoordinatorSetting.defaultsKey(for: session.userID))
        _consent = State(initialValue: CoordinatorConsentStore(api: deps.coordinatorConsentService(for: session)))
    }

    private var title: String? {
        guard let convoID else { return nil }
        let stored = (try? deps.journalStore(for: session).conversation(id: convoID))?.title
        return (stored?.isEmpty == false) ? stored : convoID
    }

    private func save(_ id: String?) {
        Task { @MainActor in saveError = await deps.setCoordinator(id, for: session) }
    }

    var body: some View {
        Section("Coordinator") {
            if let title {
                LabeledContent("Conversation", value: title)
                HStack {
                    Button("Change…") { showingChooser = true }
                    Button("Clear", role: .destructive) { save(nil) }
                }
            } else {
                Text("No coordinator conversation yet.").foregroundStyle(.secondary)
                Button("Choose…") { showingChooser = true }
            }
            consentToggle
        }
        .task { await consent.load() }
        .sheet(isPresented: $showingChooser) {
            MacCoordinatorChooserSheet(deps: deps, session: session) { id in
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
