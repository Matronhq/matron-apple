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

    /// Reads room-list snapshots to derive the unique-bot set. Re-polls
    /// on empty (1s × up to 30 attempts) for the same race that bit
    /// `ChatListViewModel`: `chatSummaries()` is single-shot per call
    /// (Phase 1/2 contract), and the first snapshot lands as soon as
    /// `sync.waitUntilReady()` returns — but `.running` doesn't
    /// guarantee any rooms have been downloaded.
    ///
    /// `didLoad` flips after the FIRST attempt regardless of whether
    /// it yielded bots — so a user with genuinely zero bots provisioned
    /// sees the empty state in ~1s instead of staring at a ProgressView
    /// for 30 seconds. Subsequent attempts refresh `bots` if a non-empty
    /// snapshot lands later.
    ///
    /// The whole retry loop goes away in Phase 2.5 (live chat-list); the
    /// long-lived stream there yields naturally when sliding sync warms
    /// up, no manual polling needed. See
    /// `docs/superpowers/plans/2026-05-05-matron-ios-phase-2-5-live-chat-list.md`.
    private func loadBots() async {
        let chat = deps.chatService(for: session)
        // Track the most recent stream error per-attempt so a transient
        // failure on attempt 1 (e.g. SyncReadyError.timeout while sync
        // is still warming up) doesn't bypass the remaining retries.
        var lastError: Error?
        for attempt in 0..<30 {
            if Task.isCancelled { return }
            var lastSnapshot: [ChatSummary] = []
            do {
                for try await snapshot in chat.chatSummaries() {
                    lastSnapshot = snapshot
                    // Load-bearing once `chatSummaries()` flips to a
                    // long-lived stream — without it, the inner loop
                    // would hang the sheet forever waiting on subsequent
                    // snapshots we don't need.
                    if !snapshot.isEmpty { break }
                }
                lastError = nil
            } catch {
                lastError = error
            }
            if !lastSnapshot.isEmpty {
                let unique = Set(lastSnapshot.map(\.bot))
                bots = Array(unique).sorted { $0.displayName < $1.displayName }
                didLoad = true
                return
            }
            // Show the empty state immediately after the first attempt
            // returns no bots. Background polling continues in case
            // sliding sync warms up later and bots appear.
            didLoad = true
            if attempt < 29 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        // If all 30 attempts produced empty snapshots AND the last one
        // threw, surface the upstream error in the same field as
        // createChat failures (QA finding #10). The empty-but-no-error
        // case (genuinely zero bots provisioned) keeps the empty-state
        // body the user is already seeing.
        if bots.isEmpty, let lastError {
            errorMessage = lastError.localizedDescription
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
