import SwiftUI
import MatronChat
import MatronModels

/// `+` toolbar sheet on the iOS chat list (and reused by the Mac variant).
/// Phase 2 doesn't fetch a separate bot directory — instead we collapse the
/// existing room list into a `Set<BotIdentity>` so any bot you've already
/// chatted with shows up as an option. Discovery of brand-new bots is the
/// onboarding/admin path and lands later.
///
/// Selecting a bot calls `ChatService.createChat(with:)` and then `onCreated`
/// with the new room id so the parent view can dismiss + navigate. The
/// sheet purposely owns its own state (`bots`, `creatingFor`, `errorMessage`)
/// instead of leaning on the parent — that keeps the iOS and Mac sheets a
/// drop-in swap for their respective placeholders.
struct NewChatSheet: View {
    let deps: AppDependencies
    let session: UserSession
    let onCreated: (String) -> Void

    @State private var bots: [BotIdentity] = []
    @State private var creatingFor: BotIdentity?
    /// Renamed from the plan's `error` to avoid shadowing the catch-binding
    /// in `create(with:)` — Swift's local `let error = error` form is
    /// readable but the shadow is easy to miss when scanning. The state
    /// holds the localized description; nil means no error is shown.
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
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
                                if creatingFor == bot { ProgressView() }
                            }
                        }
                        .disabled(creatingFor != nil)
                    }
                }
            }
            .navigationTitle("New chat")
            .task { await loadBots() }
        }
    }

    /// Reads the first room-list snapshot to derive the unique-bot set.
    /// Live `chatSummaries()` keeps the stream open in Phase 2, so we
    /// `break` after the first snapshot — re-opening the sheet picks up
    /// any newly-arrived bots from the next subscription. The fake stream
    /// finishes after yielding queued snapshots, so the `break` keeps
    /// tests deterministic.
    private func loadBots() async {
        let chat = deps.chatService(for: session)
        for await snapshot in chat.chatSummaries() {
            let unique = Set(snapshot.map(\.bot))
            bots = Array(unique).sorted { $0.displayName < $1.displayName }
            break
        }
    }

    /// Invokes `ChatService.createChat(with:)` and surfaces the new room id
    /// via `onCreated`. Failures land in `errorMessage`; the input list is
    /// not cleared so the user can retry without losing the bot list.
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
