import SwiftUI
import MatronChat
import MatronModels

/// Mac variant of `NewChatSheet`. The Mac and iOS app targets each carry
/// their own `AppDependencies` class (different storage container, different
/// entitlements), so the sheet itself is duplicated — the body is
/// platform-identical bar a `.frame` for the Mac sheet's content size and
/// the lack of `NavigationStack` (the Mac sheet doesn't get the iOS
/// navigation chrome).
///
/// See `Matron/Features/ChatList/NewChatSheet.swift` for the rationale on
/// deriving the bot list from the existing room snapshot rather than a
/// dedicated bot directory in Phase 2.
struct MacNewChatSheet: View {
    let deps: AppDependencies
    let session: UserSession
    let onCreated: (String) -> Void

    @State private var bots: [BotIdentity] = []
    @State private var creatingFor: BotIdentity?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New chat").font(.headline)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            List {
                Section("Pick a bot") {
                    ForEach(bots, id: \.matrixID) { bot in
                        Button {
                            Task { await create(with: bot) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bot.displayName).font(.body)
                                    Text(bot.matrixID).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if creatingFor == bot { ProgressView().controlSize(.small) }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(creatingFor != nil)
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(20)
        .frame(width: 420, height: 360)
        .task { await loadBots() }
    }

    private func loadBots() async {
        let chat = deps.chatService(for: session)
        for await snapshot in chat.chatSummaries() {
            let unique = Set(snapshot.map(\.bot))
            bots = Array(unique).sorted { $0.displayName < $1.displayName }
            break
        }
    }

    private func create(with bot: BotIdentity) async {
        creatingFor = bot
        defer { creatingFor = nil }
        do {
            let chat = deps.chatService(for: session)
            let roomID = try await chat.createChat(with: bot.matrixID)
            onCreated(roomID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
