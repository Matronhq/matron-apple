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
                    ChatListView(viewModel: ChatListViewModel(chat: dependencies.chatService(for: session)))
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
}
