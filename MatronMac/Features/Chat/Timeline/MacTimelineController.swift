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
///
/// Load-bearing since perf follow-ups R1: `HostedRowRoot`'s `==` compares
/// only content, width and source, so a mounted hosted row skips any write
/// that would carry new actions. Callbacks reach the new ones through the
/// trampolines, but what `hostedRowBody` reads when the root renders —
/// which optional routes are nil, and the `conversationLinkHost` reference
/// — stays as the row was rendered until its content or width changes.
/// Changing those per screen would need them in the root's equality.
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
    /// What each entry of `measurements` measured: the content, at a width.
    /// Perf follow-ups S6: an equal content at an equal width reuses the
    /// measurement without asking the `NSCache`, which memory pressure can
    /// empty (P0 saw every row re-measured on every pass).
    private var measuredFor: [String: MeasuredFor] = [:]
    private struct MeasuredFor: Equatable {
        let content: TimelineRowContent
        let width: CGFloat
    }
    /// The last build, by anchor id: an equal `TimelineRow` (with the same
    /// senders flag and children) reuses its content (perf follow-ups S6).
    private var lastBuilt: [String: (row: TimelineRow, content: TimelineRowContent)] = [:]
    private var lastBuildHasMultipleSenders: Bool?
    private var lastBuildChildren: [SubChatSummary] = []
    /// The activity label the last applied pass sized the footer for.
    private var appliedFooterLabel: String??
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

    /// Perf follow-ups O1 (a): the main-thread time one pass may spend on
    /// hosted rows the reader can't see yet (rows prepended above the
    /// viewport, a cold open's rows above its first screen). The rest wait
    /// for the next frame's pass; the window applies once all are measured.
    static let hostedSliceBudget: CFTimeInterval = 0.004
    /// A cold open's slice budget (the model is empty). No row is on screen,
    /// so no row frame can hitch: a pass measures hosted rows until it has
    /// spent this long, rather than stopping before a row that might
    /// overrun, and a frame still keeps a few ms for the loading spinner.
    static let coldOpenSliceBudget: CFTimeInterval = 0.012
    /// The time source for the slice budget and the prepared-content window
    /// (test seam: a fake clock makes both deterministic).
    var clock: () -> CFTimeInterval = CACurrentMediaTime {
        didSet { (tableView as? TimelineTableView)?.clock = clock }
    }
    /// O1 (b): how long after an open or jump apply (a reload) the table prepares
    /// only what is on screen.
    static let preparedContentRestriction: CFTimeInterval = 0.3
    /// O1 (a): rows measured but not applied yet (hosted slices, and rows
    /// above a cold open's first apply), with what they measured.
    private var pendingMeasured: [String: (key: MeasuredFor, measurement: MacRowMeasurement)] = [:]
    /// O1 (a): hosted rows of the current window still wait for a slice:
    /// the window is not applied (or only a cold open's on-screen part is).
    private var hostedDeferred = false
    /// Hosted measuring time (by `clock`) of the pass in progress.
    private var passHostedMeasureTime: CFTimeInterval = 0
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
        precomputeTask != nil || hostedDeferred || (coalescer?.isPending ?? syncRequestedBeforeLoad)
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

    /// The rows the last `applyRows` reconfigured or reloaded (perf
    /// follow-ups D0): the slow-sync breadcrumb names them.
    private var lastApplyChangedIDs: [String] = []
    var lastApplyChangedIDsForTesting: [String] { lastApplyChangedIDs }

    /// Perf follow-ups S5: the measurer's live streaming sizers.
    var streamingSizerIDsForTesting: Set<String> { measurer.streamingSizerIDsForTesting }
    func streamingSizerForTesting(_ id: String) -> MarkdownAttributed.StreamingSizer? {
        measurer.streamingSizerForTesting(id)
    }

    /// `"id[text]"` / `"id[hosted]"`, comma-joined, at most `cap` of them.
    private func describeChanged(_ ids: [String], cap: Int = 8) -> String {
        let named = ids.prefix(cap).map { id -> String in
            switch session.contents[id] {
            case .text?: return "\(id)[text]"
            case .hosted?: return "\(id)[hosted]"
            case nil: return "\(id)[?]"
            }
        }
        return named.joined(separator: ",") + (ids.count > cap ? ",+\(ids.count - cap)" : "")
    }

    /// One breadcrumb for a `sync` pass over a frame's budget (D0 (a)).
    private func logSlowSync(since start: CFTimeInterval, rowsBuilt: Int, textMeasured: Int,
                             hostedMeasured: Int, reloadedData: Bool,
                             missReasons: [String: Int], firstMisses: [String], resizePass: Bool) {
        let ms = (CACurrentMediaTime() - start) * 1000
        guard ms > 16 else { return }
        timelineLogger.breadcrumb("mac timeline slow sync \(Int(ms.rounded())) ms width=\(width) resizePass=\(resizePass) rows=\(rowsBuilt) textMeasuredOnMain=\(textMeasured) hostedMeasuredOnMain=\(hostedMeasured) changed=\(lastApplyChangedIDs.count) ids=\(describeChanged(lastApplyChangedIDs)) reloadData=\(reloadedData ? "yes" : "no") cacheMisses=\(missReasons.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")) firstMisses=\(firstMisses.joined(separator: ","))")
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
    /// Hosted rows measured (always on main) by `sync()`.
    private(set) var hostedMeasuredRowCountForTesting = 0
    /// Passes that reached `session.apply`.
    private(set) var applyCountForTesting = 0
    #if DEBUG
    /// Per pass that measured any hosted row: the `clock` time it spent on
    /// them (DEBUG only: it grows with every such pass).
    private(set) var hostedMeasureTimePerPassForTesting: [CFTimeInterval] = []
    #endif
    /// Called after every apply and its position rules.
    var onApplyForTesting: (() -> Void)?
    /// While true, O1 (a) slices measure nothing: the deferred hosted rows
    /// stay pending, so a test can act mid-slicing deterministically.
    var holdsHostedSlicesForTesting = false
    /// Hosted rows wait for slices and no text batch is in flight.
    var isSlicingHostedRowsForTesting: Bool { hostedDeferred && precomputeTask == nil }
    func resetCountersForTesting() {
        reconfiguredRowCountForTesting = 0
        reloadDataCountForTesting = 0
        syncMeasuredRowCountForTesting = 0
        hostedMeasuredRowCountForTesting = 0
        applyCountForTesting = 0
        #if DEBUG
        hostedMeasureTimePerPassForTesting = []
        #endif
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

    /// Swaps the actions without re-rendering any row. Relies on them being
    /// fixed per screen: see `MacTimelineActions` — mounted hosted rows skip
    /// identical writes (`HostedRowRoot`), so a change in which routes exist
    /// would not reach them.
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
        hostedDeferred = false
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
        tableView.clock = clock
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
    /// to the precompute and, for hosted rows off screen, to later frames'
    /// slices), apply, then the post-apply position rules.
    func sync() {
        #if DEBUG
        assertOutsideDelegate("sync")
        #endif
        guard !isTornDown, !isSuspended else { return }
        passHostedMeasureTime = 0
        #if DEBUG
        defer {
            if passHostedMeasureTime > 0 { hostedMeasureTimePerPassForTesting.append(passHostedMeasureTime) }
        }
        let syncStart = CACurrentMediaTime()
        let textMeasuredBefore = syncMeasuredRowCountForTesting
        let hostedMeasuredBefore = hostedMeasuredRowCountForTesting
        let reloadsBefore = reloadDataCountForTesting
        var rowsBuilt = 0
        var missReasons: [String: Int] = [:]
        var firstMisses: [String] = []
        var resizePass = false
        lastApplyChangedIDs = []
        defer {
            logSlowSync(since: syncStart, rowsBuilt: rowsBuilt,
                        textMeasured: syncMeasuredRowCountForTesting - textMeasuredBefore,
                        hostedMeasured: hostedMeasuredRowCountForTesting - hostedMeasuredBefore,
                        reloadedData: reloadDataCountForTesting != reloadsBefore,
                        missReasons: missReasons, firstMisses: firstMisses, resizePass: resizePass)
        }
        #endif
        observeViewModel()
        updateSelectionOrder()
        guard width > 0 else { return }
        let built = buildContents()
        let contents = built.contents
        #if DEBUG
        rowsBuilt = contents.count
        #endif
        // Perf follow-ups S5: a sizer lives only while its row streams.
        measurer.keepStreamingSizers(for: Set(contents.compactMap { content -> String? in
            guard case .text(let text) = content, text.isStreaming else { return nil }
            return text.itemID
        }))
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
        #if DEBUG
        resizePass = isLiveResizePass
        #endif
        // Perf follow-ups O1 (a): outside a forced or resize pass, a hosted
        // row the reader can't see yet may wait for a later frame's slice.
        let canDefer = !forceSynchronousMeasure && !isLiveResizePass
        var next: [String: MacRowMeasurement] = [:]
        next.reserveCapacity(contents.count)
        var nextFor: [String: MeasuredFor] = [:]
        nextFor.reserveCapacity(contents.count)
        var missing: [TextRowContent] = []
        var background: [TextRowContent] = []
        /// Unmeasured hosted rows (indices into `contents`) left for O1 (a).
        var hostedMissing: [Int] = []
        for (index, content) in contents.enumerated() {
            let id = content.anchorID
            let key = MeasuredFor(content: content, width: width)
            if measuredFor[id] == key, let kept = measurements[id] {
                next[id] = kept
                nextFor[id] = key
                continue
            }
            if let pending = pendingMeasured[id], pending.key == key {
                next[id] = pending.measurement
                nextFor[id] = key
                continue
            }
            if let hit = cache.measurement(roomID: viewModel.roomID, content: content, width: width) {
                next[id] = hit
                nextFor[id] = key
                continue
            }
            #if DEBUG
            // The reason costs a second key build, lookup and field diff:
            // only the first three misses pay it, so a pass where every row
            // misses (cache purged) is not doubled by its own diagnostic.
            if firstMisses.count < 3 {
                let reason = cache.missReason(roomID: viewModel.roomID, content: content, width: width)
                missReasons[reason, default: 0] += 1
                firstMisses.append("\(id):\(reason)")
            } else {
                missReasons["other", default: 0] += 1
            }
            #endif
            if isLiveResizePass, !onScreen.contains(id), session.contents[id] == content, let stale = measurements[id] {
                if case .text(let text) = content {
                    next[id] = stale
                    nextFor[id] = measuredFor[id]
                    background.append(text)
                    continue
                }
                if isLiveResize {
                    next[id] = stale
                    nextFor[id] = measuredFor[id]
                    continue
                }
            }
            switch content {
            case .text(let text):
                missing.append(text)
            case .hosted(let hosted):
                if canDefer {
                    hostedMissing.append(index)
                } else {
                    // Hosted rows are SwiftUI: always measured on main.
                    next[id] = measureHosted(hosted)
                    nextFor[id] = key
                }
            }
        }

        // O1 (a): the unmeasured hosted rows the reader can't see yet wait;
        // the rest (on screen, below it, or changed in place) measure now.
        var deferred: [Int] = []
        /// Rows above this index that are new to the table may wait.
        var bound = 0
        if !hostedMissing.isEmpty {
            bound = deferrableBound(contents)
            for index in hostedMissing {
                let content = contents[index]
                if index < bound, session.contents[content.anchorID] == nil {
                    deferred.append(index)
                } else if case .hosted(let hosted) = content {
                    next[content.anchorID] = measureHosted(hosted)
                    nextFor[content.anchorID] = MeasuredFor(content: content, width: width)
                }
            }
        }

        // O1 (a), cold open: nothing on screen yet and hosted rows to
        // measure. Every one goes through the slices (the anchor's part of
        // the window first) and the text rows through the precompute; the
        // loading state holds until the part from the anchor down plus a
        // screen above it is measured, which applies first.
        if canDefer, session.scrollModel.rows.isEmpty, !deferred.isEmpty {
            if coldOpenPass(contents, deferred: deferred, missing: missing, next: &next, nextFor: &nextFor) { return }
            // Everything is measured: the whole window applies below.
            deferred = []
            missing = []
        }
        if !deferred.isEmpty {
            // Nearest the reader (the model's first visible row) first.
            deferred = measureHostedSlice(deferred.sorted(by: >), contents, budget: .rowsOnScreen,
                                          next: &next, nextFor: &nextFor)
        }
        hostedDeferred = !deferred.isEmpty
        if hostedDeferred { requestSync() }

        // Perf follow-ups S6: nothing to show that isn't on screen already
        // (an observed property set to an equal value, the open's second
        // identical pass): no apply. The position rules still run, as after
        // any pass — a restore, focus or edge trigger waiting on one.
        if !hostedDeferred, missing.isEmpty, background.isEmpty, !forceSynchronousMeasure, !precomputeLanded,
           !isLiveResizePass, isApplied(contents, measured: next) {
            #if DEBUG
            // Skipping keeps `measurements` / `measuredFor` as the last apply
            // left them: they must hold what `isApplied` just matched — the
            // same rows, contents and heights. (Not the widths: a row kept at
            // another width's measurement, or re-hit in the cache at this
            // one with the same height, is applied as is.)
            assert(Self.sameAppliedState(next: next, nextFor: nextFor, measurements: measurements,
                                         measuredFor: measuredFor),
                   "a skipped pass measured something other than what is applied")
            #endif
            session.afterApply()
            return
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
                nextFor[text.itemID] = MeasuredFor(content: content, width: width)
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
        // O1 (a): the whole window applies once its last deferred hosted
        // row is measured — a later frame's pass (already requested). Until
        // then, anything else the pass brings (a tail append, the reader's
        // own send, a stream commit, a row changed in place) applies
        // without the new rows still waiting above the reader. A landed
        // batch stays landed until the whole window applies.
        if hostedDeferred {
            applyWithoutPendingTop(contents, bound: bound, missing: missing, next: next, nextFor: nextFor)
            return
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
            nextFor[text.itemID] = MeasuredFor(content: content, width: width)
        }
        measuredFor = nextFor
        // Every row of the window is applied: nothing is left pending.
        pendingMeasured = [:]
        apply(contents, measured: next, forceReconfigure: forceSynchronousMeasure || isLiveResizePass)
        session.afterApply()
        onApplyForTesting?()
        #if DEBUG
        MacTimelinePerfProbe.shared.noteRowsPresented(roomID: viewModel.roomID, count: contents.count)
        #endif
        if background.isEmpty {
            isWidthCatchingUp = false
        } else {
            schedulePrecompute(background)
        }
    }

    // MARK: Open and extend smoothing (perf follow-ups O1 (a))

    /// One hosted row measured on main now, stored in the cache and timed
    /// against the pass's hosted budget.
    private func measureHosted(_ hosted: HostedRowContent) -> MacRowMeasurement {
        let started = clock()
        let content = TimelineRowContent.hosted(hosted)
        let measured = MacRowMeasurement.hosted(measurer.hostedHeight(hosted, width: width))
        cache.store(measured, roomID: viewModel.roomID, content: content, width: width)
        hostedMeasuredRowCountForTesting += 1
        passHostedMeasureTime += clock() - started
        return measured
    }

    /// Rows of `contents` above this index that are NEW to the table sit
    /// above everything the reader sees: the model's first visible row
    /// survives below them and every apply keeps it in place (pinned to the
    /// bottom, or by the top anchor). Nothing applied yet: every row. The
    /// first visible row gone (a far jump replacing the window): none.
    private func deferrableBound(_ contents: [TimelineRowContent]) -> Int {
        let model = session.scrollModel
        guard !model.rows.isEmpty else { return contents.count }
        guard let firstVisible = model.visibleRowIDs.first else { return 0 }
        return contents.firstIndex { $0.anchorID == firstVisible } ?? 0
    }

    /// How much of a frame one slice may take.
    private enum SliceBudget {
        /// Rows are on screen: `hostedSliceBudget`, and the next row is
        /// measured only while the time spent plus the slowest row so far
        /// still fits.
        case rowsOnScreen
        /// Nothing on screen yet: rows are measured until the time spent
        /// reaches `coldOpenSliceBudget` (the last one may overrun it).
        case coldOpen
        /// Every row given (a cold open's changed rows, once they are all
        /// its first apply waits on).
        case unbounded
    }

    /// Measures deferred hosted rows (indices into `contents`) in the order
    /// given, within `budget` (at least one row per slice, so a row slower
    /// than the budget still lands). Returns the rows left for the next
    /// frame, in order.
    private func measureHostedSlice(_ order: [Int], _ contents: [TimelineRowContent], budget: SliceBudget,
                                    next: inout [String: MacRowMeasurement],
                                    nextFor: inout [String: MeasuredFor]) -> [Int] {
        guard !holdsHostedSlicesForTesting else { return order }
        var spent: CFTimeInterval = 0
        var slowest: CFTimeInterval = 0
        for (position, index) in order.enumerated() {
            let full = switch budget {
            case .rowsOnScreen: spent + slowest > Self.hostedSliceBudget
            case .coldOpen: spent >= Self.coldOpenSliceBudget
            case .unbounded: false
            }
            if position > 0, full {
                return Array(order[position...])
            }
            guard case .hosted(let hosted) = contents[index] else { continue }
            let started = clock()
            let measured = measureHosted(hosted)
            let cost = clock() - started
            spent += cost
            slowest = max(slowest, cost)
            let id = contents[index].anchorID
            let key = MeasuredFor(content: contents[index], width: width)
            pendingMeasured[id] = (key, measured)
            next[id] = measured
            nextFor[id] = key
        }
        return []
    }

    /// One pass of a cold open with hosted rows to measure (perf follow-ups
    /// O1 (a)). Nothing is measured on main beyond the cold slice budget
    /// (`coldOpenSliceBudget`, plus the changed rows of the pass that
    /// applies) and the synchronous text limit: hosted rows go through
    /// `measureHostedSlice`,
    /// the anchor's part of the window first (the anchor down, then up from
    /// it), and text rows through the precompute, as a cold open always
    /// did. Until the anchor's part is measured nothing applies (the loading
    /// state: `hasPendingWork` is true). Then that part applies alone if
    /// rows above it still wait, and they prepend as the slices finish.
    /// Returns false when the whole window is measured: the caller applies
    /// it as usual, from `next`.
    private func coldOpenPass(_ contents: [TimelineRowContent], deferred: [Int], missing: [TextRowContent],
                              next: inout [String: MacRowMeasurement],
                              nextFor: inout [String: MeasuredFor]) -> Bool {
        var textPending = false
        if missing.count > Self.synchronousMeasureLimit, !(precomputeLanded && precomputeRetried) {
            if precomputeLanded {
                // Landed short (the window grew while it ran): one retry,
                // which is then measured on main whatever it lands with.
                precomputeLanded = false
                precomputeRetried = true
            }
            schedulePrecompute(missing)
            textPending = true
        } else if !missing.isEmpty, precomputeCovers(missing) {
            // The batch stores rows as it renders them: a pass near its end
            // sees only a few missing. They are the batch's, never main's.
            textPending = true
        } else {
            syncMeasuredRowCountForTesting += missing.count
            for text in missing {
                let content = TimelineRowContent.text(text)
                let measured = measurer.measure(content, width: width)
                cache.store(measured, roomID: viewModel.roomID, content: content, width: width)
                let key = MeasuredFor(content: content, width: width)
                pendingMeasured[text.itemID] = (key, measured)
                next[text.itemID] = measured
                nextFor[text.itemID] = key
            }
        }
        let anchor = coldOpenAnchor(contents)
        let byAnchor = deferred.filter { $0 >= anchor }.sorted() + deferred.filter { $0 < anchor }.sorted(by: >)
        // A row measured by an earlier pass whose content changed since (a
        // card still streaming) goes after every row never measured: it may
        // change on every pass, and measured first it would take each
        // slice from the rows above.
        let isChanged = { (index: Int) in self.pendingMeasured[contents[index].anchorID] != nil }
        var left = measureHostedSlice(byAnchor.filter { !isChanged($0) } + byAnchor.filter(isChanged), contents,
                                      budget: .coldOpen, next: &next, nextFor: &nextFor)
        // ...but the first apply never waits on one: once the rest of its
        // part is measured (with their last measurements standing in),
        // the changed rows in it are measured now, past the budget.
        if !textPending, !left.isEmpty {
            var standIn = next
            for index in left {
                let id = contents[index].anchorID
                if let pending = pendingMeasured[id] { standIn[id] = pending.measurement }
            }
            if let start = coldOpenSuffixStart(contents, anchor: anchor, measured: standIn) {
                let now = left.filter { $0 >= start && isChanged($0) }
                let unmeasured = Set(measureHostedSlice(now, contents, budget: .unbounded, next: &next, nextFor: &nextFor))
                left.removeAll { now.contains($0) && !unmeasured.contains($0) }
            }
        }
        hostedDeferred = !left.isEmpty
        if hostedDeferred { requestSync() }
        if textPending { return true }
        guard hostedDeferred else { return false }
        if let start = coldOpenSuffixStart(contents, anchor: anchor, measured: next), start > 0 {
            applyColdOpenSuffix(contents, from: start, next: next, nextFor: nextFor, waiting: left.count)
        }
        return true
    }

    /// The row a cold open lands on: a pending jump's target, else a pending
    /// restore's row (`ChatScrollPositionMemory`, as the session read it at
    /// mount), else the tail.
    private func coldOpenAnchor(_ contents: [TimelineRowContent]) -> Int {
        let indexOf = { (id: String) in contents.firstIndex { $0.anchorID == id } }
        if let focus = viewModel.pendingFocusID, let index = indexOf(focus) { return index }
        if session.hasPendingRestore,
           let id = ChatScrollPositionMemory.retrievePosition(roomID: viewModel.roomID)?.itemID,
           let index = indexOf(id) {
            return index
        }
        return contents.count - 1
    }

    /// Where a cold open's first apply starts, from what is measured (never
    /// measures): every row from the anchor down to the end, and rows above
    /// it until the part from the suffix's top padding down to the anchor's
    /// bottom fills a viewport (a row's gap included; one gap over, never
    /// under), plus up to `onScreenMarginRows` more that are measured
    /// already. Nil while any of the required rows is unmeasured, or the
    /// viewport has no height yet.
    ///
    /// The suffix ends at the window's tail, so it has the window's
    /// `windowContainsTail`; it covers the viewport, so it has no bottom-hug
    /// pad, and a restore, jump or pinned tail lands exactly where it does
    /// in the whole window (the rows below the anchor are the same).
    ///
    /// It runs to the tail, not a screen below the anchor: a part ending
    /// above the tail would claim the VM's `windowContainsTail` (so a reader
    /// settling at its bottom, or their own send, would follow a tail that
    /// isn't there), and the passes after it would measure every hosted row
    /// below it on main (only rows above the reader wait for slices).
    private func coldOpenSuffixStart(_ contents: [TimelineRowContent], anchor: Int,
                                     measured: [String: MacRowMeasurement]) -> Int? {
        let viewport = session.scrollModel.viewportHeight
        guard viewport > 0, contents.indices.contains(anchor),
              contents[anchor...].allSatisfy({ measured[$0.anchorID] != nil }) else { return nil }
        var start = anchor
        var aboveAnchorBottom = Self.metrics.topInset + (measured[contents[anchor].anchorID]?.height ?? 0) + Self.rowSpacing
        while start > 0, aboveAnchorBottom < viewport + Self.rowSpacing {
            guard let height = measured[contents[start - 1].anchorID]?.height else { return nil }
            start -= 1
            aboveAnchorBottom += height + Self.rowSpacing
        }
        var margin = Self.onScreenMarginRows
        while margin > 0, start > 0, measured[contents[start - 1].anchorID] != nil {
            start -= 1
            margin -= 1
        }
        return start
    }

    /// Applies a cold open's suffix `contents[start...]` (all measured). The
    /// rows above wait: the measured ones in `pendingMeasured`, the hosted
    /// ones still unmeasured in the slices. `hasPendingWork` stays true
    /// until the whole window applies, so no edge trigger fires off the
    /// suffix.
    private func applyColdOpenSuffix(_ contents: [TimelineRowContent], from start: Int,
                                     next: [String: MacRowMeasurement], nextFor: [String: MeasuredFor],
                                     waiting: Int) {
        let suffix = Array(contents[start...])
        for content in contents[..<start] {
            let id = content.anchorID
            if let measured = next[id], let key = nextFor[id] { pendingMeasured[id] = (key, measured) }
        }
        var applied: [String: MacRowMeasurement] = [:]
        var appliedFor: [String: MeasuredFor] = [:]
        for content in suffix {
            let id = content.anchorID
            applied[id] = next[id]
            appliedFor[id] = nextFor[id]
        }
        // This pass consumed any landed batch: every text row is measured.
        precomputeLanded = false
        precomputeRetried = false
        timelineLogger.diag("mac timeline cold open: \(suffix.count) of \(contents.count) rows first, \(waiting) hosted still in slices")
        measuredFor = appliedFor
        apply(suffix, measured: applied, forceReconfigure: false)
        session.afterApply()
        onApplyForTesting?()
        #if DEBUG
        MacTimelinePerfProbe.shared.noteRowsPresented(roomID: viewModel.roomID, count: suffix.count)
        #endif
    }

    /// While an extension's hosted rows wait for slices: applies `contents`
    /// without the rows above `bound` (the model's first visible row) that
    /// are new to the table — the region still being measured — if that
    /// changes anything. The result ends at the window's tail (its
    /// `windowContainsTail` is true to the window) and keeps every row the
    /// reader can see, so the apply keeps them in place, or pins the tail
    /// when following; the tail rules (`handleTailChange`) run after it.
    /// `hostedDeferred` stays true, so paging still waits for the whole
    /// window. Measured rows of the waiting region keep their measurement
    /// in `pendingMeasured`; the few unmeasured text rows outside it (at
    /// most the synchronous limit) are measured here.
    private func applyWithoutPendingTop(_ contents: [TimelineRowContent], bound: Int, missing: [TextRowContent],
                                        next: [String: MacRowMeasurement], nextFor: [String: MeasuredFor]) {
        var next = next
        var nextFor = nextFor
        let waiting = Set(contents[..<bound].lazy.map(\.anchorID).filter { self.session.contents[$0] == nil })
        let shown = contents.filter { !waiting.contains($0.anchorID) }
        let now = missing.filter { !waiting.contains($0.itemID) }
        syncMeasuredRowCountForTesting += now.count
        for text in now {
            let content = TimelineRowContent.text(text)
            let measured = measurer.measure(content, width: width)
            cache.store(measured, roomID: viewModel.roomID, content: content, width: width)
            next[text.itemID] = measured
            nextFor[text.itemID] = MeasuredFor(content: content, width: width)
        }
        for id in waiting {
            if let measured = next[id], let key = nextFor[id] { pendingMeasured[id] = (key, measured) }
        }
        guard !isApplied(shown, measured: next) else { return }
        var applied: [String: MacRowMeasurement] = [:]
        var appliedFor: [String: MeasuredFor] = [:]
        for content in shown {
            let id = content.anchorID
            applied[id] = next[id]
            appliedFor[id] = nextFor[id]
        }
        measuredFor = appliedFor
        apply(shown, measured: applied, forceReconfigure: false)
        session.afterApply()
        onApplyForTesting?()
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

    /// `TimelineRowContentBuilder.build` over the window, reusing the last
    /// build's content for every row whose `TimelineRow` is unchanged (perf
    /// follow-ups S6): a row's content depends only on the row, the senders
    /// flag, the sub-chat children and — for an image — its pixel size, so
    /// only the rest go through the builder (no body hashing for links, no
    /// subtask scan). The result equals a full build.
    private func buildContents() -> BuiltRows {
        let rows = viewModel.windowedRows
        let hasMultipleSenders = viewModel.hasMultipleSenders
        let children = stripViewModel.children
        let imagePixelSize: (URL) -> CGSize? = { [viewModel] url in viewModel.imagePixelSize(for: url) }
        let reusable = hasMultipleSenders == lastBuildHasMultipleSenders && children == lastBuildChildren
        var seen = Set<String>()
        seen.reserveCapacity(rows.count)
        var dropped: [String] = []
        // Each kept row with its reused content, or nil for the builder.
        var slots: [(row: TimelineRow, reused: TimelineRowContent?)] = []
        slots.reserveCapacity(rows.count)
        var fresh: [TimelineRow] = []
        for row in rows {
            let id = TimelineRowContentBuilder.anchorID(for: row)
            guard seen.insert(id).inserted else {
                dropped.append(id)
                continue
            }
            if reusable, let last = lastBuilt[id], last.row == row,
               Self.imagePixelSizeUnchanged(last.content, imagePixelSize) {
                slots.append((row, last.content))
            } else {
                slots.append((row, nil))
                fresh.append(row)
            }
        }
        // Ids are unique already, so the builder drops none: its contents
        // pair with the nil slots in order.
        var built = TimelineRowContentBuilder.build(TimelineRowSource(
            rows: fresh, hasMultipleSenders: hasMultipleSenders, children: children,
            imagePixelSize: imagePixelSize)).contents.makeIterator()
        var contents: [TimelineRowContent] = []
        contents.reserveCapacity(slots.count)
        var nextBuilt: [String: (row: TimelineRow, content: TimelineRowContent)] = [:]
        nextBuilt.reserveCapacity(slots.count)
        for slot in slots {
            guard let content = slot.reused ?? built.next() else {
                assertionFailure("the builder returned fewer contents than rows")
                break
            }
            contents.append(content)
            nextBuilt[content.anchorID] = (slot.row, content)
        }
        lastBuilt = nextBuilt
        lastBuildHasMultipleSenders = hasMultipleSenders
        lastBuildChildren = children
        return BuiltRows(contents: contents, droppedDuplicates: dropped)
    }

    /// An image row's content carries the view model's pixel size, which
    /// can land with the row unchanged; every other content carries none.
    private static func imagePixelSizeUnchanged(_ content: TimelineRowContent,
                                                _ imagePixelSize: (URL) -> CGSize?) -> Bool {
        guard case .hosted(let hosted) = content, case .message(let item) = hosted.row,
              case .image(let url?, _, _, _) = item.kind else { return true }
        return hosted.imagePixelSize == imagePixelSize(url)
    }

    /// Whether applying `contents` with `measured` would change nothing: the
    /// session holds exactly these contents in this order at these heights,
    /// the footer is sized for the current label, and the model's
    /// `windowContainsTail` (written by an apply) is current.
    private func isApplied(_ contents: [TimelineRowContent], measured: [String: MacRowMeasurement]) -> Bool {
        let model = session.scrollModel
        guard model.rows.count == contents.count, appliedFooterLabel == .some(viewModel.activityLabel),
              model.windowContainsTail == viewModel.windowContainsTail else { return false }
        for (index, content) in contents.enumerated() {
            let id = content.anchorID
            guard model.rows[index].id == id, let height = measured[id]?.height,
                  model.rows[index].height == height + (index < contents.count - 1 ? Self.rowSpacing : 0),
                  session.contents[id] == content else { return false }
        }
        return true
    }

    #if DEBUG
    /// What `isApplied` compares, for the skip branch's assert: the same
    /// rows, each with the same content and height (widths aside).
    private static func sameAppliedState(next: [String: MacRowMeasurement], nextFor: [String: MeasuredFor],
                                         measurements: [String: MacRowMeasurement],
                                         measuredFor: [String: MeasuredFor]) -> Bool {
        guard next.count == measurements.count, nextFor.count == measuredFor.count else { return false }
        for (id, measured) in next {
            guard measurements[id]?.height == measured.height,
                  measuredFor[id]?.content == nextFor[id]?.content else { return false }
        }
        return true
    }
    #endif

    /// Measures the rows (exactly — no estimates), folds the row gap into
    /// every height but the last, and hands the pass to the session.
    private func apply(_ contents: [TimelineRowContent], measured: [String: MacRowMeasurement], forceReconfigure: Bool) {
        // Before the session applies: views configured during it read these.
        measurements = measured
        applyCountForTesting += 1
        appliedFooterLabel = .some(viewModel.activityLabel)
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

    /// The batch in flight renders every one of these rows at this width.
    private func precomputeCovers(_ texts: [TextRowContent]) -> Bool {
        precomputeTask != nil && precomputeWidth == width && Set(texts.map(\.itemID)).isSubset(of: precomputeIDs)
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

    /// The SwiftUI a hosted row renders, type-erased for the measurer's
    /// sizer — the same view `hostedRowBody` gives the cells, so render
    /// equals measure.
    func hostedRow(_ content: HostedRowContent) -> AnyView {
        AnyView(hostedRowBody(content))
    }

    /// A hosted row's SwiftUI as a concrete type: `HostedRowRoot`'s body, so
    /// a recycled cell diffs one row into another (perf follow-ups R1).
    @ViewBuilder
    func hostedRowBody(_ content: HostedRowContent) -> some View {
        if let override = hostedRowOverrideForTesting?(content) {
            override
        } else {
            MacTimelineRowView(
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
                .environment(\.conversationLinkHost, currentLinkRouting.conversationLinkHost)
        }
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
    static func footerContent(label: String?) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: metrics.bottomInset)
            if let label { ActivityIndicatorRow(label: label).padding(.bottom, 8) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func configureFooter(_ footer: MacHostedRowView) {
        let label = viewModel.activityLabel
        configuredFooterLabel = .some(label)
        footer.onHeightChange = nil
        footer.configure(rowID: "", expectedHeight: Self.metrics.bottomInset + session.scrollModel.footerHeight,
                         content: .footer(label: label), source: self)
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
        view.configure(rowID: id, expectedHeight: measurements[id]?.height ?? 0, content: .row(content), source: self)
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
    /// or no survivors at all — a room switch, a far jump). Reconfigured
    /// rows re-render in place when visible. Heights are reconciled by
    /// `setContentOffset`, which the session calls right after.
    func applyRows(_ ids: [String], reconfigure: [String], reload: [String]) {
        #if DEBUG
        assertOutsideDelegate("applyRows")
        #endif
        guard isViewLoaded else { return }
        #if DEBUG
        // Every apply, not only slow ones (D0): which rows a streaming
        // commit reconfigures besides `eph:`.
        lastApplyChangedIDs = reconfigure + reload
        if !lastApplyChangedIDs.isEmpty {
            timelineLogger.diag("mac timeline apply changed=\(lastApplyChangedIDs.count) ids=\(describeChanged(lastApplyChangedIDs))")
        }
        #endif
        // Row edits can clamp the clip origin: that is this write, not the
        // reader (the session ignores it anyway — it is mid layout update).
        let wasProgrammatic = scrollView.isApplyingProgrammaticScroll
        scrollView.isApplyingProgrammaticScroll = true
        defer { scrollView.isApplyingProgrammaticScroll = wasProgrammatic }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer { NSAnimationContext.endGrouping() }
        let old = tableIDs
        // Perf follow-ups O1 (b): an open or a jump (a reload) lands rows
        // around the reader, and that frame should mount only the ones on
        // screen. An extension does not: the reader may be scrolling (or
        // coasting) into the rows it prepends, which must be prepared as
        // usual. Neither does a tail append or a reconfigure.
        var landsRowsAroundReader = false
        defer {
            if landsRowsAroundReader, let table = tableView as? TimelineTableView {
                table.restrictPreparedContent(for: Self.preparedContentRestriction)
            }
        }
        if old != ids {
            let newSet = Set(ids)
            let oldSet = Set(old)
            let survivorsOld = old.filter(newSet.contains)
            let survivorsNew = ids.filter(oldSet.contains)
            // Perf follow-ups R2: however many rows leave and arrive (a
            // capped window slide swaps 120 of 360), survivors in order are
            // edited in place, so every surviving view stays mounted as is.
            if survivorsNew.isEmpty || survivorsOld != survivorsNew {
                tableIDs = ids
                tableHeights = expectedTableHeights()
                tableView.reloadData()
                reloadDataCountForTesting += 1
                landsRowsAroundReader = !ids.isEmpty
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
        // A drag still under the finger stays the user's (and so does the
        // gesture flag): its lift ends it.
        if scrollView.cancelGesture() { isUserGestureActive = false }
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

/// The table: reports the end of a window live resize (the full resync),
/// and prepares only what is on screen for a moment after an open or a
/// jump (perf follow-ups O1 (b)).
final class TimelineTableView: NSTableView {
    var onEndLiveResize: (() -> Void)?
    /// The time source for the restriction window (the controller's `clock`).
    var clock: () -> CFTimeInterval = CACurrentMediaTime
    private var restrictedUntil: CFTimeInterval = -.infinity
    /// The last rect AppKit asked to prepare while restricted: prepared once
    /// the window ends, so the overdraw rows still mount, only later.
    private var postponedPreparedRect: NSRect?
    private var isPostponedPrepareScheduled = false

    var isRestrictingPreparedContent: Bool { clock() < restrictedUntil }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }

    /// For `duration`, `prepareContent(in:)` prepares only `visibleRect`:
    /// the frame that shows an open or a jump mounts the rows on
    /// screen and none of AppKit's overdraw above and below them. Not
    /// permanent: in a steady scroll every prepared row is shown anyway, and
    /// a smaller prepared rect only moves that work into visible frames.
    func restrictPreparedContent(for duration: CFTimeInterval) {
        restrictedUntil = clock() + duration
        schedulePostponedPrepare(after: duration)
    }

    /// The rect the last `prepareContent(in:)` handed to AppKit (test seam:
    /// the table prepares incrementally, so `preparedContentRect` is not it).
    private(set) var lastPreparedRectForTesting: NSRect?

    override func prepareContent(in rect: NSRect) {
        guard isRestrictingPreparedContent else {
            lastPreparedRectForTesting = rect
            super.prepareContent(in: rect)
            return
        }
        postponedPreparedRect = rect
        lastPreparedRectForTesting = visibleRect
        super.prepareContent(in: visibleRect)
    }

    /// One timer at a time; it re-arms for whatever is left when the window
    /// was extended meanwhile (or its clock runs behind the timer's).
    private func schedulePostponedPrepare(after delay: CFTimeInterval) {
        guard !isPostponedPrepareScheduled else { return }
        isPostponedPrepareScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.001)) { [weak self] in
            guard let self else { return }
            self.isPostponedPrepareScheduled = false
            let remaining = self.restrictedUntil - self.clock()
            if remaining > 0 {
                self.schedulePostponedPrepare(after: remaining)
                return
            }
            guard let rect = self.postponedPreparedRect else { return }
            self.postponedPreparedRect = nil
            // The reader may have scrolled since AppKit asked: what is on
            // screen now is prepared too.
            self.prepareContent(in: rect.union(self.visibleRect))
        }
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
