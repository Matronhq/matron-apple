import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// The "Copy N Messages" item — its own View so the controller reads
/// happen in THIS leaf's body, not in the row's (the `.contextMenu`
/// builder runs during the row's body evaluation; reading observable
/// state there would make every mounted row observe the selection and
/// the streaming `windowedRows`, invalidating all ~185 rows per commit
/// and bypassing the per-row `Equatable` gate below).
///
/// The body reads exactly two things: `hasSelection` (the controller's only
/// observed property) and `finishedTranscript` (`@ObservationIgnored`, a
/// snapshot taken at `finish()`). It must NOT call `transcriptProvider()` —
/// that closure reads the view model's `windowedRows`, which would enrol this
/// menu's host row in the streaming timeline's observation and undo the fence
/// described above. Copying the captured text (rather than re-deriving it)
/// also settles the click race: the click is a left mouse down, which the
/// controller's clear-monitor answers by clearing the selection.
private struct MacSelectionCopyMenuItems: View {
    @Environment(MessageSelectionController.self) private var messageSelection: MessageSelectionController?

    var body: some View {
        if let messageSelection, messageSelection.hasSelection,
           let transcript = messageSelection.finishedTranscript, transcript.messageCount > 0 {
            let count = transcript.messageCount
            Button { messageSelection.copyText(transcript.text) } label: {
                Label("Copy \(count) Message\(count == 1 ? "" : "s")", systemImage: "doc.on.doc")
            }
            Divider()
        }
    }
}

/// One timeline row, fenced behind `Equatable` so a stream commit that
/// reassigns `windowedRows` re-evaluates ONLY the rows whose value
/// actually changed (normally just the streaming tail row). Without this
/// gate every commit re-ran body + layout for the whole 120–185-row
/// eager window — the closure properties below made the ForEach content
/// never memcmp-equal, so SwiftUI rebuilt the full view list up to 4×/s
/// during a live turn, pegging the main thread (2026-08-10 spike
/// samples: AttributeGraph update + makeViewList + sizeThatFits ~100%
/// of a 3s sample; conversation switches and scrolls queued behind it).
///
/// `==` deliberately ignores the closures (fresh values every parent
/// eval, stable behavior — they only capture `viewModel`, compared by
/// reference). Row state that lives OUTSIDE `row` still updates through
/// the two channels the gate preserves:
/// - `subtaskChild` is resolved in the parent (where
///   `stripViewModel.children` observation lives) and participates in
///   `==`, so indicator cards re-render when the child appears/finishes.
/// - ask-user / agent-chat / image-resolution state is read from
///   `@Observable` view-model storage inside THIS row's body (via the
///   closures), so Observation invalidates the row directly, bypassing
///   the parent-driven equality gate.
struct MacTimelineRowView: View, Equatable {
    let row: TimelineRow
    let subtaskChild: SubChatSummary?
    let viewModel: ChatViewModel
    let onOpenSubChat: (String) -> Void
    /// Selects the room a started spawn talks in — a top-level conversation,
    /// so it changes the sidebar selection rather than opening a child pane.
    /// `nil` where there is nowhere to navigate.
    let onOpenSpawnRoom: ((String) -> Void)?
    /// Opens the items pane to a tapped `.itemMarker`'s item. Fixed per
    /// screen like `onOpenSpawnRoom`, so `==` ignoring it is safe.
    let onOpenItem: ((String) -> Void)?
    /// Opens the mission page to a tapped `.milestoneMarker` /
    /// `.missionMarker`. Fixed per screen like `onOpenSpawnRoom`, so `==`
    /// ignoring it is safe.
    let onOpenMission: ((String) -> Void)?
    let onPreviewImage: (URL, Image) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.subtaskChild == rhs.subtaskChild
            && lhs.viewModel === rhs.viewModel
    }

    var body: some View {
        switch row {
        case .separator(let date):
            DateSeparator(date: date)
        case .message(let item):
            if let child = subtaskChild {
                // Bridge subtask indicator → tappable card opening
                // the child sub-chat pane.
                Button {
                    onOpenSubChat(child.id)
                } label: {
                    SubtaskLinkCard(title: child.title, isRunning: child.isRunning)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            } else {
                MacTimelineItemView(
                    item: item,
                    resolveImage: { viewModel.image(for: $0) },
                    onRetry: { id in viewModel.retrySend(itemID: id) },
                    onTapImage: { url, img in
                        onPreviewImage(url, img)
                    },
                    onTapFile: { mxc, filename in
                        Task {
                            if let url = await viewModel.writeTempFile(
                                mxcURL: mxc, filename: filename
                            ) {
                                // Hand off to the system —
                                // QuickLook / the user's
                                // chosen app handles the
                                // open. Stays inside the
                                // SwiftUI surface (no
                                // need for a sheet on
                                // Mac since the OS shell
                                // owns the open path).
                                await MainActor.run {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    },
                    isDownloadingFile: { viewModel.isDownloadingFile($0) },
                    isMediaUnavailable: { viewModel.isMediaUnavailable($0) },
                    askViewModel: { viewModel.askViewModel(forPrompt: $0) },
                    isPromptAnswered: { viewModel.isPromptAnswered($0) },
                    answerSummary: { viewModel.answerSummary(forPrompt: $0) },
                    agentChatState: { viewModel.agentChatState($0) },
                    onAnswerAgentChat: { eventID, request, approve in
                        Task {
                            await viewModel.answerAgentChat(
                                eventID: eventID, request: request,
                                decision: approve ? .approve : .deny)
                        }
                    },
                    agentSpawnState: { viewModel.agentSpawnState($0, request: $1) },
                    onAnswerAgentSpawn: { eventID, request, approve in
                        Task {
                            // `try?`: the only error that escapes is
                            // cancellation, which the view model has already
                            // handled by dropping the in-flight state.
                            try? await viewModel.answerAgentSpawn(
                                eventID: eventID, request: request,
                                decision: approve ? .approve : .deny)
                        }
                    },
                    onOpenSpawnRoom: onOpenSpawnRoom,
                    onOpenItem: onOpenItem,
                    onOpenMission: onOpenMission,
                    convoID: viewModel.roomID,
                    hasMultipleSenders: viewModel.hasMultipleSenders
                )
                // No `.onAppear` history trigger — an eager stack
                // mounts every row immediately; the near-top
                // geometry check in `MacChatView` owns extension.
                // Copy only (Dan, 2026-08-03: no Share / View
                // source, same as the iOS long-press menu). An
                // empty builder result (non-text rows) presents
                // no menu at all — so BOTH items live inside the
                // `.text` branch: a "Copy N Messages"-only menu on
                // an image or a tool card would be a menu where
                // this branch found none before. Captioned
                // image/file rows still offer the same item over
                // their caption, from the text view's AppKit menu.
                // With a cross-message selection present it leads.
                .contextMenu {
                    if case .text(let body, _) = item.kind {
                        MacSelectionCopyMenuItems()
                        Button {
                            Pasteboard.copy(body)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
        }
    }
}
