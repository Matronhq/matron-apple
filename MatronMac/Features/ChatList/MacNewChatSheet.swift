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
    /// See iOS `NewChatSheet.didLoad` — gates the empty-state render so
    /// the first-snapshot in-flight window doesn't flash an
    /// `ContentUnavailableView` (QA finding #5).
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New chat").font(.headline)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            // Mirror the chat list's no-rooms state — first-time user
            // with no rooms sees a `ContentUnavailableView` instead of
            // a silent empty list (QA finding #5).
            if didLoad && bots.isEmpty {
                ContentUnavailableView(
                    "No bots yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Provision one via dev-boxer to get started.")
                )
            } else {
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
        }
        .padding(20)
        .frame(width: 420, height: 360)
        .task { await loadBots() }
    }

    /// Reads room-list snapshots to derive the unique-bot set. Re-polls
    /// on empty (1s × 30 attempts) for the same race that bit
    /// `ChatListViewModel` — see iOS `NewChatSheet.loadBots()` for the
    /// full rationale.
    private func loadBots() async {
        let chat = deps.chatService(for: session)
        do {
            for attempt in 0..<30 {
                if Task.isCancelled { return }
                var lastSnapshot: [ChatSummary] = []
                for try await snapshot in chat.chatSummaries() {
                    lastSnapshot = snapshot
                }
                if !lastSnapshot.isEmpty {
                    let unique = Set(lastSnapshot.map(\.bot))
                    bots = Array(unique).sorted { $0.displayName < $1.displayName }
                    break
                }
                if attempt < 29 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        } catch {
            // Surface the upstream stream error (e.g. SyncReadyError.timeout)
            // in the same field as createChat failures (QA finding #10).
            errorMessage = error.localizedDescription
        }
        didLoad = true
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
