import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// iOS bot-profile sheet — surfaced from `ChatView`'s ⓘ toolbar button. Shows
/// the bot's display name, Matrix ID, and the list of all chats with that
/// bot derived from a `chatSummaries()` snapshot at construction time.
///
/// Phase 1 deferred Phase-3 SDK calls to fetch the bot's full profile
/// (avatar mxc, description). Phase 2 renders just what `BotIdentity` carries
/// today: a `displayName`, `matrixID`, and an `avatarURL?` placeholder.
///
/// "Start new chat" and the row taps both dismiss the sheet via callbacks
/// owned by `ChatListView` (the route owner). The view itself is otherwise
/// pure — no `@Environment(\.appDependencies)` reach-around.
struct BotProfileView: View {
    @State var viewModel: BotProfileViewModel
    let onSelectChat: (ChatSummary) -> Void
    let onStartNewChat: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    headerCard
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                Section("All chats") {
                    if viewModel.chatsForBot.isEmpty {
                        Text("No chats with this bot yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.chatsForBot) { summary in
                            Button {
                                onSelectChat(summary)
                            } label: {
                                chatRow(summary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Bot")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// Header section: avatar placeholder, display name, Matrix ID with a
    /// "copy" button (Pasteboard was promoted to public in Task 14c), and a
    /// primary "Start new chat" CTA.
    @ViewBuilder
    private var headerCard: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(.secondary.opacity(0.2))
                .frame(width: 64, height: 64)
                .overlay {
                    // Phase-3 SDK lookup will swap this for the real avatar.
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            Text(viewModel.bot.displayName)
                .font(.title3)
                .bold()
            HStack(spacing: 6) {
                Text(viewModel.bot.matrixID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button {
                    Pasteboard.copy(viewModel.bot.matrixID)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy Matrix ID")
            }
            Button("Start new chat", action: onStartNewChat)
                .buttonStyle(.borderedProminent)
        }
    }

    /// One row in the "All chats" section. Title on top, relative-time
    /// caption underneath when known.
    @ViewBuilder
    private func chatRow(_ summary: ChatSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .foregroundStyle(.primary)
                if let lastActivity = summary.lastActivity {
                    Text(lastActivity, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if summary.unreadCount > 0 {
                Circle()
                    .fill(.blue)
                    .frame(width: 8, height: 8)
            }
        }
        .contentShape(Rectangle())
    }
}
