import SwiftUI
import UniformTypeIdentifiers
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem
import os

/// Diagnostic logger for the chat paginate trigger plumbing. Calls
/// to `paginateLogger.diag(...)` are gated by `MatronDebug.enabled`
/// so they stay in the source as living documentation of the data
/// flow without paying for them at runtime in shipped builds.
private let paginateLogger = Logger(subsystem: "chat.matron", category: "mac-chat-paginate")

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
    /// App lifecycle — drives `viewModel.handleForeground()` so a
    /// background→foreground timeline re-sync doesn't flash the empty
    /// placeholder. See iOS `ChatView`.
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false
    /// Generation token from the observation THIS view instance started;
    /// `onDisappear` only stops the VM if it still matches (see there).
    @State private var startedGeneration = 0
    /// Backing state for the right-click "View source" sheet (Task 16).
    /// `TimelineItem` is `Identifiable` (the SDK's stable
    /// `TimelineUniqueId.id`), so `.sheet(item:)` re-presents a fresh sheet
    /// when the user picks a different row.
    @State private var sourceItem: TimelineItem?
    /// Sticky "following the live tail" mode — see iOS `ChatView` for
    /// the full trace-driven rationale. Exited only by a real user drag
    /// (gesture phases); re-engaged when scrolling settles near the
    /// bottom or via the jump button. While `true`, the scroll engine
    /// keeps the viewport pinned via `sizeChangeAnchor`. There is
    /// deliberately NO row-id anchor state — the `.scrollPosition(id:)`
    /// binding this view used to carry was the root cause of the 2026-07
    /// blank-chat bug family (clobbered writes, dead-row anchoring; see
    /// iOS `ChatView`).
    @State private var isFollowingTail = true
    /// Viewport-derived "the bottom edge of content is on screen" —
    /// updated by `onScrollGeometryChange`, consumed by the gesture
    /// settle handler to re-arm follow-tail.
    @State private var isNearBottom = true
    /// Reference box for the bottommost visible row id (per-room scroll
    /// memory). A class box, not value `@State`: visibility updates
    /// arrive per row crossing while scrolling, and a value-typed write
    /// per tick would re-evaluate this whole body. Only `onDisappear`
    /// reads it.
    @State private var visibleRows = VisibleRowsBox()
    /// Scroll-memory id waiting for the first row snapshot of a fresh
    /// view model — consumed by the rows-populated observer.
    @State private var pendingRestoreID: String?
    /// Debounced follow-tail self-heal — see the schedule site in the
    /// geometry action and iOS `ChatView` for the trace rationale.
    @State private var followHealTask: Task<Void, Never>?

    /// AppKit reach-through for the jump button's momentum kill — see
    /// `NativeScrollViewBox` and the iOS twin in `ChatView`.
    @State private var nativeScroll = NativeScrollViewBox()

    final class VisibleRowsBox {
        var bottomID: String?
        /// Latest raw scroll geometry, refreshed by the
        /// `onScrollGeometryChange` transform — forensic context for
        /// breadcrumbs. See iOS ChatView.
        var geoDescription = ""
    }

    /// Bottom-edge proximity threshold (pt) for `isNearBottom` — see iOS
    /// ChatView: 60 left engine append-shortfalls (61–63pt) in the
    /// heal's blind side.
    private static let nearBottomThresholdPt: CGFloat = 100
    /// Top-edge proximity threshold (pt) that triggers backward
    /// pagination.
    private static let nearTopThresholdPt: CGFloat = 600

    /// proxy.scrollTo id of the inline activity indicator — a sibling of
    /// the scroll-target layout, so it never enters the anchor namespace.
    private static let activityFooterID = "activity-footer"

    /// Where "scroll to the bottom" should actually land: the inline
    /// activity indicator when the bot is working, else the last row.
    private var bottomScrollTargetID: String? {
        viewModel.activityLabel != nil ? Self.activityFooterID : viewModel.lastRenderableItemID
    }

    /// The `.sizeChanges` anchor role — the whole follow-tail mechanism;
    /// see iOS `ChatView.sizeChangeAnchor` for the full rationale.
    /// `.bottom` while following (engine-level bottom pinning through
    /// streaming growth / echo swaps / indicator mount), `nil` while
    /// reading (appends don't move the viewport), `.bottom` during a
    /// backward paginate (prepends keep the same rows on screen).
    private var sizeChangeAnchor: UnitPoint? {
        if isFollowingTail { return .bottom }
        return (viewModel.isPaginatingBackward || viewModel.isExtendingWindow) ? .bottom : nil
    }

    /// Edge proximity snapshot derived from scroll geometry — Equatable
    /// so `onScrollGeometryChange` fires only on edge transitions.
    private struct ScrollEdgeState: Equatable {
        var nearTop: Bool
        var nearBottom: Bool
    }
    /// Backing state for the fullscreen image preview. Files take a
    /// different path on Mac — `NSWorkspace.shared.open(_:)` hands
    /// the temp file to QuickLook / the user's preferred app, which
    /// means no SwiftUI sheet is needed. Only image taps land here.
    @State private var imagePreview: ImagePreview?

    /// Identifiable wrapper around a SwiftUI `Image` so
    /// `.sheet(item:)` has something to key on. Per-present UUID so
    /// two consecutive taps re-mount the sheet.
    fileprivate struct ImagePreview: Identifiable {
        let id = UUID()
        let image: Image
    }

    let chatTitle: String
    let onShowBotProfile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // QA finding #10: mirror the iOS error banner. Sliding-sync
            // timeouts now surface here instead of leaving the user
            // staring at an empty scroll view.
            if let errorMessage = viewModel.error {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.9))
                    .accessibilityLabel("Chat error: \(errorMessage)")
            }
            if viewModel.settledEmpty && viewModel.error == nil {
                // Settled-empty branch — see iOS `ChatView` and
                // `ChatViewModel.settledEmpty`. The debounced flag keeps
                // the placeholder from flashing on cold-start warm-up OR a
                // transient sliding-sync timeline reset.
                EmptyChatPlaceholder(botName: chatTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollViewReader { proxy in
            ScrollView {
                // `.equatable()` + the reference-identity `==` on
                // `MacTimelineListContent` is the scroll-perf fence —
                // see the iOS `ChatView` call site: parent scroll-state
                // churn (follow-mode / edge-proximity flips) must not
                // re-evaluate every mounted row. Timeline changes still
                // propagate via `@Observable` tracking, which
                // invalidates the child directly.
                VStack(spacing: 0) {
                    MacTimelineListContent(
                        viewModel: viewModel,
                        onPreviewImage: { imagePreview = ImagePreview(image: $0) },
                        onShowSource: { sourceItem = $0 }
                    )
                    .equatable()
                    // Inline typing indicator under the last bubble —
                    // sibling of the scroll-target layout so it never
                    // enters the scroll-target namespace. Its
                    // mount/unmount is a content-size change, so the
                    // `.sizeChanges` bottom anchor reveals/heals it
                    // natively while pinned. See iOS ChatView.
                    if let activityLabel = viewModel.activityLabel {
                        ActivityIndicatorRow(label: activityLabel)
                            .id(Self.activityFooterID)
                    }
                }
                // Mac mirror of iOS: fold cross-device ask-user answers
                // into the persisted set on every snapshot so resolved
                // inline cards stay resolved (bugbot "Cross-device
                // answers not persisted").
                .onChange(of: viewModel.items) { _, _ in
                    viewModel.persistVisibleAnswers()
                }
                // Grabs the backing NSScrollView (must sit INSIDE the
                // ScrollView content — the capture walks up from here).
                .captureNativeScrollView(into: nativeScroll)
            }
            // Warm-up state — see iOS `ChatView`: no rows yet but not
            // settled-empty, previously a fully blank message area. The
            // indicator delays its own appearance so cache-warm opens
            // never flash a spinner.
            .overlay {
                if viewModel.rows.isEmpty {
                    TimelineLoadingIndicator()
                }
            }
            // Every open lands at the bottom — including reopens against
            // a cached view model whose rows are already populated at
            // first layout. See iOS ChatView for the trace-driven
            // rationale behind each anchor role.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            // THE follow-tail mechanism — see `sizeChangeAnchor`.
            .defaultScrollAnchor(sizeChangeAnchor, for: .sizeChanges)
            .onScrollGeometryChange(for: ScrollEdgeState.self) { geo in
                // Side write into the box (cheap, non-invalidating) —
                // forensic numbers for breadcrumbs; see iOS ChatView.
                visibleRows.geoDescription = "visY=\(Int(geo.visibleRect.minY))–\(Int(geo.visibleRect.maxY)) contentH=\(Int(geo.contentSize.height)) containerH=\(Int(geo.containerSize.height))"
                return ScrollEdgeState(
                    nearTop: geo.visibleRect.minY < Self.nearTopThresholdPt,
                    nearBottom: geo.visibleRect.maxY
                        >= geo.contentSize.height - Self.nearBottomThresholdPt
                )
            } action: { _, edges in
                if isNearBottom != edges.nearBottom {
                    isNearBottom = edges.nearBottom
                    paginateLogger.diag("near-bottom → \(edges.nearBottom) (\(visibleRows.geoDescription))")
                    // Follow-tail self-heal: while following, losing the
                    // bottom edge with no user gesture is a layout
                    // artifact (LazyVStack content-height estimate churn
                    // — see iOS ChatView, 2026-07-14 06:51 trace).
                    // Geometry-keyed, non-animated, debounced 300ms.
                    if !edges.nearBottom, isFollowingTail {
                        followHealTask?.cancel()
                        followHealTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            guard !Task.isCancelled, isFollowingTail, !isNearBottom,
                                  let target = bottomScrollTargetID else { return }
                            paginateLogger.breadcrumb("follow-tail heal → \(target) (\(visibleRows.geoDescription))")
                            proxy.scrollTo(target, anchor: .bottom)
                        }
                    } else {
                        followHealTask?.cancel()
                        followHealTask = nil
                    }
                }
                // History-reveal trigger — viewport geometry; fires once
                // per approach to the top edge (Equatable state),
                // re-armed when the revealed rows push the threshold
                // away. `!isFollowingTail` gates out layout churn: only
                // a user who has actually dragged away from the tail can
                // be reading toward the top (see iOS ChatView).
                if edges.nearTop, !isFollowingTail {
                    Task { await viewModel.extendHistoryWindow() }
                }
            }
            // Per-room scroll memory feed — non-invalidating box; see
            // `VisibleRowsBox`.
            .onScrollTargetVisibilityChange(idType: String.self) { visibleIDs in
                visibleRows.bottomID = visibleIDs.last
                // History-reveal trigger #2 — the window's first row is
                // actually on screen. Keeps firing while the user sits
                // at the top, which the near-top edge transition can't
                // (fast flicks park in the bounce before the extend
                // applies and the edge never re-fires — 07:23 iOS
                // trace). See iOS ChatView.
                if !isFollowingTail,
                   let firstID = viewModel.windowedRows.first?.id,
                   visibleIDs.contains(firstID) {
                    Task { await viewModel.extendHistoryWindow() }
                }
            }
            // Gesture-driven follow-mode transitions. Only a real drag
            // exits the mode; re-armed by settling near the bottom
            // (geometry, not row identity).
            .onUserScrollGesture(
                begin: {
                    if isFollowingTail {
                        isFollowingTail = false
                        paginateLogger.breadcrumb("follow-tail OFF (user gesture)")
                    }
                },
                settle: {
                    if !isFollowingTail, isNearBottom {
                        isFollowingTail = true
                        paginateLogger.breadcrumb("follow-tail ON (settled at tail)")
                    }
                }
            )
            // Restore the per-room scroll position — see iOS ChatView:
            // cached view model resolves immediately, fresh view model
            // parks the id for the rows-populated observer below; ids
            // the room no longer contains are dropped.
            .task {
                if let restored = ChatScrollPositionMemory.retrieve(roomID: viewModel.roomID) {
                    if viewModel.rowAnchorIDs.isEmpty {
                        isFollowingTail = false
                        pendingRestoreID = restored
                    } else if viewModel.rowAnchorIDs.contains(restored) {
                        isFollowingTail = false
                        // Widen the window first — the remembered row may
                        // sit above the default tail window.
                        viewModel.ensureWindowContains(restored)
                        proxy.scrollTo(restored, anchor: .bottom)
                    } else {
                        ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
                    }
                    return
                }
                // Open-at-bottom verification — `initialOffset: .bottom`
                // can land short of the true bottom once lazy row
                // heights settle; one non-animated correction. See iOS
                // ChatView for the trace rationale.
                try? await Task.sleep(nanoseconds: 350_000_000)
                if isFollowingTail, !isNearBottom, let target = bottomScrollTargetID {
                    paginateLogger.breadcrumb("open re-pin → \(target) (\(visibleRows.geoDescription))")
                    proxy.scrollTo(target, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.rows.isEmpty) { _, isEmpty in
                guard !isEmpty, let restored = pendingRestoreID else { return }
                pendingRestoreID = nil
                if viewModel.rowAnchorIDs.contains(restored) {
                    viewModel.ensureWindowContains(restored)
                    proxy.scrollTo(restored, anchor: .bottom)
                } else {
                    // The remembered row didn't survive to this open —
                    // fall back to the open-at-tail default.
                    ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
                    isFollowingTail = true
                }
            }
            // Discrete tail changes: own sends always return to the
            // bottom; while following, instant re-pin per new row. See
            // iOS ChatView for the trace rationale.
            .onChange(of: viewModel.lastRenderableItemID) { _, newID in
                guard newID != nil else { return }
                if viewModel.lastRenderableItemIsOwn, !isFollowingTail {
                    isFollowingTail = true
                    paginateLogger.breadcrumb("follow-tail ON (own send)")
                }
                guard isFollowingTail, let target = bottomScrollTargetID else { return }
                proxy.scrollTo(target, anchor: .bottom)
            }
            // "Loading earlier messages…" pill — see iOS `ChatView`
            // for the overlay rationale + `MinDisplayDuration`'s
            // role keeping fast-paginate flashes perceptible.
            .overlay(alignment: .top) {
                MinDisplayDuration(while: viewModel.isPaginatingBackward) { visible in
                    if visible {
                        PaginatingHeader()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: viewModel.isPaginatingBackward)
            }
            // Floating jump-to-latest — visible whenever the user has
            // left follow-tail mode. Imperative scroll; the retired
            // binding write here was clobbered by the ScrollView's
            // post-layout write-back (2026-07-14 iOS device trace).
            .overlay(alignment: .bottomTrailing) {
                if !isFollowingTail {
                    JumpToBottomButton {
                        isFollowingTail = true
                        paginateLogger.breadcrumb("follow-tail ON (jump button, \(visibleRows.geoDescription))")
                        ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
                        // Kill in-flight momentum and snap to the bottom
                        // in the same frame (AppKit reach-through — see
                        // `NativeScrollViewBox`), then scrollTo settles
                        // row-exact position on the still view. No
                        // window reset here: swapping `windowedRows`
                        // mid-scroll rebuilds the layout under the
                        // jump's feet; `onDisappear` owns the trim.
                        nativeScroll.killMomentumAndSnapToBottom()
                        if let target = bottomScrollTargetID {
                            proxy.scrollTo(target, anchor: .bottom)
                        }
                        followHealTask?.cancel()
                        followHealTask = Task { @MainActor in
                            for _ in 0..<10 {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                guard !Task.isCancelled, isFollowingTail, !isNearBottom,
                                      let target = bottomScrollTargetID else { return }
                                paginateLogger.breadcrumb("jump re-assert → \(target) (\(visibleRows.geoDescription))")
                                proxy.scrollTo(target, anchor: .bottom)
                            }
                        }
                    }
                }
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
        // matron-web's cream timeline gradient behind the whole chat
        // column — bubbles and the composer material share the warm ground.
        .background(MatronTimelineBackground())
        .toolbar {
            MacChatToolbar(
                title: chatTitle,
                onShowBotProfile: onShowBotProfile
            )
        }
        .task {
            // (Scroll-memory restore lives on the ScrollView inside the
            // ScrollViewReader above — it needs the proxy.)
            //
            // `start()` (round-3 bugbot fix #3) returns once the first
            // timeline snapshot has been applied, so the chained
            // `markAsRead()` marks the actual head of the timeline as
            // read instead of racing the empty initial state.
            // BEFORE the await — see iOS ChatView: a mid-await disappear
            // would skip a post-await assignment and leak the observation
            // (bugbot "Early disappear skips observation stop").
            startedGeneration = viewModel.observationGeneration + 1
            await viewModel.start()
            // Explicit paginate-on-open BEFORE markAsRead — see iOS
            // `ChatView`: history loads over HTTP and must not wait on
            // the live socket, which a half-dead connection can hang.
            await viewModel.paginateBackward()
            await viewModel.markAsRead()
        }
        .onDisappear {
            paginateLogger.breadcrumb("chat view disappear room=\(viewModel.roomID) lastVisible=\(visibleRows.bottomID ?? "nil") following=\(isFollowingTail)")
            followHealTask?.cancel()
            followHealTask = nil
            // Persist the user's scroll position so the next open of
            // this room lands where they left off. A user in follow-tail
            // mode gets no entry — the default already opens at the
            // bottom, and a live-tail row id would reopen the room
            // pinned to a stale position.
            if !isFollowingTail, let id = visibleRows.bottomID {
                ChatScrollPositionMemory.store(roomID: viewModel.roomID, itemID: id)
            } else {
                ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
                // Off-screen and at the tail — shrink the cached VM's
                // window back to the default for the next open (a reader
                // mid-history keeps theirs; see iOS ChatView).
                viewModel.resetHistoryWindow()
            }
            // Generation-guarded: the VM is cached per room (ChatVMCache),
            // and on a same-room remount SwiftUI can run the NEW view's
            // `.task`/start() before the OLD view's onDisappear — an
            // unconditional stop() here would kill the successor's fresh
            // stream and freeze the timeline.
            viewModel.stop(ifGeneration: startedGeneration)
        }
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
        // When focus is on a chat detail column, ⌘R reloads THIS
        // chat's timeline (paginate-backward via
        // `ChatViewModel.refresh()`). The chat-list `⌘R` /
        // pull-to-refresh in `MacChatListView.refreshable` handles
        // the list-level snapshot via `ChatService.forceSnapshot()` —
        // those are different surfaces and stay separately wired.
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
        // Mac fullscreen image preview — Mac's `NSWorkspace.shared.open`
        // already owns the file path, so the only sheet wired here is
        // for the in-app pinch-zoom-style image viewer.
        .sheet(item: $imagePreview) { preview in
            AttachmentFullscreenViewer(
                image: preview.image,
                onDismiss: { imagePreview = nil }
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                wasBackgrounded = true
            } else if newPhase == .active, wasBackgrounded {
                wasBackgrounded = false
                viewModel.handleForeground()
            }
        }
    }

}

/// The timeline's eager `VStack` + `ForEach`, fenced off behind
/// `Equatable` so the parent's scroll-state churn (follow-mode /
/// edge-proximity flips) can't
/// re-evaluate every mounted row (see the call site in
/// `MacChatView.body` and the iOS twin in `ChatView.swift`). `==`
/// compares only the view-model reference: row data is delivered
/// through `@Observable` tracking, which invalidates this view
/// directly when `viewModel.rows` (or anything else its body reads)
/// changes — the equatable check only gates parent-driven invalidation.
private struct MacTimelineListContent: View, Equatable {
    let viewModel: ChatViewModel
    let onPreviewImage: (Image) -> Void
    let onShowSource: (TimelineItem) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.viewModel === rhs.viewModel
    }

    var body: some View {
        // Eager `VStack`, NOT `LazyVStack` — the window bounds the row
        // count, and eager layout makes content height exact instead of
        // estimated (the estimate churn is what kept teleporting the
        // viewport; see the iOS twin in `ChatView.swift` for the full
        // rationale and device-trace evidence).
        VStack(spacing: 8) {
            // Render `rows` (messages interleaved with date
            // separators) instead of `items` directly. Mirrors
            // the iOS surface — the bucketing logic lives in
            // `ChatViewModel.rows` so the two platforms can't
            // drift.
            // `windowedRows`, NOT `rows` — see `ChatViewModel.windowedRows`.
            ForEach(viewModel.windowedRows) { row in
                switch row {
                case .separator(let date):
                    DateSeparator(date: date)
                        .id(row.id)
                case .message(let item):
                    MacTimelineItemView(
                        item: item,
                        resolveImage: { viewModel.image(for: $0) },
                        onRetry: { id in viewModel.retrySend(itemID: id) },
                        onTapImage: { img in
                            onPreviewImage(img)
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
                        askViewModel: { viewModel.askViewModel(forPrompt: $0) },
                        isPromptAnswered: { viewModel.isPromptAnswered($0) },
                        answerSummary: { viewModel.answerSummary(forPrompt: $0) }
                    )
                        .id(item.id)
                        // No `.onAppear` history trigger — an eager stack
                        // mounts every row immediately; the near-top
                        // geometry check in `MacChatView` owns extension.
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
                                onShowSource(item)
                            } label: {
                                Label("View source", systemImage: "curlybraces")
                            }
                        }
                }
            }
        }
        .scrollTargetLayout()
        .padding(.vertical)
    }
}

