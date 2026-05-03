import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// Mac analogue of `BotProfileView` (iOS Task 15). Renders as a
/// **full-window sheet** (`.sheet(isPresented:)`) rather than the iOS
/// half-sheet, per spec §5.9: "single main window — no third column."
///
/// Reuses the shared `BotProfileViewModel` from `MatronShared` unchanged —
/// no Mac-specific data model. Layout differs from iOS:
///   - Header card uses larger 80pt avatar, `.title2` display name.
///   - List sits below a `Divider`, scrollable.
///   - "Done" button in `.confirmationAction` toolbar slot for keyboard
///     dismissal (Esc / ⌘W via the host sheet).
///   - Frame sized to a Mac-appropriate sheet (480×540 minimum).
///
/// Wired from `MacChatListView`'s detail-column construction (Task 13c
/// placeholder swap) and routed via `MacChatToolbar`'s ⓘ button (Task 14d).
struct MacBotProfileSheet: View {
    @State var viewModel: BotProfileViewModel
    let onSelectChat: (ChatSummary) -> Void
    let onStartNewChat: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerCard
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 24)

            Divider()

            // All chats list. `.frame(minHeight:)` keeps the section
            // visible even when there are zero chats (the empty-state
            // text needs vertical space).
            List {
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
            .frame(minHeight: 240)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 540, idealHeight: 640)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Header section — avatar placeholder, display name, Matrix ID with
    /// a copy button (`Pasteboard` is public in `MatronDesignSystem`),
    /// and a "Start new chat" CTA. Sized larger than the iOS variant
    /// because the Mac sheet has more headroom.
    @ViewBuilder
    private var headerCard: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(.secondary.opacity(0.2))
                .frame(width: 80, height: 80)
                .overlay {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(10)
                }
            Text(viewModel.bot.displayName)
                .font(.title2)
                .bold()
            HStack(spacing: 6) {
                Text(viewModel.bot.matrixID)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button {
                    Pasteboard.copy(viewModel.bot.matrixID)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy Matrix ID")
                .accessibilityLabel("Copy Matrix ID")
            }
            Button("Start new chat", action: onStartNewChat)
                .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func chatRow(_ summary: ChatSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                if let lastActivity = summary.lastActivity {
                    Text(lastActivity, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if summary.unreadCount > 0 {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
            }
        }
        .contentShape(Rectangle())
    }
}
