import SwiftUI
import MatronAuth
import MatronModels
import MatronViewModels

@main
struct MatronMacApp: App {
    @State private var dependencies = AppDependencies()
    @State private var session: UserSession?
    @State private var bootstrapDone = false

    var body: some Scene {
        WindowGroup {
            Group {
                if !bootstrapDone {
                    ProgressView("Loading…")
                        .frame(width: 480, height: 360)
                        .task { await bootstrap() }
                } else if let session {
                    MacChatListView(
                        viewModel: ChatListViewModel(chat: dependencies.chatService(for: session))
                    )
                    .frame(minWidth: 800, minHeight: 600)
                    .environment(\.appDependencies, dependencies)
                    .environment(\.currentSession, session)
                    .task { try? await dependencies.syncService(for: session).start() }
                } else {
                    MacSignInView(
                        viewModel: SignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron Mac"),
                        onSignedIn: { session in self.session = session }
                    )
                }
            }
            // Sign Out menu / toolbar: clear the persisted session, drop
            // in-memory caches, and flip `session = nil` so the SignInView
            // re-mounts. Without this listener the menu item posted to
            // the command bus but nothing observed it — sign-out was
            // silently a no-op (QA finding #2 + #7). Listener lives on
            // the WindowGroup root so it's attached regardless of which
            // child view (chat list, sign-in) is on screen.
            .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.signOut))) { _ in
                dependencies.signOut()
                session = nil
            }
        }
        .windowResizability(.contentMinSize)
        // Mac menu bar — File / Edit / View / Help shortcuts that post
        // to a `NotificationCenter` command bus. See `Commands.swift`
        // for the keyboard shortcuts and notification names.
        .commands { ChatCommands() }

        // Placeholder — Phase 7 fills in the full Settings UI. Phase 2
        // ships Sign Out via the File menu (`Commands.swift`), so even
        // without a Settings UI the user can swap accounts.
        Settings {
            Text("Settings — Phase 7 fills this in.")
                .padding()
                .frame(width: 480, height: 240)
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
}

// UNUserNotificationCenter.current().delegate registration is deferred
// to Phase 4 (Push & NSE).
