import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels

/// iOS chat screen. Hosts a scrollable timeline (LazyVStack rendering each
/// `TimelineItem` via `TimelineItemView`) above a `ComposerView`. The
/// navigation toolbar shows the chat title and an info button that calls
/// `onShowBotProfile` (Phase 5+ wires this to a profile sheet).
///
/// `viewModel.start()` runs in `.task`; `viewModel.stop()` runs in
/// `.onDisappear` to release the AsyncStream's continuation. This mirrors
/// the `ChatListView` pattern from Phase 1.
struct ChatView: View {
    @State var viewModel: ChatViewModel
    @State var composerVM: ComposerViewModel
    /// Backing state for the "View source" sheet. `TimelineItem` is
    /// `Identifiable` (the SDK's stable `TimelineUniqueId.id`), so
    /// `.sheet(item:)` re-presents a fresh sheet whenever the user picks a
    /// different row instead of clinging to the prior one.
    @State private var sourceItem: TimelineItem?

    let chatTitle: String
    let onShowBotProfile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.items) { item in
                            TimelineItemView(item: item, resolveImage: { viewModel.image(for: $0) })
                                .id(item.id)
                                .contextMenu {
                                    if case .text(let body, _) = item.kind {
                                        Button {
                                            UIPasteboard.general.string = body
                                        } label: {
                                            Label("Copy", systemImage: "doc.on.doc")
                                        }
                                        ShareLink(item: body) {
                                            Label("Share", systemImage: "square.and.arrow.up")
                                        }
                                    }
                                    // "View source" applies to every kind —
                                    // text, image, file, stateChange, unknown
                                    // — so it lives outside the `.text` guard.
                                    Button {
                                        sourceItem = item
                                    } label: {
                                        Label("View source", systemImage: "curlybraces")
                                    }
                                }
                        }
                    }
                    .padding(.vertical)
                }
                .onChange(of: viewModel.items.last?.id) { _, _ in
                    // Round-3 bugbot finding #5: previously we keyed on
                    // `items.count`, which misses two real cases —
                    // (a) a `.set` diff swapping a local-echo item id for
                    // its remote-event id keeps `count` constant but
                    // should still scroll to the new tail, and
                    // (b) a remove + add in the same diff batch leaves
                    // `count` unchanged but the last-item id moves.
                    // Keying on `last?.id` catches both.
                    if let last = viewModel.items.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            ComposerView(viewModel: composerVM)
        }
        .navigationTitle(chatTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { onShowBotProfile() } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .task {
            // Chain `markAsRead()` *after* the timeline observation has
            // applied its first snapshot. `start()` is now `async` and
            // returns once the first snapshot has landed (or the stream
            // ends without one), so the subsequent `markAsRead()` always
            // marks the actual head of the timeline as read instead of
            // racing the empty initial state. See `ChatViewModel.start()`
            // for the underlying signal mechanism (round-3 bugbot fix #3).
            await viewModel.start()
            await viewModel.markAsRead()
        }
        .onDisappear { viewModel.stop() }
        .sheet(item: $sourceItem) { item in
            EventSourceSheet(item: item)
        }
    }
}
