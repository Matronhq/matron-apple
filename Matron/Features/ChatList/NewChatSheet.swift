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
    /// Tracks whether the first snapshot has been processed. We can't
    /// use `bots.isEmpty` alone to gate the empty state, because a
    /// brand-new user with no rooms still gets an empty `bots` once
    /// `loadBots()` returns — but during the in-flight window the list
    /// would also flash the empty state. `false` until `loadBots()`
    /// completes; then `true` so the empty state can render if `bots`
    /// is still empty (QA finding #5).
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            // Mirror the chat list's no-rooms state — a first-time user
            // with no rooms (and therefore no bots derivable from the
            // room list) sees a `ContentUnavailableView` instead of a
            // silent empty list (QA finding #5).
            Group {
                if didLoad && bots.isEmpty {
                    ContentUnavailableView(
                        "No bots yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Provision one via dev-boxer to get started.")
                    )
                } else {
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
                }
            }
            .navigationTitle("New chat")
            .task { await loadBots() }
        }
    }

    /// Reads room-list snapshots from the long-lived Phase 2.5 broadcaster
    /// to derive the unique-bot set. The stream stays open for the
    /// lifetime of this `.task`; an empty first yield (sliding sync
    /// still warming up) just means the next yield will arrive once
    /// rooms land. `didLoad` flips on the first yield regardless of
    /// emptiness so a user with genuinely zero bots sees the empty
    /// state immediately rather than staring at a ProgressView. If a
    /// non-empty snapshot arrives, we refresh `bots` and return.
    /// Errors propagate through the stream and surface in
    /// `errorMessage`.
    private func loadBots() async {
        let chat = deps.chatService(for: session)
        do {
            for try await snapshot in chat.chatSummaries() {
                if Task.isCancelled { return }
                if !snapshot.isEmpty {
                    let unique = Set(snapshot.map(\.bot))
                    bots = Array(unique).sorted { $0.displayName < $1.displayName }
                    didLoad = true
                    return
                }
                // Empty snapshot — show the empty state so the user
                // isn't staring at a ProgressView, but keep iterating
                // in case bots arrive later.
                didLoad = true
            }
        } catch {
            errorMessage = error.localizedDescription
            didLoad = true
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
