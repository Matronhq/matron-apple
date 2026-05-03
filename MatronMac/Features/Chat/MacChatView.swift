import SwiftUI
import UniformTypeIdentifiers
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// Mac chat detail column. Hosts a `ScrollView` + `LazyVStack` of
/// `MacTimelineItemView` rows above the `MacComposerView`. Right-click
/// context menu replaces iOS's long-press; `⌘K` (hidden button) toggles
/// the slash palette without the user typing `/`. `⌘R` refresh is wired
/// via `NotificationCenter.matronCommand(.refresh)` (Task 14e attaches
/// the menu item; the listener stays attached even when the menu is
/// absent, so trackpad-only Macs without a hardware ⌘R can still drive
/// refresh once a binding lands).
///
/// Drag-and-drop attachments via `.onDrop(of: [.image, .fileURL], delegate:)`,
/// which routes through `ComposerDropDelegate → ComposerViewModel.attachFiles(_:)`
/// — same pipeline as the iOS PhotosPicker / fileImporter sites. The
/// security-scoped-resource bracketing the iOS `fileImporter` site
/// requires isn't needed here because the Mac sandbox grants drop URLs
/// transparent read access via the
/// `com.apple.security.files.user-selected.read-only` entitlement.
struct MacChatView: View {
    @State var viewModel: ChatViewModel
    @State var composerVM: ComposerViewModel
    /// Backing state for the right-click "View source" sheet (Task 16).
    /// `TimelineItem` is `Identifiable` (the SDK's stable
    /// `TimelineUniqueId.id`), so `.sheet(item:)` re-presents a fresh sheet
    /// when the user picks a different row.
    @State private var sourceItem: TimelineItem?

    let chatTitle: String
    let onShowBotProfile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.items) { item in
                            MacTimelineItemView(item: item, resolveImage: { viewModel.image(for: $0) })
                                .id(item.id)
                                .contextMenu {
                                    if case .text(let body, _) = item.kind {
                                        Button {
                                            Pasteboard.copy(body)
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
                    // Round-3 bugbot finding #5: keying on `items.count`
                    // missed `.set` diffs that swap a local-echo id for
                    // a remote-event id (count constant, last id moves)
                    // and remove+add diff batches (count constant, last
                    // id moves). Keying on `last?.id` catches both.
                    if let last = viewModel.items.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            // Drag-and-drop attachments via ComposerDropDelegate.
            MacComposerView(viewModel: composerVM)
                .onDrop(
                    of: [.image, .fileURL],
                    delegate: ComposerDropDelegate(composer: composerVM)
                )
        }
        .toolbar {
            MacChatToolbar(
                title: chatTitle,
                viewModel: viewModel,
                onShowBotProfile: onShowBotProfile
            )
        }
        .task {
            // `start()` (round-3 bugbot fix #3) returns once the first
            // timeline snapshot has been applied, so the chained
            // `markAsRead()` marks the actual head of the timeline as
            // read instead of racing the empty initial state.
            await viewModel.start()
            await viewModel.markAsRead()
        }
        .onDisappear { viewModel.stop() }
        // ⌘K opens the slash palette without typing `/`. The hidden
        // button is the SwiftUI-recommended pattern for a global keyboard
        // shortcut that doesn't have a visible UI counterpart. Marked
        // accessibilityHidden because the unlabeled button would
        // otherwise be announced as a nameless "button" by VoiceOver
        // (QA finding #21).
        .background(
            Button("") { composerVM.palettePinnedOpen.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
        // ⌘R refresh — driven by the menu-bar command bus (Task 14e).
        .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.refresh))) { _ in
            Task { await viewModel.refresh() }
        }
        // ⌘K menu route — `Commands.swift` posts `.slashCommand` from
        // the Edit menu's "Slash Command" item. Without this listener
        // the menu route was dead (the keyboard shortcut still worked
        // via the hidden Button above, but the menu picked the same
        // notification and dropped it). QA finding #2.
        .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.slashCommand))) { _ in
            composerVM.palettePinnedOpen.toggle()
        }
        .sheet(item: $sourceItem) { item in
            MacEventSourceSheet(item: item, onDismiss: { sourceItem = nil })
        }
    }
}
