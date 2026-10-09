import SwiftUI
import Foundation
import MatronEvents
import MatronModels

/// Full detail surface for a single tracker item: header, body, item-level
/// attachments, the comment thread (including in-flight pending comments),
/// the close/reopen action bar, and the reply composer. A pure leaf view —
/// the host view model supplies everything through `Model` and the closure
/// bag, and this view never touches Journal/ViewModels directly (DesignSystem
/// may only depend on Models/Events/Search).
public struct ItemDetailView: View {
    public struct PendingComment: Equatable, Identifiable {
        public let id: String
        public let body: String
        public let attachmentCount: Int
        public let attempts: Int
        public let lastError: String?
        public init(id: String, body: String, attachmentCount: Int, attempts: Int, lastError: String?) {
            self.id = id; self.body = body; self.attachmentCount = attachmentCount; self.attempts = attempts; self.lastError = lastError
        }
    }

    public struct Model: Equatable {
        public var item: TrackerItem
        public var comments: [TrackerComment]
        public var pending: [PendingComment]
        /// The item's mission and owner conversation, drawn under the
        /// `#N · Kind` line — `ItemDetailViewModel.context(currentConvoID:)`.
        /// Defaulted to empty so call sites that have none stay simple.
        public var context: ItemContext
        public var availableResolutions: [ItemResolution]
        public var isBusy: Bool
        /// The comment count of the loaded thread, `nil` until the opening
        /// refetch has completed (`ItemDetailViewModel.loadedCommentCount`).
        /// Follow-tail only treats growth as a new reply when it starts
        /// from at least this many rows: a header-only thread is trivially
        /// "at the bottom", and treating the opening load — or a stale
        /// replay of it — as growth would jump an unread item to its end
        /// (Bugbot, PR #198). Defaulted to `nil` so existing call sites and
        /// snapshot tests stay source-compatible.
        public var loadedCommentCount: Int?
        /// The spawn consent ask this item mirrors, derived by
        /// `ItemDetailViewModel.spawnConsent`; `nil` for every other item.
        /// Defaulted so existing call sites and snapshot tests stay
        /// source-compatible.
        public var spawnConsent: ItemSpawnConsent?
        /// The one-tap answers to draw under the body card
        /// (`ItemDetailViewModel.offeredActions` — empty once the item is
        /// closed) and the one showing as chosen
        /// (`ItemDetailViewModel.selectedAction`). Defaulted so existing
        /// call sites and snapshot tests stay source-compatible.
        public var actions: [String]
        public var selectedAction: String?
        /// The reply's staged attachments (`ItemDetailViewModel.stagedAttachments`),
        /// shown in the composer's tray until Send. Defaulted so existing
        /// call sites and snapshot tests stay source-compatible.
        public var stagedAttachments: [StagedAttachment]
        /// Your replies the agent hasn't got yet, by comment id
        /// (`ItemDetailViewModel.queuedReplies`): queued behind its running
        /// turn, or cancelled / never delivered. Defaulted so existing call
        /// sites and snapshot tests stay source-compatible.
        public var queuedReplies: [String: QueuedReplyState]
        /// The label showing as chosen under each comment that offers its
        /// own buttons, by comment id
        /// (`ItemDetailViewModel.selectedCommentActions`). The buttons
        /// themselves are the comment's `actions`. Defaulted so existing
        /// call sites and snapshot tests stay source-compatible.
        public var selectedCommentActions: [String: String]
        public init(item: TrackerItem, comments: [TrackerComment], pending: [PendingComment], context: ItemContext = ItemContext(), availableResolutions: [ItemResolution], isBusy: Bool, loadedCommentCount: Int? = nil, spawnConsent: ItemSpawnConsent? = nil, actions: [String] = [], selectedAction: String? = nil, stagedAttachments: [StagedAttachment] = [], queuedReplies: [String: QueuedReplyState] = [:], selectedCommentActions: [String: String] = [:]) {
            self.item = item; self.comments = comments; self.pending = pending; self.context = context
            self.availableResolutions = availableResolutions; self.isBusy = isBusy; self.loadedCommentCount = loadedCommentCount
            self.spawnConsent = spawnConsent; self.actions = actions; self.selectedAction = selectedAction
            self.stagedAttachments = stagedAttachments; self.queuedReplies = queuedReplies
            self.selectedCommentActions = selectedCommentActions
        }
    }

    let model: Model
    /// The reply's draft. Only `ReplyComposer` turns it into a `Binding`:
    /// `Binding(get:set:)` reads its getter when it is made,
    /// so a binding made in a host's or this view's body subscribes THAT
    /// body to the draft, and every keystroke rebuilt every comment row
    /// (17–21 ms a keystroke on a 113-comment thread on the Mac, ~39 ms on
    /// iPhone). `ItemDetailDraftIsolationTests`.
    let draft: ItemReplyDraft
    let image: (TrackerAttachment) -> Image?
    let onOpenAttachment: (TrackerAttachment) -> Void
    let onOpenLink: (URL) -> Void
    let onOpenConversation: (String) -> Void
    /// Opens a mission page by number — the context block's mission row.
    /// `nil` draws it as plain text: a row wired to nothing would look like
    /// it opens something.
    let onOpenMission: ((Int) -> Void)?
    let onSubmit: () -> Void
    let onAttach: () -> Void
    let onVoiceNote: () -> Void
    let onClose: (ItemResolution) -> Void
    let onReopen: () -> Void
    /// Reference instant for relative comment-date captions ("5 min ago").
    /// Defaulted to `Date()` so existing/host call sites stay source-compatible;
    /// snapshot tests pass a fixed instant so the thread renders deterministically.
    let now: Date
    /// Whether the reader had previously scrolled to the bottom of this
    /// item's thread (`ItemReadMemory.wasAtBottom(itemID:)`, read once by
    /// the host) — mirrors the chat timeline opening at the tail when the
    /// reader was following it. Defaulted so existing call sites/snapshot
    /// tests stay source-compatible.
    let startsAtBottom: Bool
    /// Reports whether the comment thread's bottom is currently visible,
    /// so the host can persist it for next time. Defaulted to `nil` for
    /// the same reason.
    let onBottomVisibilityChange: ((Bool) -> Void)?
    /// Answers the spawn consent card: `true` approves, `false` declines —
    /// the same `POST /agent-spawn/answer` the timeline card uses, via the
    /// host's view model. `nil` (previews, tests, hosts without an
    /// answerer) draws whatever state the model carries; the model itself
    /// never offers buttons when nothing is wired to them.
    let onAnswerSpawn: ((Bool) -> Void)?
    /// Opens the room a started spawn talks in. `nil` omits the Open
    /// button, as on the timeline card.
    let onOpenRoom: ((String) -> Void)?
    /// Answers the item with one of its action buttons (the host's
    /// `ItemDetailViewModel.chooseAction`). `nil` draws no buttons: a
    /// button wired to nothing would look like an answer and send none.
    let onAction: ((String) -> Void)?
    /// Answers a follow-up question with one of its comment's buttons —
    /// the asking comment's id, then the label (the host's
    /// `ItemDetailViewModel.chooseCommentAction`). `nil` draws no buttons
    /// under comments, for the same reason.
    let onCommentAction: ((String, String) -> Void)?
    /// Removes a staged attachment from the reply's tray (its ✕).
    let onRemoveAttachment: (UUID) -> Void
    /// What the thread's not-yet-delivered replies offer.
    let replyDelivery: ReplyDeliveryActions

    /// The buttons on replies the agent hasn't got yet, wired to the host's
    /// `ItemDetailViewModel`. Each `nil` draws no button: a button wired to
    /// nothing would look like it acted and do nothing.
    public struct ReplyDeliveryActions {
        /// Send now on a reply queued behind the agent's turn, by comment
        /// id — `sendQueuedReplyNow`.
        public var sendQueuedNow: ((String) -> Void)?
        /// Cancel on a reply queued behind the agent's turn, by comment id
        /// — `cancelQueuedReply`.
        public var cancelQueued: ((String) -> Void)?
        /// Edit and resend on a reply that never reached the agent, by
        /// comment id — `editAndResend`.
        public var editAndResend: ((String) -> Void)?
        /// Send now on a reply still in this device's outbox —
        /// `sendPendingNow`.
        public var sendPendingNow: (() -> Void)?
        /// Cancel on a reply still in this device's outbox, by its local id
        /// — `cancelPendingReply`.
        public var cancelPending: ((String) -> Void)?

        public init(sendQueuedNow: ((String) -> Void)? = nil, cancelQueued: ((String) -> Void)? = nil,
                    editAndResend: ((String) -> Void)? = nil, sendPendingNow: (() -> Void)? = nil,
                    cancelPending: ((String) -> Void)? = nil) {
            self.sendQueuedNow = sendQueuedNow; self.cancelQueued = cancelQueued; self.editAndResend = editAndResend
            self.sendPendingNow = sendPendingNow; self.cancelPending = cancelPending
        }
    }

    /// Whether the comment thread's bottom is currently visible — read by
    /// the follow-tail `.onChange(of: rowCount)` below, written by
    /// `.onScrollGeometryChange`'s `action`.
    @State private var isAtBottom = false
    /// Guards the initial `startsAtBottom` scroll to firing once per item
    /// (see `.onAppear`/`.onChange(of: item.id)` below) rather than on
    /// every body re-evaluation.
    @State private var hasScrolledToInitialBottom = false
    /// Whether the thread is taller than its viewport — reported by the
    /// same geometry callback as `isAtBottom`. Gates the jump-to-bottom
    /// button so a thread that fits on screen never offers a jump.
    @State private var isScrollable = false
    /// The item body size for plain `Text` that sits beside a markdown
    /// body (pending replies, voice transcripts): the same base and scale
    /// `Theme.matronItem` resolves to, and — because it is a
    /// `@ScaledMetric` relative to `.body`, exactly as MarkdownUI scales
    /// its own base — it grows and shrinks with Dynamic Type in step with
    /// the markdown next to it. A fixed `.system(size:)` would agree at
    /// the default size and diverge at every other.
    @ScaledMetric(relativeTo: .body) private var scaledBodySize: CGFloat = ItemTypography.baseSize * ItemTypography.bodyScale
    /// On the Mac the markdown bodies are `SelectableMessageText` at the
    /// fixed `Style.item` size, so the plain `Text` beside them takes that
    /// same size or the two drift apart under a non-default Dynamic Type
    /// (Bugbot, PR #232).
    private var bodySize: CGFloat {
        #if os(macOS)
        MarkdownAttributed.Style.item.baseFontSize
        #else
        scaledBodySize
        #endif
    }
    #if os(macOS)
    /// The thread's cross-card selection: the body card and
    /// every text comment render through the chat timeline's NSTextView
    /// (`SelectableMessageText`), and this controller — installed in the
    /// environment below, shadowing any chat timeline's own — lets one
    /// drag run from a card into the next, exactly as in a conversation.
    /// Owned here rather than by the host so the iOS view stays a pure leaf
    /// and the Mac hosts (pane, Decisions, Missions) need no wiring.
    @State fileprivate var cardSelection = MessageSelectionController()
    /// The host has no header of its own over the thread (the Mac Decisions
    /// page): the thread runs up under the window's clear title bar, and
    /// the host draws the resolve/reopen menu there instead of the pinned
    /// ⋯ row.
    @Environment(\.itemDetailFillsTitleBar) private var fillsTitleBar
    /// How far the header's top row stays clear of the trailing edge, so
    /// its status chip never sits under the title-bar menu: zero while the
    /// centred measure leaves a wide enough margin, more as the pane
    /// narrows (`titleBarMenuReserve`).
    @State private var titleBarReserve: CGFloat = 0
    #endif

    /// For previews and tests: a `Binding` made in the caller's body
    /// subscribes that body to the draft, so hosts pass an `ItemReplyDraft`.
    public init(model: Model, draft: Binding<String>, image: @escaping (TrackerAttachment) -> Image?,
                onOpenAttachment: @escaping (TrackerAttachment) -> Void, onOpenLink: @escaping (URL) -> Void,
                onOpenConversation: @escaping (String) -> Void, onSubmit: @escaping () -> Void, onAttach: @escaping () -> Void,
                onVoiceNote: @escaping () -> Void, onClose: @escaping (ItemResolution) -> Void, onReopen: @escaping () -> Void,
                now: Date = Date(), startsAtBottom: Bool = false, onBottomVisibilityChange: ((Bool) -> Void)? = nil,
                onAnswerSpawn: ((Bool) -> Void)? = nil, onOpenRoom: ((String) -> Void)? = nil,
                onAction: ((String) -> Void)? = nil, onRemoveAttachment: @escaping (UUID) -> Void = { _ in },
                replyDelivery: ReplyDeliveryActions = .init(),
                onCommentAction: ((String, String) -> Void)? = nil,
                onOpenMission: ((Int) -> Void)? = nil) {
        self.init(model: model, draft: ItemReplyDraft(draft), image: image, onOpenAttachment: onOpenAttachment,
                  onOpenLink: onOpenLink, onOpenConversation: onOpenConversation, onSubmit: onSubmit, onAttach: onAttach,
                  onVoiceNote: onVoiceNote, onClose: onClose, onReopen: onReopen, now: now, startsAtBottom: startsAtBottom,
                  onBottomVisibilityChange: onBottomVisibilityChange, onAnswerSpawn: onAnswerSpawn, onOpenRoom: onOpenRoom,
                  onAction: onAction, onRemoveAttachment: onRemoveAttachment, replyDelivery: replyDelivery,
                  onCommentAction: onCommentAction, onOpenMission: onOpenMission)
    }

    public init(model: Model, draft: ItemReplyDraft, image: @escaping (TrackerAttachment) -> Image?,
                onOpenAttachment: @escaping (TrackerAttachment) -> Void, onOpenLink: @escaping (URL) -> Void,
                onOpenConversation: @escaping (String) -> Void, onSubmit: @escaping () -> Void, onAttach: @escaping () -> Void,
                onVoiceNote: @escaping () -> Void, onClose: @escaping (ItemResolution) -> Void, onReopen: @escaping () -> Void,
                now: Date = Date(), startsAtBottom: Bool = false, onBottomVisibilityChange: ((Bool) -> Void)? = nil,
                onAnswerSpawn: ((Bool) -> Void)? = nil, onOpenRoom: ((String) -> Void)? = nil,
                onAction: ((String) -> Void)? = nil, onRemoveAttachment: @escaping (UUID) -> Void = { _ in },
                replyDelivery: ReplyDeliveryActions = .init(),
                onCommentAction: ((String, String) -> Void)? = nil,
                onOpenMission: ((Int) -> Void)? = nil) {
        self.model = model; self.draft = draft; self.image = image; self.onOpenAttachment = onOpenAttachment
        self.onOpenLink = onOpenLink; self.onOpenConversation = onOpenConversation; self.onSubmit = onSubmit
        self.onAttach = onAttach; self.onVoiceNote = onVoiceNote; self.onClose = onClose; self.onReopen = onReopen
        self.now = now; self.startsAtBottom = startsAtBottom; self.onBottomVisibilityChange = onBottomVisibilityChange
        self.onAnswerSpawn = onAnswerSpawn; self.onOpenRoom = onOpenRoom; self.onAction = onAction
        self.onRemoveAttachment = onRemoveAttachment
        self.replyDelivery = replyDelivery
        self.onCommentAction = onCommentAction
        self.onOpenMission = onOpenMission
    }

    private var item: TrackerItem { model.item }

    /// Stable id the `ScrollViewReader` scrolls to — an invisible spacer
    /// after the last comment/pending row, not a row's own id, so it
    /// stays valid even when the thread is empty.
    private static let bottomAnchorID = "bottom"

    /// Row count driving the follow-tail re-pin below: comments plus
    /// locally-queued pending ones, since either landing is "the thread
    /// grew" from the reader's point of view.
    private var rowCount: Int { model.comments.count + model.pending.count }

    public var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // The Mac pane has no navigation bar of its own to host the
            // resolve/reopen menu (its pushes share the window toolbar),
            // so a slim pinned row above the thread stands in — pinned,
            // not in the scrolling header, so it stays reachable after
            // reading to the tail (Bugbot). The iOS host puts the same
            // control in the navigation bar, and the Mac's Decisions page
            // in the window's title bar (`itemDetailFillsTitleBar`).
            if !fillsTitleBar {
                HStack {
                    Spacer()
                    ItemResolveControl(isOpen: item.state == .open, resolutions: model.availableResolutions, isBusy: model.isBusy, canReopen: !item.isConsentAsk,
                                       onClose: onClose, onReopen: onReopen)
                        .menuStyle(.borderlessButton).fixedSize()
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
            #endif
            ScrollViewReader { proxy in
                ScrollView {
                    // Eager, not lazy: every row is laid out
                    // up front, so the thread's height is final from the
                    // first frame. A `LazyVStack` opened fast but, under
                    // load, re-estimated the rows above the reader and moved
                    // the thread by hundreds of points while scrolling up
                    // from the tail. What made the eager stack slow was an
                    // NSTextView per card, built at open; on the Mac
                    // `itemBody` defers each one until its card nears the
                    // screen, behind a box of the same measured size
                    // (`SelectableMessageText.defersTextView`).
                    // `ItemDetailDeferredThreadTests` pins both.
                    VStack(alignment: .leading, spacing: ItemTypography.threadSpacing) {
                        header
                        if !item.labels.isEmpty || !item.links.isEmpty { meta }
                        if let consent = model.spawnConsent { spawnConsentCard(consent) }
                        if !item.body.isEmpty || !item.attachments.isEmpty { bodyCard }
                        if let onAction, Self.showsActions(model.actions, isOpen: item.state == .open) {
                            ItemActionButtons(actions: model.actions, selected: model.selectedAction, isEnabled: !model.isBusy, onChoose: onAction)
                        }
                        Divider()
                        ForEach(model.comments) { comment in commentView(comment) }
                        ForEach(model.pending) { p in pendingView(p) }
                        Color.clear.frame(height: 1).id(Self.bottomAnchorID)
                    }
                    // A reading measure, not a chat column: the thread caps
                    // at `ItemTypography.measure` and centres in whatever
                    // width the host gives it (a dragged-wide Mac pane, the
                    // narrow takeover, an iPad) instead of stretching every
                    // line across the window.
                    .frame(maxWidth: ItemTypography.measure, alignment: .leading)
                    .padding()
                    #if os(macOS)
                    .padding(.top, fillsTitleBar ? Self.titleBarClearance : 0)
                    #endif
                    .frame(maxWidth: .infinity)
                }
                // Answers its own minimum, ideal and maximum size, so a
                // container probing them never measures the thread. A
                // split view's per-column hosting view (Decisions'
                // `NavigationSplitView`, the chat's `HSplitView`) asks on
                // every layout pass, and a scroll view's ideal size is its
                // content's: every card measured again at a width it is
                // never shown at.
                .threadScrollFrame()
                #if os(macOS)
                .fillingTitleBar(fillsTitleBar)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    Self.titleBarMenuReserve(paneWidth: proxy.size.width)
                } action: { titleBarReserve = $0 }
                #endif
                .onItemThreadGeometryChange { geometry in
                    isAtBottom = geometry.atBottom
                    isScrollable = geometry.scrollable
                    onBottomVisibilityChange?(geometry.atBottom)
                }
                // Dragging the thread down through the keyboard hides it,
                // as in the chat timeline — the composer row's own
                // pull-down (`dragDownDismissesKeyboard`) covers the
                // other place people reach for.
                .scrollDismissesKeyboard(.interactively)
                // Floating jump-to-latest, the chat timeline's own
                // affordance, shown once the reader has scrolled away from
                // the tail of a thread that actually overflows.
                .overlay(alignment: .bottomTrailing) {
                    if Self.showsJumpToBottom(placed: hasScrolledToInitialBottom, scrollable: isScrollable, atBottom: isAtBottom) {
                        JumpToBottomButton {
                            isAtBottom = true
                            withAnimation { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: isAtBottom)
                .animation(.easeInOut(duration: 0.18), value: isScrollable)
                .onAppear {
                    guard !hasScrolledToInitialBottom else { return }
                    placeInitially(proxy)
                }
                // The Mac host swaps items in place — same `ItemDetailView`
                // call site, new `model.item` — which SwiftUI treats as the
                // SAME view identity, so `.onAppear` above only fires once
                // for the whole lifetime, not per item. This re-runs the
                // initial-scroll decision whenever the item underneath an
                // unchanged identity actually changes; on iOS, where each
                // item gets a fresh push (and so a fresh identity), this is
                // a harmless no-op duplicate of `.onAppear`.
                .onChange(of: item.id) { _, _ in
                    placeInitially(proxy)
                }
                // Follow-tail: once the reader has settled at the bottom, a
                // newly-arrived comment (or a locally-queued pending one)
                // re-pins the viewport there, mirroring the chat timeline.
                // `newCount > oldCount` (not just "changed") so a comment
                // being removed doesn't yank the viewport, and gating on
                // `hasScrolledToInitialBottom` means this never fires
                // before the initial placement above has had its say.
                .onChange(of: rowCount) { oldCount, newCount in
                    guard Self.shouldFollowTail(loadedCount: model.loadedCommentCount, startsAtBottom: startsAtBottom,
                                                placed: hasScrolledToInitialBottom, atBottom: isAtBottom,
                                                oldCount: oldCount, newCount: newCount) else { return }
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .cardSelection(self)
            }
            Divider()
            ReplyComposer(draft: draft, attachments: model.stagedAttachments, isBusy: model.isBusy,
                          onSubmit: onSubmit, onAttach: onAttach, onVoiceNote: onVoiceNote,
                          onRemoveAttachment: onRemoveAttachment)
        }
        // The chat timeline's cream ground (warm-dark in dark mode) under
        // thread, action bar and composer alike — an item thread used to
        // sit on the bare system background, solid black in dark mode,
        // unlike every other reading surface in the app.
        .background(MatronTimelineBackground())
    }

    /// Whether the jump-to-bottom button is offered: only after the
    /// initial placement has run (so it can't flash during the opening
    /// scroll), only when the thread overflows its viewport (a short
    /// thread has nowhere to jump; before the first geometry callback
    /// `scrollable` is false, which keeps a freshly opened item quiet),
    /// and only while the reader is away from the bottom.
    static func showsJumpToBottom(placed: Bool, scrollable: Bool, atBottom: Bool) -> Bool {
        placed && scrollable && !atBottom
    }

    /// The one-time placement decision for an item (Bugbot, PR #198): it
    /// is made whether or not we scroll — staying at the top still arms
    /// follow-tail — and a bottom placement also marks the reader as AT
    /// the bottom straight away, so comments that land after the first
    /// `scrollTo` (they arrive on their own stream) re-pin the tail before
    /// the first geometry callback has said anything.
    private func placeInitially(_ proxy: ScrollViewProxy) {
        hasScrolledToInitialBottom = true
        isAtBottom = startsAtBottom
        // `isScrollable` is deliberately NOT reset here. Geometry only
        // re-reports when the (atBottom, scrollable) pair actually changes,
        // so a Mac in-place swap between two overflowing threads would
        // never restore a cleared flag and the jump button would stay
        // hidden for good (Bugbot, round 2). Left alone, a swap onto a
        // thread with different overflow flips it as soon as the new
        // content is measured — a same-pass update, not a visible flash —
        // and a swap between like threads has nothing to correct.
        guard startsAtBottom else { return }
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
    }

    /// The follow-tail decision for a thread that just grew (Bugbot, PR
    /// #198, rounds 1–4). Only re-pins when the growth started from a
    /// thread that was already loaded — `oldCount` at or above
    /// `loadedCount` — so the opening refetch of an unread item is never
    /// mistaken for a new reply, whichever SwiftUI update the loaded count
    /// lands in (same update as the rows: old 0 < loaded 8; a later one:
    /// loaded still nil) and even if a stale pre-refetch snapshot replays
    /// afterwards (8→3 shrinks, 3→8 starts below 8). Also requires the
    /// initial placement to have run, the reader at the bottom, and real
    /// growth (a removed comment must not yank the viewport). A
    /// `startsAtBottom` reader is exempt from the load gate: they asked
    /// for the tail, `placeInitially` marked them at-bottom before any
    /// geometry callback, and the rows landing during the load are
    /// exactly what must keep them pinned there.
    static func shouldFollowTail(loadedCount: Int?, startsAtBottom: Bool, placed: Bool, atBottom: Bool,
                                 oldCount: Int, newCount: Int) -> Bool {
        guard placed, atBottom, newCount > oldCount else { return false }
        if startsAtBottom { return true }
        guard let loadedCount else { return false }
        return oldCount >= loadedCount
    }

    /// Whether the action-button row draws: only for an open item that
    /// has actions. The view model already offers none for a closed item;
    /// checking the item here too keeps a stale model from flashing
    /// buttons on an item that has just closed.
    static func showsActions(_ actions: [String], isOpen: Bool) -> Bool {
        isOpen && !actions.isEmpty
    }

    #if os(macOS)
    /// The trailing room the title-bar menu (`MacItemHeaderBar`) takes from
    /// the pane's edge, gap included: its 30 pt circle, the bar's 8 pt
    /// inset and a 6 pt gap.
    static let titleBarMenuWidth: CGFloat = 44

    /// Extra room above the header when the thread runs up under the clear
    /// title bar: with the thread's 16 pt padding the header starts 34 pt
    /// down, about halfway between none and the strip's full 52 pt
    /// (`MacChatHeaderAccessory.height`). The status chip can still reach
    /// the strip's ⋯ menu, so `titleBarMenuReserve` keeps them apart.
    static let titleBarClearance: CGFloat = 18

    /// How much the header's top row must give up so the menu clears it,
    /// in a pane `paneWidth` wide: the thread is the measure plus its
    /// padding, centred, so only the part of the menu that reaches past
    /// the margin beside it.
    static func titleBarMenuReserve(paneWidth: CGFloat) -> CGFloat {
        let column = min(paneWidth, ItemTypography.measure + 2 * threadPadding)
        let margin = (paneWidth - column) / 2
        return max(0, titleBarMenuWidth - margin - threadPadding)
    }

    /// The `.padding()` round the thread column.
    static let threadPadding: CGFloat = 16
    #endif

    private var statusText: String {
        if item.needsUser { return "Needs you" }
        if item.state == .closed { return "Closed" + (item.resolution.map { " · \(ItemGlyph.label($0))" } ?? "") }
        return item.awaiting == .agent ? "With the agent" : "Open"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: ItemGlyph.symbol(item.kind)).foregroundStyle(ItemGlyph.tint(item.kind))
                Text("#\(item.num) · \(ItemGlyph.label(item.kind))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(statusText).font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((item.needsUser ? Color.orange : Color.secondary).opacity(0.18), in: Capsule())
            }
            #if os(macOS)
            .padding(.trailing, fillsTitleBar ? titleBarReserve : 0)
            #endif
            if !model.context.isEmpty { contextBlock(model.context) }
            Text(item.title).font(ItemTypography.titleFont).textSelection(.enabled)
        }
    }

    /// The context block's icon column — wide enough for the widest glyph
    /// it draws (the owner's two bubbles) at caption size.
    @ScaledMetric(relativeTo: .caption) private var contextIconWidth: CGFloat = 18

    /// Where the item lives: its mission and the
    /// conversation that owns it (filed it) — one caption line each, each
    /// a way there. Answers "which conversation is this connected to?"
    /// without leaving the item.
    private func contextBlock(_ context: ItemContext) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let mission = context.mission {
                contextRow(mission.label, systemImage: MissionGlyph.symbol(),
                           accessibility: "Mission: \(mission.label)", hint: "Opens the mission",
                           action: onOpenMission.map { open in { open(mission.num) } })
            }
            if let owner = context.owner {
                contextRow(owner.label, systemImage: "bubble.left.and.bubble.right",
                           accessibility: "Conversation: \(owner.label)"
                               + (owner.isOpenable ? "" : ", not on this device yet"),
                           hint: "Opens the conversation",
                           action: owner.isOpenable ? { onOpenConversation(owner.id) } : nil)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// One context line: icon and label, truncated to a single line, a
    /// plain button when it has somewhere to go, lighter text when not.
    /// The icon sits in a fixed column so both labels start at the same
    /// edge, whatever their glyphs' widths.
    @ViewBuilder
    private func contextRow(_ text: String, systemImage: String, accessibility: String, hint: String,
                            action: (() -> Void)?) -> some View {
        let label = HStack(spacing: 6) {
            Image(systemName: systemImage).imageScale(.small).frame(width: contextIconWidth)
            Text(verbatim: text).lineLimit(1).truncationMode(.tail)
        }
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibility)
                .accessibilityHint(hint)
        } else {
            // Nothing to open: drawn a step lighter, so it doesn't read as
            // a link.
            label.foregroundStyle(.tertiary)
                .accessibilityElement(children: .ignore).accessibilityLabel(accessibility)
        }
    }

    /// The original post — body and item-level attachments — in the same
    /// card as a comment, captioned with who filed it and when, so the
    /// thread reads as one conversation instead of a bare body followed
    /// by carded replies. Tinted like a comment from the
    /// same author.
    private var bodyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            authorCaption(item.createdBy, date: item.createdAt)
            segmentedBody(item.body, attachments: item.attachments, selectionID: Self.bodySelectionID(for: item.id))
        }
        .itemCard(mine: item.createdBy == .user)
    }

    /// A markdown body at the item reading scale with the thread's leading
    /// — one call for the item body and every comment. On the Mac it is the
    /// chat timeline's selectable NSTextView at `MarkdownAttributed.Style
    /// .item`, so a drag selects across paragraphs, lists and code — and,
    /// through `cardSelection`, across cards — built only
    /// once the card nears the screen (`defersTextView`).
    /// MarkdownUI's per-block `Text`s (`Theme.matronItem`) stay on iOS,
    /// where selection is a long-press affair and cannot span blocks either
    /// way.
    @ViewBuilder
    private func itemBody(_ markdown: String, selectionID: String) -> some View {
        #if os(macOS)
        SelectableMessageText(markdown, itemID: selectionID, style: .item, defersTextView: true)
        #else
        MarkdownText(markdown, theme: .matronItem, lineSpacing: ItemTypography.lineSpacing)
        #endif
    }

    /// A body with its inline attachments (`![caption](attachment:ref)`,
    /// shared spec "inline images") drawn in place: each text segment
    /// through `itemBody`, each placed attachment through the same view a
    /// trailing one gets (image with its size and tap-to-full-screen, or
    /// the file row), and the attachments no ref placed after it all, as
    /// before. A body with no refs is one text segment — unchanged.
    /// `showsTrailing` is off for a status note, which never drew its
    /// attachments.
    @ViewBuilder
    private func segmentedBody(_ markdown: String, attachments list: [TrackerAttachment], selectionID: String,
                               showsTrailing: Bool = true) -> some View {
        let split = splitInlineAttachments(body: markdown, attachments: list)
        ForEach(Self.bodyParts(split, selectionID: selectionID)) { part in
            switch part.content {
            case .text(let text): itemBody(text, selectionID: part.id)
            case .attachment(let a): attachmentView(a)
            }
        }
        if showsTrailing { attachments(split.trailing) }
    }

    /// One drawn piece of a segmented body. A text part's id is its
    /// selection id (`segmentSelectionID`); an attachment's is its blob,
    /// which the splitter places at most once per body.
    struct BodyPart: Identifiable {
        let id: String
        let content: InlineSegment
    }

    static func bodyParts(_ split: InlineAttachmentSplit, selectionID: String) -> [BodyPart] {
        var textIndex = 0
        return split.segments.map { segment in
            switch segment {
            case .text:
                defer { textIndex += 1 }
                return BodyPart(id: segmentSelectionID(selectionID, textIndex: textIndex), content: segment)
            case .attachment(let a):
                return BodyPart(id: "attachment:" + a.blobRef, content: segment)
            }
        }
    }

    /// The selection id of a card's `textIndex`th text segment. The first
    /// keeps the card's own id, so a body without inline attachments
    /// selects and copies exactly as before; the rest are suffixed.
    static func segmentSelectionID(_ cardID: String, textIndex: Int) -> String {
        textIndex == 0 ? cardID : cardID + segmentSeparator + String(textIndex)
    }

    static let segmentSeparator = "#seg"

    /// The card a selection id belongs to — `segmentSelectionID` undone.
    static func cardID(ofSelectionID id: String) -> String {
        guard let range = id.range(of: segmentSeparator, options: .backwards),
              id[range.upperBound...].allSatisfy(\.isNumber), Int(id[range.upperBound...]) != nil else { return id }
        return String(id[..<range.lowerBound])
    }

    /// Every selection id a card contributes, in reading order: its own id,
    /// then one per further text segment.
    static func selectionIDs(cardID: String, body: String, attachments: [TrackerAttachment]) -> [String] {
        let texts = splitInlineAttachments(body: body, attachments: attachments).textSegmentCount
        return [cardID] + (1..<max(texts, 1)).map { segmentSelectionID(cardID, textIndex: $0) }
    }

    /// The selection id of the body card. Prefixed so it can never collide
    /// with a comment id — both are journal ids, and the selection
    /// controller keys its targets by id.
    static func bodySelectionID(for itemID: String) -> String { "body:" + itemID }

    /// Row order for the cross-card selection: the body card first (when
    /// it renders at all — a body or attachments), then every comment
    /// that renders a card — every non-status comment, plus a status row
    /// that carries a closing/reopening note. A card with no text (a voice note, a
    /// file) has no text view to highlight, but it is still a row a drag
    /// passes THROUGH, and the transcript stands in a marker for it — the
    /// chat timeline's rule for an uncaptioned image (reviewer, PR #232).
    static func selectionOrder(item: TrackerItem, comments: [TrackerComment]) -> [String] {
        var ids: [String] = []
        if !item.body.isEmpty || !item.attachments.isEmpty {
            ids += selectionIDs(cardID: bodySelectionID(for: item.id), body: item.body, attachments: item.attachments)
        }
        for c in comments where c.kind != .status || !c.body.isEmpty {
            ids += selectionIDs(cardID: c.id, body: c.body, attachments: c.attachments)
        }
        return ids
    }

    /// "You · 5 min ago" / "Agent · 3 Sept" above a card's body. A reply
    /// that was an action-button tap leads with a small tap glyph.
    private func authorCaption(_ author: ItemAuthor, date: Date, tapped: Bool = false) -> some View {
        authorCaption(name: author == .user ? "You" : "Agent", conversation: nil, date: date, tapped: tapped)
    }

    /// A comment's caption: an agent's is headed with the box that wrote it
    /// and, when the journal names it, the conversation — so a thread
    /// several sessions post in says which one wrote what. The conversation
    /// opens on a tap and is the part that truncates in a narrow card; the
    /// name and the time always show.
    private func authorCaption(_ comment: TrackerComment, tapped: Bool = false) -> some View {
        authorCaption(name: comment.authorName, conversation: comment.authorConversation, date: comment.createdAt, tapped: tapped)
    }

    private func authorCaption(name: String, conversation: (id: String, title: String)?, date: Date,
                               tapped: Bool) -> some View {
        HStack(spacing: 4) {
            if tapped {
                Image(systemName: "hand.tap")
                    .font(ItemTypography.captionDetailFont)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Tapped")
            }
            Text(verbatim: name).font(ItemTypography.captionFont.weight(.semibold)).lineLimit(1).layoutPriority(2)
            if let conversation {
                Button { onOpenConversation(conversation.id) } label: {
                    Text(verbatim: "· \(conversation.title)").font(ItemTypography.captionDetailFont)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Conversation: \(conversation.title)")
                .accessibilityHint("Opens the conversation")
            }
            Text("· \(relativeDate(date))").font(ItemTypography.captionDetailFont).foregroundStyle(.tertiary)
                .lineLimit(1).layoutPriority(1)
        }
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.labels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.labels, id: \.self) { l in
                        Text(l).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
            }
            ForEach(item.links, id: \.url) { link in
                Button { if let u = URL(string: link.url) { onOpenLink(u) } } label: {
                    Label(link.title ?? link.url, systemImage: "link").font(.caption).lineLimit(1)
                }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
    }

    /// The spawn consent card for a consent item, between the
    /// meta row and the body so the answer sits near the top of the thread.
    /// The full `AgentSpawnRequestCard` when the card's own event is in the
    /// local store — its task is then byte-for-byte what the timeline card
    /// shows. Without it there is nothing to approve: the id in the item's
    /// link is agent-written and could name an ask the user has never seen,
    /// so the placeholder says the card has not arrived and offers no
    /// buttons; the view model re-derives the moment it syncs. The body
    /// stays either way; it holds facts (model, room flag) the card does
    /// not draw.
    @ViewBuilder
    private func spawnConsentCard(_ consent: ItemSpawnConsent) -> some View {
        if let request = consent.request {
            AgentSpawnRequestCard(request: request, state: consent.state,
                                  onApprove: { onAnswerSpawn?(true) }, onDeny: { onAnswerSpawn?(false) },
                                  onOpen: onOpenRoom)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("Agent spawn request").font(.callout.weight(.semibold))
                } icon: {
                    Image(systemName: "sparkles.rectangle.stack").foregroundStyle(.tint)
                }
                Text("The request card hasn't reached this device yet. It can be approved once it arrives, or from the conversation it was asked in.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.matronBubbleBot)
                    .shadow(color: .matronBubbleShadow, radius: 2, y: 1)
            )
        }
    }

    /// Renders a list of attachments using the shared chat-timeline
    /// primitives (`AttachmentImage` / `AttachmentFile`) so items match the
    /// conversation surface. Audio gets a bespoke waveform + transcript
    /// treatment per the tracker spec — neither shared primitive covers
    /// audio playback yet.
    @ViewBuilder
    private func attachments(_ list: [TrackerAttachment]) -> some View {
        ForEach(list, id: \.blobRef) { a in
            attachmentView(a)
        }
    }

    /// One attachment, placed inline or trailing.
    @ViewBuilder
    private func attachmentView(_ a: TrackerAttachment) -> some View {
        if a.isImage {
            AttachmentImage(image: image(a), meta: ByteCountFormatter.string(fromByteCount: a.size, countStyle: .file),
                            pixelSize: a.pixelSize, onTap: { onOpenAttachment(a) })
        } else if a.isAudio {
            VStack(alignment: .leading, spacing: 4) {
                Button { onOpenAttachment(a) } label: { Label("Voice note", systemImage: "waveform") }.buttonStyle(.plain)
                if let transcript = a.transcript, !transcript.isEmpty {
                    Text(transcript).font(.system(size: bodySize)).lineSpacing(ItemTypography.lineSpacing).foregroundStyle(.secondary)
                } else if a.transcriptionFailed {
                    Text("Couldn’t transcribe — tap to listen").font(.subheadline).foregroundStyle(.tertiary).italic()
                } else {
                    Text("Transcribing…").font(.subheadline).foregroundStyle(.tertiary).italic()
                }
            }
        } else {
            AttachmentFile(filename: a.name, sizeBytes: a.size, onTap: { onOpenAttachment(a) })
        }
    }

    @ViewBuilder
    private func commentView(_ c: TrackerComment) -> some View {
        #if DEBUG
        let _ = ItemDetailViewProbe.commentRowBuilds += 1
        #endif
        if c.kind == .status {
            // The note an agent or the user leaves when closing or
            // reopening (item_close's `comment`) is a real message, often
            // with links (`matron://item/N`, a PR): it renders as an
            // ordinary card at body size, through the same markdown path as
            // any comment, so its links are tappable. Only the transition
            // itself stays a small centred caption.
            VStack(alignment: .leading, spacing: 8) {
                if let line = statusLine(c) {
                    Text(line).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                if !c.body.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        authorCaption(c)
                        segmentedBody(c.body, attachments: c.attachments, selectionID: c.id, showsTrailing: false)
                    }
                    .itemCard(mine: c.author == .user)
                }
            }
        } else {
            let delivery = c.author == .user ? model.queuedReplies[c.id] : nil
            VStack(alignment: .leading, spacing: 6) {
                authorCaption(c, tapped: c.action != nil)
                segmentedBody(c.body, attachments: c.attachments, selectionID: c.id)
                if let delivery {
                    ItemReplyDeliveryLine(state: delivery, onSendNow: replyDelivery.sendQueuedNow.map { send in { send(c.id) } },
                                          onCancel: replyDelivery.cancelQueued.map { cancel in { cancel(c.id) } },
                                          // Text only: the reply box can't take
                                          // back an already-uploaded attachment,
                                          // and resending half a reply would
                                          // read as the whole of it.
                                          onEditAndResend: c.attachments.isEmpty && !c.body.isEmpty
                                              ? replyDelivery.editAndResend.map { resend in { resend(c.id) } } : nil)
                }
            }
            .itemCard(mine: c.author == .user)
            // Not yet with the agent: drawn like an outbox row, so it never
            // reads as delivered at a glance.
            .opacity(delivery == nil ? 1 : 0.85)
            // A follow-up question's own buttons (comment action buttons,
            // contract 2026-10-04), under the card that asks — the item's
            // row of buttons, one level down.
            let offered = c.offeredActions(itemIsOpen: item.state == .open)
            if let onCommentAction, !offered.isEmpty {
                ItemActionButtons(actions: offered, selected: model.selectedCommentActions[c.id], isEnabled: !model.isBusy,
                                  identifierPrefix: "comment-action-\(c.id)", onChoose: { label in onCommentAction(c.id, label) })
            }
        }
    }

    /// Relative caption for a comment's timestamp ("5 min ago"), computed
    /// against `now` (not the ambient clock) so snapshot tests are
    /// deterministic. Falls back to an absolute short date once the comment
    /// is more than 7 days older than `now` — "3 mo. ago" reads worse than
    /// an actual date once relative units stop being useful at that range.
    private func relativeDate(_ date: Date) -> String {
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        if now.timeIntervalSince(date) > sevenDays {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Derives the centred status line from `statusTo` (never the raw body,
    /// per the tracker spec — the raw body only renders as a secondary line
    /// beneath when non-empty, handled by the caller).
    ///
    /// Fix wave, item I: this used to say "reopened" for ANY status row
    /// whose `to.state` wasn't `.closed` — including a pure awaiting-only
    /// change (e.g. the agent handing an open item back to the user),
    /// which was never a reopen at all. "Reopened" now only fires on an
    /// actual closed→open transition; other non-closing changes describe
    /// the awaiting change instead, and a status row that changed neither
    /// (state nor awaiting) renders no line — `nil`, not empty-string, so
    /// the caller can skip the row instead of showing a blank line above
    /// a body it already renders separately.
    private func statusLine(_ c: TrackerComment) -> String? {
        let who = c.author == .user ? "You" : "Agent"
        guard let to = c.statusTo else { return "\(who) updated the item" }
        if to.state == .closed {
            return "\(who) closed this" + (to.resolution.map { " as \(ItemGlyph.label($0).lowercased())" } ?? "")
        }
        if c.statusFrom?.state == .closed, to.state == .open {
            return "\(who) reopened this"
        }
        if let toAwaiting = to.awaiting, toAwaiting != c.statusFrom?.awaiting {
            return toAwaiting == .agent ? "Now with the agent" : "Needs you"
        }
        return nil
    }

    /// A comment queued locally (offline outbox / in-flight send) that
    /// hasn't landed in `comments` yet. Reuses `SendStateIndicator` so the
    /// caption matches the chat timeline's own queued/failed treatment
    /// instead of forking a bespoke label.
    private func pendingView(_ p: PendingComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You").font(ItemTypography.captionFont.weight(.semibold))
            if !p.body.isEmpty { Text(p.body).font(.system(size: bodySize)).lineSpacing(ItemTypography.lineSpacing) }
            if p.attachmentCount > 0 { Label("\(p.attachmentCount) attachment\(p.attachmentCount == 1 ? "" : "s")", systemImage: "paperclip").font(.caption) }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SendStateIndicator(state: pendingState(p))
                Spacer(minLength: 0)
                // Waiting out a retry backoff (or failed): Send now tries it
                // at once, Cancel withdraws it. A first attempt still in
                // flight has nothing to hurry and may already have landed.
                if pendingState(p) != .sending {
                    if let cancel = replyDelivery.cancelPending {
                        Button("Cancel") { cancel(p.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityHint(p.attachmentCount > 0
                                ? "Withdraws this reply if it hasn't reached the journal yet. Its text goes back in the reply box; its attachments are discarded"
                                : "Withdraws this reply if it hasn't reached the journal yet. Its text goes back in the reply box")
                    }
                    if let sendNow = replyDelivery.sendPendingNow {
                        Button("Send now", action: sendNow)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }
        }
        .itemCard(mine: true)
        .opacity(0.85)
    }

    /// Maps outbox progress to the shared glyph: a fresh comment that
    /// hasn't attempted a send yet reads as "Sending…"; once at least one
    /// attempt has been made without an error it's genuinely waiting on
    /// connectivity ("Queued"); any recorded error wins and shows the
    /// retry affordance regardless of attempt count.
    private func pendingState(_ p: PendingComment) -> SendStateGlyph {
        if let lastError = p.lastError { return .failed(reason: lastError) }
        if p.attempts > 0 { return .queued }
        return .sending
    }
}

#if os(macOS)
extension ItemDetailView {
    /// The pasteboard text for a finished cross-card selection — the chat
    /// timeline's own "[date] Name: text" shape (`TranscriptFormatter`),
    /// one entry per selected card in row order. The selected text comes
    /// first; each attachment follows on its own line as a marker
    /// (`attachmentMarker`), so a voice-note reply copies its transcript
    /// rather than vanishing. A card whose text view exists but has
    /// nothing selected (the pointer sat in the gap above it) and an id
    /// that no longer names a card contribute nothing. The reader is
    /// "Me", as in the timeline; the agent is its box's name, else "Agent", as in the captions.
    static func transcript(item: TrackerItem, comments: [TrackerComment], spans: [SelectedSpan],
                           locale: Locale = .current, timeZone: TimeZone = .current) -> SelectionTranscript {
        // A card with inline attachments has one text view per text
        // segment (`segmentSelectionID`); its spans arrive together, in
        // row order, and copy as one entry.
        var groups: [(cardID: String, texts: [String?])] = []
        for span in spans {
            let card = cardID(ofSelectionID: span.id)
            if let last = groups.last, last.cardID == card {
                groups[groups.count - 1].texts.append(span.text)
            } else {
                groups.append((card, [span.text]))
            }
        }
        var entries: [TranscriptEntry] = []
        for group in groups {
            let author: ItemAuthor
            let date: Date
            let attachments: [TrackerAttachment]
            // An agent's comment is named by its box, as its caption is.
            var agentName = "Agent"
            if group.cardID == bodySelectionID(for: item.id) {
                author = item.createdBy
                date = item.createdAt
                attachments = item.attachments
            } else if let comment = comments.first(where: { $0.id == group.cardID }) {
                author = comment.author
                agentName = comment.authorName
                date = comment.createdAt
                attachments = comment.attachments
            } else {
                continue
            }
            // `""` means a text view exists and none of it is selected —
            // skip the whole card, markers included, as the timeline does
            // for an image whose caption view has an empty selection.
            let viewed = group.texts.compactMap { $0 }
            if !viewed.isEmpty, viewed.allSatisfy(\.isEmpty) { continue }
            var lines = viewed.filter { !$0.isEmpty }
            lines += attachments.map(attachmentMarker)
            guard !lines.isEmpty else { continue }
            entries.append(TranscriptEntry(timestamp: date, name: author == .user ? "Me" : agentName,
                                           text: lines.joined(separator: "\n")))
        }
        return SelectionTranscript(text: TranscriptFormatter.format(entries, locale: locale, timeZone: timeZone),
                                   messageCount: entries.count)
    }

    /// What an attachment contributes to a copied transcript: a voice
    /// note carries its transcript (the words are what the reader wants),
    /// an image the timeline's `[Photo]`, anything else `[File: name]`.
    static func attachmentMarker(_ attachment: TrackerAttachment) -> String {
        if attachment.isAudio {
            if let transcript = attachment.transcript, !transcript.isEmpty { return "[Voice note] " + transcript }
            return "[Voice note]"
        }
        if attachment.isImage { return "[Photo]" }
        return "[File: \(attachment.name)]"
    }

    /// Row order as the controller wants it, recomputed from the model.
    fileprivate var selectionOrder: [String] { Self.selectionOrder(item: item, comments: model.comments) }

    /// Installs the spans → transcript bridge for `model` — the value the
    /// `onChange` that calls this just received, captured by value:
    /// comments are immutable once posted and the provider is re-installed
    /// whenever the model changes, so what a finished selection copies is
    /// what the cards showed when it finished.
    fileprivate func installTranscriptProvider(for model: Model) {
        cardSelection.transcriptProvider = { [weak cardSelection] in
            guard let cardSelection else { return SelectionTranscript(text: "", messageCount: 0) }
            return Self.transcript(item: model.item, comments: model.comments, spans: cardSelection.selectedSpans())
        }
    }
}
#endif

extension View {
    /// See the call site in `ItemDetailView.body`.
    func threadScrollFrame() -> some View {
        ThreadScrollFrame { self }
    }
}

/// Answers every size question about the thread's scroll view itself and
/// lays the scroll view out only at the size it is finally given. A
/// `.frame(min…ideal…max)` was not enough: a flexible frame clamps a
/// below-minimum probe UP to its minimum and still asks its child, so a
/// split view's minimum-size probe measured every card of the thread a
/// second time at the minimum width — on a 99-comment thread, a full
/// TextKit layout of every card, every open. A scroll view
/// fills whatever it is offered, so the answer never needs the content:
/// the proposal on an axis that has one (raised to a small minimum), the
/// ideal on an axis that doesn't.
struct ThreadScrollFrame: Layout {
    static let minimum = CGSize(width: 240, height: 120)
    /// The ideal when a container asks without proposing — any fixed value:
    /// the thread scrolls, so its real height is whatever it is given.
    static let ideal = CGSize(width: ItemTypography.measure, height: 400)

    static func size(for proposal: ProposedViewSize) -> CGSize {
        CGSize(width: max(proposal.width ?? ideal.width, minimum.width),
               height: max(proposal.height ?? ideal.height, minimum.height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.size(for: proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }

    // No alignment guides of its own. The default implementation answers by
    // placing the content at the probe's size — a full trial layout of the
    // thread at the split view's minimum width, every open.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

private extension View {
    /// The Mac cross-card selection plumbing on the thread's scroll view:
    /// the controller in the environment for every
    /// `SelectableMessageText` under it, the row order kept in step with
    /// the model, the transcript provider re-installed as comments land,
    /// and the selection dropped on the way out so its clear-monitor does
    /// not outlive the thread. No-op on iOS.
    @ViewBuilder
    func cardSelection(_ detail: ItemDetailView) -> some View {
        #if os(macOS)
        self
            .environment(detail.cardSelection)
            .onChange(of: detail.selectionOrder, initial: true) { _, order in
                detail.cardSelection.orderedIDs = order
            }
            .onChange(of: detail.model, initial: true) { _, model in
                detail.installTranscriptProvider(for: model)
            }
            .onDisappear { detail.cardSelection.clear() }
        #else
        self
        #endif
    }

    /// The thread's card chrome — the chat bubble surfaces on a rounded
    /// rectangle with the bubble shadow — shared by the body card, the
    /// comment cards and the pending rows so they read as one thread.
    func itemCard(mine: Bool) -> some View {
        self
            .padding(ItemTypography.cardPadding)
            .background(mine ? Color.matronBubbleMe : Color.matronBubbleBot, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .matronBubbleShadow, radius: 2, y: 1)
    }

    /// Reports whether a `ScrollView`'s bottom is currently visible, via
    /// `onScrollGeometryChange` (iOS 18 / macOS 15 — same wave as
    /// `onUserScrollGesture`'s `onScrollPhaseChange`, see that file). The
    /// app's real deployment target is 18/15 (`project.yml`), but
    /// `MatronShared`'s own declared package platforms are more
    /// conservative (iOS 17 / macOS 14), so this still needs the
    /// availability guard to typecheck; the `else` branch is a no-op
    /// (`ItemDetailView.onBottomVisibilityChange` just never fires,
    /// falling back to the existing "always opens at the top" behaviour).
    @ViewBuilder
    func onItemThreadGeometryChange(action: @escaping (ItemThreadGeometry) -> Void) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            self.onScrollGeometryChange(for: ItemThreadGeometry.self) { geometry in
                ItemThreadGeometry(
                    atBottom: geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 8,
                    scrollable: geometry.contentSize.height > geometry.containerSize.height + 8
                )
            } action: { _, geometry in
                action(geometry)
            }
        } else {
            self
        }
    }
}

/// The two facts `ItemDetailView` needs from the thread's scroll geometry.
struct ItemThreadGeometry: Equatable {
    var atBottom: Bool
    var scrollable: Bool
}

extension EnvironmentValues {
    /// Set by a host with no header of its own over the thread — the Mac
    /// Decisions page. The thread then starts at the top of the window,
    /// under its clear title bar, and `ItemDetailView` leaves out its
    /// pinned ⋯ row: the host draws `ItemResolveControl` in the title bar.
    /// Mac only; iOS puts the control in the navigation bar.
    @Entry public var itemDetailFillsTitleBar = false
}

private extension View {
    /// See `EnvironmentValues.itemDetailFillsTitleBar`. The title bar over
    /// it is clear on every page (`MacChatHeaderAccessory.installed`).
    @ViewBuilder
    func fillingTitleBar(_ fills: Bool) -> some View {
        if fills { ignoresSafeArea(.container, edges: .top) } else { self }
    }
}

/// An item reply's draft as accessors, not a `Binding`.
/// `Binding(get:set:)` calls its getter as it is made, so a host that builds
/// one in its body re-runs that body — and the whole thread under it — on
/// every keystroke. Hosts hand these closures over instead; `ReplyComposer`
/// makes the binding inside its own small body.
public struct ItemReplyDraft {
    let get: () -> String
    let set: (String) -> Void

    public init(get: @escaping () -> String, set: @escaping (String) -> Void) {
        self.get = get; self.set = set
    }

    /// Wraps an existing binding (previews, tests). Reads it only when the
    /// composer does.
    public init(_ binding: Binding<String>) {
        self.init(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0 })
    }
}

/// `ItemCommentComposer` behind the draft's binding: the one body that
/// re-runs as the reader types.
private struct ReplyComposer: View {
    let draft: ItemReplyDraft
    let attachments: [StagedAttachment]
    let isBusy: Bool
    let onSubmit: () -> Void
    let onAttach: () -> Void
    let onVoiceNote: () -> Void
    let onRemoveAttachment: (UUID) -> Void

    var body: some View {
        ItemCommentComposer(draft: Binding(get: draft.get, set: draft.set), attachments: attachments, isBusy: isBusy,
                            onSubmit: onSubmit, onAttach: onAttach, onVoiceNote: onVoiceNote,
                            onRemoveAttachment: onRemoveAttachment)
    }
}

#if DEBUG
/// Test seam: counts comment rows built by `ItemDetailView`'s
/// body. Typing in the reply must build none — the thread does not depend on
/// the draft. Main-thread only.
public enum ItemDetailViewProbe {
    nonisolated(unsafe) public static var commentRowBuilds = 0
}
#endif
