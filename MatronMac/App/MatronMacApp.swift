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
        }
        .windowResizability(.contentMinSize)
        // Mac menu bar — File / Edit / View / Help shortcuts that post
        // to a `NotificationCenter` command bus. See `Commands.swift`
        // for the keyboard shortcuts and notification names.
        .commands { ChatCommands() }

        // Placeholder — Phase 7 fills in the full Settings UI.
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
