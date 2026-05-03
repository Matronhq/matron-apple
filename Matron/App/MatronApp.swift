import SwiftUI
import MatronAuth
import MatronModels
import MatronViewModels

@main
struct MatronApp: App {
    @State private var dependencies = AppDependencies()
    @State private var session: UserSession?
    @State private var bootstrapDone = false

    var body: some Scene {
        WindowGroup {
            Group {
                if !bootstrapDone {
                    ProgressView("Loading…")
                        .task { await bootstrap() }
                } else if let session {
                    NavigationStack {
                        ChatListView(
                            viewModel: ChatListViewModel(chat: dependencies.chatService(for: session)),
                            onSignOut: { signOut() }
                        )
                    }
                    .environment(\.appDependencies, dependencies)
                    .environment(\.currentSession, session)
                    .task { try? await dependencies.syncService(for: session).start() }
                } else {
                    SignInView(
                        viewModel: SignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron iOS"),
                        onSignedIn: { session in self.session = session }
                    )
                }
            }
        }
    }

    private func bootstrap() async {
        do {
            session = try await dependencies.auth.restoreSession()
        } catch {
            session = nil
        }
        bootstrapDone = true
    }

    /// Sign-out path. Phase-7 spec lands a full Settings → Account → Sign
    /// Out flow; Phase 2 wires the menu / toolbar hook now (QA finding
    /// #7) so swapping accounts on iOS doesn't require deleting the
    /// app's Application Support directory. Drops the in-memory session
    /// state and clears the persisted session + caches via
    /// `AppDependencies.signOut()` — the resulting `session == nil`
    /// branch re-mounts the SignInView.
    private func signOut() {
        dependencies.signOut()
        session = nil
    }
}
