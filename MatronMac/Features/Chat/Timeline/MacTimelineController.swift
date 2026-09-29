import AppKit
import SwiftUI
import QuartzCore
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// What hosted rows and text rows call out to. Fixed per screen in practice;
/// `MacTimelineController.update(actions:)` swaps them without re-rendering
/// (every row closure reads the controller's CURRENT actions when invoked).
struct MacTimelineActions {
    var onOpenSubChat: (String) -> Void
    var onOpenSpawnRoom: ((String) -> Void)?
    var onOpenItem: ((String) -> Void)?
    var onOpenMission: ((String) -> Void)?
    var onPreviewImage: (URL, Image) -> Void
    var linkRouting: MacTimelineLinkRouting

    static let inert = MacTimelineActions(onOpenSubChat: { _ in }, onOpenSpawnRoom: nil, onOpenItem: nil,
                                          onOpenMission: nil, onPreviewImage: { _, _ in }, linkRouting: .init())
}

/// The AppKit chat timeline (spec 2026-09-28): a virtualised `NSTableView`
/// that is the second `TimelineSurface` over `TimelineSession` (the iOS
/// collection view is the first). It reads the unchanged `ChatViewModel`
/// through Observation, measures every row exactly before applying it, and
/// writes the clip view's origin only with the value `TimelineScrollModel`
/// decided (`setContentOffset`).
///
/// Geometry mapping — the table's row rects equal the model's:
/// - table row 0 is a spacer of `alignmentPad + topInset` (the bottom hug
///   of a short conversation plus the list's top padding);
/// - table rows 1…n are the model's rows (table index = model index + 1),
///   each carrying the `VStack(spacing: 8)` gap below it (all but the last)
///   — the model runs with `rowSpacing: 0`;
/// - the last table row is the footer, `bottomInset + footerHeight` (the
///   list's bottom padding plus the activity indicator).
@MainActor
final class MacTimelineController: NSViewController, TimelineSurface, NSTableViewDataSource, NSTableViewDelegate {
    /// Up to this many unmeasured text rows are measured on the spot (a new
    /// message, the streaming row); more wait for the background precompute.
    static let synchronousMeasureLimit = 8
    /// `MacTimelineListContent`'s `VStack(spacing: 8)`, folded into heights.
    static let rowSpacing: CGFloat = 8
    static let metrics = TimelineScrollModel.Metrics(topInset: 16, bottomInset: 16, rowSpacing: 0,
                                                     nearBottomThreshold: 100, nearTopScreens: 1.5)
    /// `NSTableView` rejects non-positive row heights; a hosted row that
    /// renders nothing as the LAST row (no gap folded in) gets this instead.
    private static let minimumTableRowHeight: CGFloat = 0.01
    private static let footerIdentifier = NSUserInterfaceItemIdentifier("timeline.footer")

    let viewModel: ChatViewModel
    let stripViewModel: SubChatStripViewModel
    let bridge: MacTimelineBridge
    let selection: MessageSelectionController

    /// Implicitly unwrapped only because the session needs `self` as its
    /// surface; set in `init`, never nil afterwards.
    private(set) var session: TimelineSession!
    private(set) var tableView: NSTableView!
    private(set) var scrollView: MacTimelineScrollView!

    private var actions: MacTimelineActions
    private let cache: MacTimelineMeasureCache
    private lazy var measurer = MacTimelineMeasurer(hostedRow: { [weak self] content in
        self?.hostedRow(content) ?? AnyView(EmptyView())
    })
    private var coalescer: MacFrameCoalescer?
    /// `mount()` asks for a sync before `loadView` built the coalescer.
    private var syncRequestedBeforeLoad = false

    /// The measurement every applied row was laid out with (text rows carry
    /// their whole render — row views configure from it).
    private var measurements: [String: MacRowMeasurement] = [:]
    /// What the table currently believes, step by step through every
    /// structural edit: model ids (table rows 1…n) and every table row's
    /// height (spacer and footer included). Data source and `heightOfRow`
    /// answer from these, never from the model directly, so the table is
    /// consistent even mid-edit.
    private var tableIDs: [String] = []
    private var tableHeights: [CGFloat] = []
    private var width: CGFloat = 0
    private var lastViewportHeight: CGFloat = -1
    private var forceSynchronousMeasure = false
    private var precomputeLanded = false
    /// A landed batch came up short (the window grew while it ran) and its
    /// off-screen remainder went to a second batch; that one applies even
    /// if it lands short too, so the two never ping-pong.
    private var precomputeRetried = false
    private var precomputeTask: Task<Void, Never>?
    private var precomputeIDs = Set<String>()
    /// The width the in-flight batch measures at: a batch for another width
    /// (a live resize moved on) never covers this pass.
    private var precomputeWidth: CGFloat = 0
    private var precomputeGeneration = 0
    /// A non-live width change is still replacing other-width measurements
    /// of off-screen rows with background ones (cleared once none remain).
    private var isWidthCatchingUp = false
    /// Rows beyond the clip, each side, measured on main with it.
    private static let onScreenMarginRows = 4
    private var footerHeights: [String: CGFloat] = [:]
    private lazy var footerSizer = NSHostingView<AnyView>(rootView: AnyView(EmptyView()))
    /// The activity label the footer view on screen was configured with.
    private var configuredFooterLabel: String??

    /// Between the scroll view's "began" and "ended" (a wheel / trackpad
    /// gesture including its momentum, or a scroller drag): the gesture's
    /// end decides re-arming, not each move inside it.
    private var isUserGestureActive = false
    /// Only the main chat column drives the perf rig's probe (the SwiftUI
    /// path's `respondsToMenuCommands` guard): a second timeline on screen
    /// must never steal it.
    let registersPerfProbe: Bool

    private var isTornDown: Bool { session.isTornDown }
    private var isSuspended: Bool { session.isSuspended }
    var hasPendingWork: Bool {
        precomputeTask != nil || (coalescer?.isPending ?? syncRequestedBeforeLoad)
    }

    #if DEBUG
    /// How many table delegate / data-source callbacks are on the stack.
    /// Structural edits made while it is non-zero are the "reentrant
    /// operation in its NSTableView delegate" AppKit warns about.
    private var delegateDepth = 0

    /// Logs (so the `-O -DDEBUG` rig, where `assert` compiles out, still
    /// reports it) and asserts that no table delegate callback is on the
    /// stack.
    private func assertOutsideDelegate(_ site: StaticString) {
        guard delegateDepth > 0 else { return }
        NSLog("MacTimeline REENTRANT-GUARD %@ inside a table delegate call (depth %d)\n%@",
              "\(site)", delegateDepth, Thread.callStackSymbols.prefix(40).joined(separator: "\n"))
        assert(delegateDepth == 0, "\(site) ran inside an NSTableView delegate callback")
    }
    #endif

    // MARK: Test seams

    /// Replaces the SwiftUI content of hosted rows it returns non-nil for
    /// (measure and render alike). Set before the first sync.
    var hostedRowOverrideForTesting: ((HostedRowContent) -> AnyView?)?
    private(set) var reconfiguredRowCountForTesting = 0
    private(set) var reloadDataCountForTesting = 0
    /// Text rows measured on the main thread by `sync()`.
    private(set) var syncMeasuredRowCountForTesting = 0
    func resetCountersForTesting() {
        reconfiguredRowCountForTesting = 0
        reloadDataCountForTesting = 0
        syncMeasuredRowCountForTesting = 0
    }

    init(viewModel: ChatViewModel, stripViewModel: SubChatStripViewModel, bridge: MacTimelineBridge,
         selection: MessageSelectionController, actions: MacTimelineActions,
         cache: MacTimelineMeasureCache = .shared, registersPerfProbe: Bool = true) {
        self.viewModel = viewModel
        self.registersPerfProbe = registersPerfProbe
        self.stripViewModel = stripViewModel
        self.bridge = bridge
        self.selection = selection
        self.actions = actions
        self.cache = cache
        super.init(nibName: nil, bundle: nil)
        session = TimelineSession(viewModel: viewModel, surface: self, metrics: Self.metrics)
        bridge.controller = self
        // Cross-message selection over unmounted rows (Task 5): called per
        // unmounted selected row on every drag event, so O(1) lookups only.
        selection.contentProvider = { [weak self] id in
            guard let self, case .text(let render)? = self.measurements[id] else { return nil }
            return (render.rendered.attributed, render.content.body)
        }
        timelineLogger.breadcrumb("mac timeline controller init room=\(viewModel.roomID)")
        session.mount()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(actions: MacTimelineActions) {
        self.actions = actions
    }

    /// Called when SwiftUI removes this timeline. Idempotent.
    func tearDown() {
        guard !isTornDown else { return }
        timelineLogger.breadcrumb("mac timeline controller tearDown room=\(viewModel.roomID)")
        // The session stores the position and latches torn down.
        session.tearDown()
        coalescer?.invalidate()
        cancelPrecompute()
    }

    // MARK: View

    override func loadView() {
        let scrollView = MacTimelineScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = .init()

        let tableView = TimelineTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("timeline"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.usesAutomaticRowHeights = false
        tableView.style = .plain
        tableView.gridStyleMask = []
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.setAccessibilityIdentifier("chat.timeline")
        tableView.onEndLiveResize = { [weak self] in self?.liveResizeEnded() }
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView

        // The user's own scrolling feeds the model; drag-select autoscroll,
        // momentum and keyboard scrolling move the clip with no gesture
        // callbacks, so they only report an offset (`userScrolled(to:)`
        // releases / re-arms follow from the geometry). A torn-down
        // controller (a pane toggle made a new one over the same bridge)
        // must not touch the shared bridge's follow state.
        scrollView.onUserScrollBegan = { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.isUserGestureActive = true
            self.session.userDragBegan()
        }
        scrollView.onUserScrollEnded = { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.isUserGestureActive = false
            self.session.userScrollSettled()
        }
        scrollView.onUserScrolled = { [weak self] y in
            guard let self, !self.isTornDown else { return }
            self.userScrolled(to: y)
        }

        self.scrollView = scrollView
        self.tableView = tableView
        view = scrollView
        // Spacer + footer from the start: the table always has both.
        tableHeights = expectedTableHeights()
        tableView.reloadData()
        coalescer = MacFrameCoalescer(view: scrollView) { [weak self] in self?.sync() }
        if syncRequestedBeforeLoad {
            syncRequestedBeforeLoad = false
            requestSync()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        session.resume()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        session.resume()
        #if DEBUG
        // The perf rig drives whichever timeline is on screen — only when
        // this one is the main chat column (`MacChatView` passes
        // `respondsToMenuCommands`, as the SwiftUI path guards).
        if registersPerfProbe {
            let probe = MacTimelinePerfProbe.shared
            probe.viewModel = viewModel
            probe.scrollViewProvider = { [weak self] in self?.scrollView }
            probe.jumpToBottom = { [weak self] in self?.session.jumpToBottom() }
        }
        #endif
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        session.suspend()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let size = scrollView.contentView.bounds.size
        // A width change keeps the TOP anchor (the resync below), so a
        // height change in the same pass must keep the top too.
        let widthChanging = width > 0 && size.width > 0 && size.width != width
        // The session has no no-op guard: this surface guards.
        if size.height != lastViewportHeight || widthChanging {
            lastViewportHeight = size.height
            session.setViewportHeight(size.height, widthChanging: widthChanging)
        }
        if size.width != width, size.width > 0 {
            #if DEBUG
            assertOutsideDelegate("viewDidLayout width change")
            #endif
            let hadWidth = width > 0
            width = size.width
            tableView.sizeLastColumnToFit()
            footerHeights.removeAll()
            if !hadWidth {
                sync()
            } else if view.inLiveResize {
                // One sync per frame while the window is dragged: visible
                // rows re-measure on main, the rest in the background.
                requestSync()
            } else {
                // A split-view divider drag is no window live resize and
                // steps the width once per pixel: re-measure only what is
                // on screen now (the top anchor holds), the rest in the
                // background — never the whole window on main per step.
                isWidthCatchingUp = true
                cancelPrecompute()
                sync()
            }
        }
    }

    /// Live resize is over: every row at the final width, synchronously.
    private func liveResizeEnded() {
        guard width > 0 else { return }
        resyncSynchronously()
    }

    /// A clip move the user made (or AppKit's drag autoscroll). A move made
    /// while the clip's height differs from the model's viewport is a resize
    /// clamping the origin, not the user: `viewDidLayout` is about to tell
    /// the session the new height and write the model's offset back.
    ///
    /// Follow-tail is geometry-aware here, as on the SwiftUI path: a move
    /// with no gesture around it (momentum after the lift, Page Up / Home /
    /// space in a text view, drag-select autoscroll) that leaves the bottom
    /// releases follow, and one that arrives at the tail re-arms it — else
    /// the next apply would snap a reader who scrolled away back down.
    private func userScrolled(to y: CGFloat) {
        guard !isTornDown, scrollView.contentView.bounds.height == session.scrollModel.viewportHeight else { return }
        session.userScrolled(toOffset: y)
        // The session drops offsets that arrive inside its own layout
        // update; only a move it actually recorded is the reader's. (The
        // controller's own writes never get here: `applyRows` and
        // `setContentOffset` run flagged `isApplyingProgrammaticScroll`.)
        let model = session.scrollModel
        guard !scrollView.isApplyingProgrammaticScroll, model.contentOffsetY == y else { return }
        if model.isFollowingTail, !model.isNearBottom {
            session.userDragBegan()
        } else if !model.isFollowingTail, model.isNearBottom, !isUserGestureActive, !session.hasPendingRestore {
            session.userScrollSettled()
        }
    }

    // MARK: Observation → apply

    private func observeViewModel() {
        withObservationTracking { [viewModel, stripViewModel] in
            _ = viewModel.windowedRows
            _ = viewModel.activityLabel
            _ = viewModel.hasMultipleSenders
            _ = viewModel.windowTailAnchorID
            _ = viewModel.pendingFocusID
            _ = viewModel.lastRenderableItemID
            _ = stripViewModel.children
            for case .message(let item) in viewModel.windowedRows {
                if case .image(let url?, _, _, _) = item.kind { _ = viewModel.imagePixelSize(for: url) }
            }
        } onChange: { [weak self] in
            // The view models mutate on the main actor: mark the frame
            // pending synchronously so `hasPendingWork` never misses it.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.requestSync() }
            } else {
                Task { @MainActor in self?.requestSync() }
            }
        }
    }

    func requestSync() {
        guard !isTornDown, !isSuspended else { return }
        guard let coalescer else {
            syncRequestedBeforeLoad = true
            return
        }
        coalescer.request()
    }

    /// One pass: re-arm observation, build row contents, measure (or defer
    /// to the precompute), apply, then the post-apply position rules.
    func sync() {
        #if DEBUG
        assertOutsideDelegate("sync")
        #endif
        guard !isTornDown, !isSuspended else { return }
        observeViewModel()
        updateSelectionOrder()
        guard width > 0 else { return }
        let built = TimelineRowContentBuilder.build(TimelineRowSource(
            rows: viewModel.windowedRows,
            hasMultipleSenders: viewModel.hasMultipleSenders,
            children: stripViewModel.children,
            imagePixelSize: { [viewModel] url in viewModel.imagePixelSize(for: url) }))
        if !built.droppedDuplicates.isEmpty {
            timelineLogger.breadcrumb("mac timeline dropped duplicate row ids \(built.droppedDuplicates.prefix(5).joined(separator: ","))")
        }

        // A width change (live resize, or a divider drag): off-screen text
        // rows keep their last (other-width) measurement until the
        // background batch (or the end-of-live-resize resync) replaces it;
        // the rows in the clip, plus a small margin, are measured now.
        // Off-screen hosted rows stay stale only during a window live resize
        // (its end resyncs everything); otherwise they measure on main.
        let isLiveResize = view.inLiveResize
        let isLiveResizePass = (isLiveResize || isWidthCatchingUp) && !forceSynchronousMeasure
        let onScreen = isLiveResizePass ? onScreenRowIDs() : []
        var next: [String: MacRowMeasurement] = [:]
        next.reserveCapacity(built.contents.count)
        var missing: [TextRowContent] = []
        var background: [TextRowContent] = []
        for content in built.contents {
            let id = content.anchorID
            if let hit = cache.measurement(roomID: viewModel.roomID, content: content, width: width) {
                next[id] = hit
                continue
            }
            if isLiveResizePass, !onScreen.contains(id), session.contents[id] == content, let stale = measurements[id] {
                if case .text(let text) = content {
                    next[id] = stale
                    background.append(text)
                    continue
                }
                if isLiveResize {
                    next[id] = stale
                    continue
                }
            }
            switch content {
            case .text(let text):
                missing.append(text)
            case .hosted(let hosted):
                // Hosted rows are SwiftUI: always measured on main.
                let measured = MacRowMeasurement.hosted(measurer.hostedHeight(hosted, width: width))
                cache.store(measured, roomID: viewModel.roomID, content: content, width: width)
                next[id] = measured
            }
        }

        let mustApply = forceSynchronousMeasure || precomputeLanded || isLiveResizePass
        if missing.count > Self.synchronousMeasureLimit, !mustApply {
            // No estimates: nothing partial to show until the batch lands.
            schedulePrecompute(missing)
            return
        }
        if precomputeLanded, !precomputeRetried, !forceSynchronousMeasure, !isLiveResizePass,
           missing.count > Self.synchronousMeasureLimit {
            // Landed short: the same split as a width change. Rows the
            // reader can see are measured now; the rest never on main.
            let visible = onScreenRowIDs()
            let later = missing.filter { !visible.contains($0.itemID) }
            let now = missing.filter { visible.contains($0.itemID) }
            syncMeasuredRowCountForTesting += now.count
            for text in now {
                let content = TimelineRowContent.text(text)
                let measured = measurer.measure(content, width: width)
                cache.store(measured, roomID: viewModel.roomID, content: content, width: width)
                next[text.itemID] = measured
            }
            precomputeLanded = false
            if !later.isEmpty {
                precomputeRetried = true
                timelineLogger.breadcrumb("mac timeline precompute landed short: \(now.count) on screen measured on main, \(later.count) rescheduled")
                schedulePrecompute(later)
                return
            }
            missing = []
        }
        if precomputeLanded, missing.count > Self.synchronousMeasureLimit {
            timelineLogger.breadcrumb("mac timeline precompute landed with \(missing.count) rows still missing — measuring on main")
        }
        precomputeLanded = false
        precomputeRetried = false
        // A batch still in flight is moot once everything is measured here.
        if missing.count > Self.synchronousMeasureLimit { cancelPrecompute() }
        syncMeasuredRowCountForTesting += missing.count
        for text in missing {
            let content = TimelineRowContent.text(text)
            let measured = measurer.measure(content, width: width)
            cache.store(measured, roomID: viewModel.roomID, content: content, width: width)
            next[text.itemID] = measured
        }
        apply(built.contents, measured: next, forceReconfigure: forceSynchronousMeasure || isLiveResizePass)
        session.afterApply()
        #if DEBUG
        MacTimelinePerfProbe.shared.noteRowsPresented(roomID: viewModel.roomID, count: built.contents.count)
        #endif
        if background.isEmpty {
            isWidthCatchingUp = false
        } else {
            schedulePrecompute(background)
        }
    }

    /// The model rows in the clip plus `onScreenMarginRows` each side.
    private func onScreenRowIDs() -> Set<String> {
        let model = session.scrollModel
        let visible = model.visibleRowIDs
        guard let first = visible.first.flatMap(model.index(of:)),
              let last = visible.last.flatMap(model.index(of:)) else { return [] }
        let lower = max(0, first - Self.onScreenMarginRows)
        let upper = min(model.rows.count - 1, last + Self.onScreenMarginRows)
        return Set(model.rows[lower...upper].map(\.id))
    }

    private func resyncSynchronously() {
        forceSynchronousMeasure = true
        defer { forceSynchronousMeasure = false }
        cancelPrecompute()
        sync()
    }

    /// Measures the rows (exactly — no estimates), folds the row gap into
    /// every height but the last, and hands the pass to the session.
    private func apply(_ contents: [TimelineRowContent], measured: [String: MacRowMeasurement], forceReconfigure: Bool) {
        // Before the session applies: views configured during it read these.
        measurements = measured
        var heights: [String: CGFloat] = [:]
        heights.reserveCapacity(contents.count)
        for (index, content) in contents.enumerated() {
            let id = content.anchorID
            guard let height = measured[id]?.height else { continue }
            heights[id] = height + (index < contents.count - 1 ? Self.rowSpacing : 0)
        }
        session.apply(contents, heights: heights, footerHeight: currentFooterHeight(), forceReconfigure: forceReconfigure)
        reconfigureFooterIfNeeded()
    }

    /// Background-renders unmeasured text rows into the cache, then syncs.
    /// A batch already covering these rows is left to finish; one that
    /// doesn't (the window moved on) is cancelled and replaced.
    private func schedulePrecompute(_ texts: [TextRowContent]) {
        let ids = Set(texts.map(\.itemID))
        if precomputeTask != nil {
            if precomputeWidth == width, ids.isSubset(of: precomputeIDs) { return }
            cancelPrecompute()
        }
        precomputeGeneration += 1
        let generation = precomputeGeneration
        precomputeIDs = ids
        precomputeWidth = width
        // The two hosted SwiftUI pieces of a text row are sized here, on main.
        var pills: [String: CGFloat] = [:]
        var sendStates: [String: CGFloat] = [:]
        for text in texts {
            if !text.pills.isEmpty {
                pills[text.itemID] = measurer.pillsHeight(text.pills, isOwn: text.isOwn,
                                                          hasAvatar: text.avatarSender != nil, width: width)
            }
            if text.isOwn, text.sendState != .sent {
                sendStates[text.itemID] = measurer.sendStateHeight(width: width, state: text.sendState)
            }
        }
        let cache = cache, roomID = viewModel.roomID, width = width
        let work = Task.detached(priority: .userInitiated) {
            for text in texts {
                if Task.isCancelled { return }
                let render = MacTimelineMeasurer.measureText(text, width: width, pillsHeight: pills[text.itemID],
                                                             sendStateHeight: sendStates[text.itemID])
                cache.store(.text(render), roomID: roomID, content: .text(text), width: width)
            }
        }
        precomputeTask = Task { [weak self] in
            await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard let self, generation == self.precomputeGeneration else { return }
            self.precomputeTask = nil
            self.precomputeIDs = []
            self.precomputeLanded = true
            self.requestSync()
        }
    }

    private func cancelPrecompute() {
        precomputeTask?.cancel()
        precomputeTask = nil
        precomputeIDs = []
        precomputeGeneration += 1
    }

    /// Row order for the cross-message selection: message ids only, as
    /// `MacTimelineListContent` feeds it. Assigned only on a real change
    /// (its `didSet` may drop a selection whose endpoints left the window).
    private func updateSelectionOrder() {
        let ids = viewModel.windowedRows.compactMap { row -> String? in
            if case .message(let item) = row { return item.id }
            return nil
        }
        if selection.orderedIDs != ids { selection.orderedIDs = ids }
    }

    // MARK: Hosted rows

    /// The SwiftUI a hosted row renders — the same closure the measurer
    /// sizes, so render equals measure.
    func hostedRow(_ content: HostedRowContent) -> AnyView {
        if let override = hostedRowOverrideForTesting?(content) { return override }
        return AnyView(MacTimelineRowView(
            row: content.row,
            subtaskChild: content.subtaskChild,
            viewModel: viewModel,
            onOpenSubChat: { [weak self] id in self?.actions.onOpenSubChat(id) },
            onOpenSpawnRoom: actions.onOpenSpawnRoom.map { _ in { [weak self] id in self?.actions.onOpenSpawnRoom?(id) } },
            onOpenItem: actions.onOpenItem.map { _ in { [weak self] id in self?.actions.onOpenItem?(id) } },
            onOpenMission: actions.onOpenMission.map { _ in { [weak self] id in self?.actions.onOpenMission?(id) } },
            onPreviewImage: { [weak self] url, image in self?.actions.onPreviewImage(url, image) })
            .environment(selection)
            .environment(\.openTrackerItem, currentLinkRouting.openTrackerItem)
            .environment(\.openConversation, currentLinkRouting.openConversation)
            .environment(\.conversationLinkHost, currentLinkRouting.conversationLinkHost))
    }

    /// `actions.linkRouting`, as trampolines reading the CURRENT actions (a
    /// nil route stays nil: the renderer omits what has nowhere to go).
    private var currentLinkRouting: MacTimelineLinkRouting {
        MacTimelineLinkRouting(
            openTrackerItem: actions.linkRouting.openTrackerItem.map { _ in
                { [weak self] number in self?.actions.linkRouting.openTrackerItem?(number) }
            },
            openConversation: actions.linkRouting.openConversation.map { _ in
                { [weak self] id in self?.actions.linkRouting.openConversation?(id) }
            },
            // A reference: the current one is fine to hand over as is.
            conversationLinkHost: actions.linkRouting.conversationLinkHost)
    }

    /// A hosted row's content settled at a height other than measured (an
    /// ask card answered, an image landed): re-measure only that row. The
    /// report arrives a main-queue turn after the cell's layout and may
    /// outlive its reuse — the id is looked up, the cell never trusted.
    private func hostedHeightChanged(_ id: String, to height: CGFloat) {
        guard !isTornDown, case .hosted(let content)? = session.contents[id],
              let current = measurements[id]?.height, abs(current - height) > 0.5,
              let index = session.scrollModel.index(of: id) else { return }
        // Recorded even while suspended: the cell already took this height
        // as its `expectedHeight` and will never report it again, so a
        // dropped report left `resume()`'s sync hitting the OLD cached
        // height. Only the model/table update waits — that sync applies it.
        cache.store(.hosted(height), roomID: viewModel.roomID, content: .hosted(content), width: width)
        measurements[id] = .hosted(height)
        guard !isSuspended else { return }
        let gap = index < session.scrollModel.rows.count - 1 ? Self.rowSpacing : 0
        session.updateHeight(ofRow: id, to: height + gap)
    }

    // MARK: Footer

    private func currentFooterHeight() -> CGFloat {
        guard let label = viewModel.activityLabel else { return 0 }
        if let height = footerHeights[label] { return height }
        footerSizer.rootView = AnyView(ActivityIndicatorRow(label: label).padding(.bottom, 8).frame(width: width))
        let height = footerSizer.fittingSize.height
        footerHeights[label] = height
        return height
    }

    /// The footer's content: the list's bottom padding, then the activity
    /// indicator as `MacChatView` places it (8 pt off the composer).
    private func footerContent(label: String?) -> AnyView {
        AnyView(VStack(spacing: 0) {
            Color.clear.frame(height: Self.metrics.bottomInset)
            if let label { ActivityIndicatorRow(label: label).padding(.bottom, 8) }
        }
        .frame(maxHeight: .infinity, alignment: .top))
    }

    private func configureFooter(_ footer: MacHostedRowView) {
        let label = viewModel.activityLabel
        configuredFooterLabel = .some(label)
        footer.onHeightChange = nil
        footer.configure(rowID: "", expectedHeight: Self.metrics.bottomInset + session.scrollModel.footerHeight,
                         content: footerContent(label: label))
    }

    /// A label change doesn't go through the rows: push it to the footer on
    /// screen, if any.
    private func reconfigureFooterIfNeeded() {
        let footerRow = tableHeights.count - 1
        guard configuredFooterLabel != .some(viewModel.activityLabel), footerRow < tableView.numberOfRows,
              let footer = tableView.view(atColumn: 0, row: footerRow, makeIfNecessary: false)
                as? MacHostedRowView else { return }
        configureFooter(footer)
    }

    // MARK: Row views

    private func configureText(_ view: MacTextRowView, render: MacTextRowRender) {
        let content = render.content
        let retry: (String) -> Void = { [weak viewModel] id in viewModel?.retrySend(itemID: id) }
        let routing = currentLinkRouting
        view.configure(
            render: render, selectionController: selection, linkRouting: routing,
            pills: {
                guard !content.pills.isEmpty else { return nil }
                return AnyView(ConversationLinkPillRow(refs: content.pills, style: content.isOwn ? .me : .bot,
                                                       hasAvatar: content.avatarSender != nil)
                    .environment(\.openConversation, routing.openConversation)
                    .environment(\.conversationLinkHost, routing.conversationLinkHost))
            },
            sendState: {
                // The footer carries its own retry, exactly as
                // `MacTimelineItemView` builds it.
                AnyView(SendStateIndicator(state: SendStateGlyph.from(content.sendState),
                                           onRetry: { retry(content.itemID) })
                    .padding(.horizontal))
            })
    }

    private func configureHosted(_ view: MacHostedRowView, id: String, content: HostedRowContent) {
        view.onHeightChange = { [weak self] rowID, height in self?.hostedHeightChanged(rowID, to: height) }
        // Top-aligned: the row's height includes the gap below the content.
        view.configure(rowID: id, expectedHeight: measurements[id]?.height ?? 0,
                       content: AnyView(hostedRow(content).frame(maxHeight: .infinity, alignment: .top)))
    }

    /// A tabled render must never land in a TextKit 2 view (or back): the
    /// two kinds dequeue from separate identifiers.
    private static func textIdentifier(for render: MacTextRowRender) -> NSUserInterfaceItemIdentifier {
        render.rendered.containsTable ? MacTextRowView.tabledIdentifier : MacTextRowView.identifier
    }

    // MARK: NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { tableHeights.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        #if DEBUG
        delegateDepth += 1
        defer { delegateDepth -= 1 }
        #endif
        return tableHeights.indices.contains(row) ? tableHeights[row] : Self.minimumTableRowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        #if DEBUG
        delegateDepth += 1
        defer { delegateDepth -= 1 }
        #endif
        if row == 0 { return nil }                          // the spacer draws nothing
        if row == tableIDs.count + 1 {
            let footer = tableView.makeView(withIdentifier: Self.footerIdentifier, owner: nil) as? MacHostedRowView
                ?? Self.makeHostedView(identifier: Self.footerIdentifier)
            configureFooter(footer)
            return footer
        }
        guard tableIDs.indices.contains(row - 1) else { return nil }
        let id = tableIDs[row - 1]
        switch session.contents[id] {
        case .text?:
            guard case .text(let render)? = measurements[id] else {
                timelineLogger.breadcrumb("mac timeline text row \(id) has no text measurement")
                assertionFailure("text row \(id) viewed without a .text measurement")
                return nil
            }
            let identifier = Self.textIdentifier(for: render)
            let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? MacTextRowView ?? {
                let view = MacTextRowView(frame: .zero)
                view.identifier = identifier
                return view
            }()
            configureText(view, render: render)
            return view
        case .hosted(let content)?:
            let view = tableView.makeView(withIdentifier: MacHostedRowView.identifier, owner: nil) as? MacHostedRowView
                ?? Self.makeHostedView(identifier: MacHostedRowView.identifier)
            configureHosted(view, id: id, content: content)
            return view
        case nil:
            return nil
        }
    }

    private static func makeHostedView(identifier: NSUserInterfaceItemIdentifier) -> MacHostedRowView {
        let view = MacHostedRowView(frame: .zero)
        view.identifier = identifier
        return view
    }

    // MARK: TimelineSurface

    /// Brings the table to `ids`: removals and insertions in place when the
    /// surviving rows keep their order, `reloadData` otherwise (a reorder,
    /// or most rows changed). Reconfigured rows re-render in place when
    /// visible. Heights are reconciled by `setContentOffset`, which the
    /// session calls right after.
    func applyRows(_ ids: [String], reconfigure: [String], reload: [String]) {
        #if DEBUG
        assertOutsideDelegate("applyRows")
        #endif
        guard isViewLoaded else { return }
        // Row edits can clamp the clip origin: that is this write, not the
        // reader (the session ignores it anyway — it is mid layout update).
        let wasProgrammatic = scrollView.isApplyingProgrammaticScroll
        scrollView.isApplyingProgrammaticScroll = true
        defer { scrollView.isApplyingProgrammaticScroll = wasProgrammatic }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer { NSAnimationContext.endGrouping() }
        let old = tableIDs
        if old != ids {
            let newSet = Set(ids)
            let oldSet = Set(old)
            let survivorsOld = old.filter(newSet.contains)
            let survivorsNew = ids.filter(oldSet.contains)
            let changed = (old.count - survivorsOld.count) + (ids.count - survivorsNew.count)
            if survivorsOld != survivorsNew || changed * 2 > max(old.count, ids.count) {
                tableIDs = ids
                tableHeights = expectedTableHeights()
                tableView.reloadData()
                reloadDataCountForTesting += 1
            } else {
                let model = session.scrollModel
                tableView.beginUpdates()
                let removed = IndexSet(old.indices.filter { !newSet.contains(old[$0]) }.map { $0 + 1 })
                if !removed.isEmpty {
                    for tableRow in removed.reversed() {
                        tableIDs.remove(at: tableRow - 1)
                        tableHeights.remove(at: tableRow)
                    }
                    tableView.removeRows(at: removed, withAnimation: [])
                }
                let inserted = IndexSet(ids.indices.filter { !oldSet.contains(ids[$0]) }.map { $0 + 1 })
                if !inserted.isEmpty {
                    for tableRow in inserted {
                        tableIDs.insert(ids[tableRow - 1], at: tableRow - 1)
                        tableHeights.insert(Self.tableHeight(model.rows[tableRow - 1].height), at: tableRow)
                    }
                    tableView.insertRows(at: inserted, withAnimation: [])
                }
                tableView.endUpdates()
            }
        }
        var reloadRows = IndexSet()
        for id in reload {
            if let index = session.scrollModel.index(of: id) { reloadRows.insert(index + 1) }
        }
        for id in reconfigure {
            reconfiguredRowCountForTesting += 1
            guard let index = session.scrollModel.index(of: id),
                  let view = tableView.view(atColumn: 0, row: index + 1, makeIfNecessary: false) else { continue }
            if let textView = view as? MacTextRowView, case .text(let render)? = measurements[id] {
                // A body that just gained (or lost) a table needs the other
                // kind of view: reload the row rather than flip TextKit.
                if textView.identifier == Self.textIdentifier(for: render) {
                    configureText(textView, render: render)
                } else {
                    reloadRows.insert(index + 1)
                }
            } else if let hostedView = view as? MacHostedRowView, case .hosted(let content)? = session.contents[id] {
                configureHosted(hostedView, id: id, content: content)
            } else {
                reloadRows.insert(index + 1)
            }
        }
        if !reloadRows.isEmpty {
            tableView.reloadData(forRowIndexes: reloadRows, columnIndexes: IndexSet(integer: 0))
        }
    }

    /// The single clip-origin write (`TimelineSession.performLayoutUpdate`
    /// calls it once per model change): bring every table row height to the
    /// model's, then write the model's offset if the clip is more than
    /// 0.25 pt away from it.
    func setContentOffset(_ offsetY: CGFloat) {
        #if DEBUG
        assertOutsideDelegate("setContentOffset")
        #endif
        guard isViewLoaded else { return }
        // Height reconciling (a re-tile) can clamp the origin too.
        let wasProgrammatic = scrollView.isApplyingProgrammaticScroll
        scrollView.isApplyingProgrammaticScroll = true
        defer { scrollView.isApplyingProgrammaticScroll = wasProgrammatic }
        reconcileHeights()
        let clip = scrollView.contentView
        guard abs(clip.bounds.origin.y - offsetY) > 0.25 else { return }
        clip.scroll(to: NSPoint(x: 0, y: offsetY))
        scrollView.reflectScrolledClipView(clip)
    }

    /// A zero-delta origin write ends momentum on macOS 13+ (as in
    /// `NativeScrollViewBox`). Never re-enters the session: the write is
    /// flagged programmatic, so no user-scroll callback fires.
    ///
    /// No `momentumPhase.ended` follows a killed momentum, so the open
    /// gesture is closed here too (silently — the session is about to decide
    /// follow-tail itself): left open, the next non-gesture move at the tail
    /// could not re-arm follow until another wheel gesture came and went.
    func killMomentum() {
        guard isViewLoaded else { return }
        let clip = scrollView.contentView
        scrollView.isApplyingProgrammaticScroll = true
        clip.scroll(to: clip.bounds.origin)
        scrollView.reflectScrolledClipView(clip)
        scrollView.isApplyingProgrammaticScroll = false
        scrollView.cancelGesture()
        isUserGestureActive = false
    }

    var isUserGestureActiveForTesting: Bool { isUserGestureActive }

    /// The blank-chat tripwire's probe: some model row (spacer and footer
    /// excluded) intersects the clip. Off window it never trips.
    func hasVisibleRows() -> Bool {
        guard isViewLoaded, view.window != nil, !tableIDs.isEmpty else { return true }
        let range = tableView.rows(in: scrollView.contentView.bounds)
        let lower = max(range.location, 1)
        let upper = min(range.location + range.length, tableIDs.count + 1)
        return upper > lower
    }

    func flashRow(_ id: String) {
        guard isViewLoaded, let index = session.scrollModel.index(of: id),
              let view = tableView.view(atColumn: 0, row: index + 1, makeIfNecessary: false) else { return }
        if let text = view as? MacTextRowView { text.flash() }
        if let hosted = view as? MacHostedRowView { hosted.flash() }
    }

    func followingChanged(_ following: Bool) {
        bridge.setFollowing(following)
    }

    /// The INVARIANT breadcrumb's real offset (diagnostics only).
    var currentOffsetY: CGFloat? { isViewLoaded ? scrollView.contentView.bounds.origin.y : nil }

    // MARK: Heights

    private static func tableHeight(_ modelHeight: CGFloat) -> CGFloat {
        max(modelHeight, minimumTableRowHeight)
    }

    /// Every table row's height as the model has it now.
    private func expectedTableHeights() -> [CGFloat] {
        let model = session.scrollModel
        var heights: [CGFloat] = []
        heights.reserveCapacity(model.rows.count + 2)
        heights.append(model.alignmentPad + Self.metrics.topInset)
        for row in model.rows { heights.append(Self.tableHeight(row.height)) }
        heights.append(Self.metrics.bottomInset + model.footerHeight)
        return heights
    }

    /// `noteHeightOfRows` for exactly the table rows whose height differs
    /// from the model's (spacer, footer, reconfigured rows, the row a new
    /// tail folded a gap into, a hosted report…), then re-tile so the
    /// document is the model's height before the origin is written.
    private func reconcileHeights() {
        #if DEBUG
        assertOutsideDelegate("reconcileHeights")
        #endif
        let expected = expectedTableHeights()
        guard expected.count == tableHeights.count else {
            timelineLogger.breadcrumb("mac timeline table rows \(tableHeights.count) ≠ model \(expected.count) → reload")
            assertionFailure("table rows out of step with the model")
            tableIDs = session.scrollModel.rows.map(\.id)
            tableHeights = expected
            tableView.reloadData()
            reloadDataCountForTesting += 1
            return
        }
        var changed = IndexSet()
        for index in expected.indices where expected[index] != tableHeights[index] { changed.insert(index) }
        if !changed.isEmpty {
            tableHeights = expected
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: changed)
            NSAnimationContext.endGrouping()
        }
        let documentHeight = expected.reduce(0, +)
        if abs(tableView.frame.height - max(documentHeight, scrollView.contentView.bounds.height)) > 0.25 {
            tableView.tile()
        }
    }
}

/// The table: reports the end of a window live resize (the full resync).
private final class TimelineTableView: NSTableView {
    var onEndLiveResize: (() -> Void)?

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }
}

/// Runs `action` once on the next display frame however often it was
/// requested since — the Mac twin of iOS `FrameCoalescer`, on
/// `NSView.displayLink`. Paused whenever idle; `invalidate()` is final.
///
/// An occluded window (behind others, on a locked or sleeping display, a
/// test host's window) gets no display-link ticks at all, so every request
/// also arms a one-shot fallback timer: whichever fires first runs the
/// action and disarms the other. On screen the link always wins.
@MainActor
final class MacFrameCoalescer {
    /// Longer than any real frame (≤ 16.7 ms), short enough that an
    /// occluded timeline still settles promptly.
    static let fallbackDelay: TimeInterval = 0.05

    /// The display link's and timer's target: holds its owner weakly (the
    /// link retains the target, never the owner) and invalidates the link
    /// itself if it ever ticks after the owner is gone.
    private final class Target: NSObject {
        weak var owner: MacFrameCoalescer?
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated {
                guard let owner else {
                    link.invalidate()
                    return
                }
                #if DEBUG
                MacFrameCoalescer.noteFirstFire(viaDisplayLink: true)
                #endif
                owner.fire()
            }
        }
        @objc func fallback(_ timer: Timer) {
            MainActor.assumeIsolated {
                // A timer outliving its coalescer is no fire: no breadcrumb.
                guard let owner else { return }
                #if DEBUG
                MacFrameCoalescer.noteFirstFire(viaDisplayLink: false)
                #endif
                owner.fire()
            }
        }
    }

    #if DEBUG
    /// One breadcrumb per process for each path, so a rig `app.log` shows
    /// whether the display link ever ticked or only the fallback timer ran.
    private static var loggedLinkTick = false
    private static var loggedFallback = false
    fileprivate static func noteFirstFire(viaDisplayLink: Bool) {
        if viaDisplayLink, !loggedLinkTick {
            loggedLinkTick = true
            timelineLogger.breadcrumb("mac timeline coalescer: display link ticked")
        } else if !viaDisplayLink, !loggedFallback {
            loggedFallback = true
            timelineLogger.breadcrumb("mac timeline coalescer: fallback timer fired")
        }
    }
    #endif

    /// `nonisolated(unsafe)` only so the nonisolated `deinit` can read them;
    /// every other access is on the main actor.
    nonisolated(unsafe) private var link: CADisplayLink?
    nonisolated(unsafe) private var fallbackTimer: Timer?
    private let target = Target()
    private weak var view: NSView?
    private let action: () -> Void
    private var isInvalidated = false

    init(view: NSView, action: @escaping () -> Void) {
        self.view = view
        self.action = action
        target.owner = self
    }

    deinit {
        let link = link, timer = fallbackTimer
        guard link != nil || timer != nil else { return }
        if Thread.isMainThread {
            link?.invalidate()
            timer?.invalidate()
        } else {
            nonisolated(unsafe) let orphanLink = link
            nonisolated(unsafe) let orphanTimer = timer
            DispatchQueue.main.async {
                orphanLink?.invalidate()
                orphanTimer?.invalidate()
            }
        }
    }

    var isPending: Bool { fallbackTimer != nil }

    func request() {
        guard !isInvalidated, fallbackTimer == nil else { return }
        if link == nil, let view {
            let link = view.displayLink(target: target, selector: #selector(Target.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
        let timer = Timer(timeInterval: Self.fallbackDelay, target: target,
                          selector: #selector(Target.fallback(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    func invalidate() {
        isInvalidated = true
        link?.invalidate()
        link = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    fileprivate func fire() {
        // A tick with nothing requested (the link was unpaused and paused
        // again in between) does nothing.
        guard let timer = fallbackTimer else {
            link?.isPaused = true
            return
        }
        timer.invalidate()
        fallbackTimer = nil
        link?.isPaused = true
        action()
    }
}
