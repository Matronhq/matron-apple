import UIKit
import SwiftUI
import os
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// Instruments intervals for the device pass (spec §4 performance gate).
let timelineSignposter = OSSignposter(subsystem: "chat.matron", category: "timeline")

/// Runs `action` once on the next display frame however often it was
/// requested since — the spec's "coalesced to one update per display frame".
/// `invalidate()` is final: a torn-down timeline never schedules again.
@MainActor
final class FrameCoalescer {
    /// The display link's target. It holds its owner weakly (the link and
    /// the run loop retain the target, never the owner) and invalidates the
    /// link itself if it ever ticks after the owner is gone.
    @MainActor
    private final class Target: NSObject {
        weak var owner: FrameCoalescer?
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.fire()
        }
    }

    /// `nonisolated(unsafe)` only so the plain (nonisolated) `deinit` can
    /// read it — `isolated deinit` needs an experimental flag CI's toolchain
    /// lacks. Every other access is on the main actor like the rest of the
    /// type, and `deinit` runs with no other reference left, so nothing can
    /// race it.
    nonisolated(unsafe) private var link: CADisplayLink?
    private let target = Target()
    private let action: () -> Void
    private var isInvalidated = false

    init(action: @escaping () -> Void) {
        self.action = action
        target.owner = self
    }

    /// Dropped without `invalidate()` (a controller released without
    /// `tearDown()`): take the link off the run loop. A main-actor object's
    /// last release is on main in practice; `invalidate` must run on the
    /// thread the link was added to (main), so any other thread hops there.
    deinit {
        guard let link else { return }
        if Thread.isMainThread {
            link.invalidate()
        } else {
            nonisolated(unsafe) let orphan = link
            DispatchQueue.main.async { orphan.invalidate() }
        }
    }

    /// Test seam: the display link currently scheduled, if any.
    var displayLinkForTesting: CADisplayLink? { link }

    var isPending: Bool { link.map { !$0.isPaused } ?? false }

    func request() {
        guard !isInvalidated else { return }
        if link == nil {
            let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }

    func invalidate() {
        isInvalidated = true
        link?.invalidate()
        link = nil
    }

    fileprivate func fire() {
        link?.isPaused = true
        action()
    }
}

/// The timeline's collection view. `UICollectionView.setFrame` moves
/// `contentOffset` by itself when the size changes (it keeps the visible
/// centre — a rotation or split-view resize); that write is UIKit's, not
/// the user's, so the controller must not record it (final review MUST 2).
/// `viewDidLayoutSubviews` then writes the model's decision back.
final class TimelineCollectionView: UICollectionView {
    private(set) var isChangingFrame = false
    /// Set when a frame change moved the offset; cleared by the controller.
    var frameChangeMovedOffset = false
    /// The controller's resume backstop (final re-review): a real window
    /// attach is itself proof the timeline is on screen again, whether or
    /// not an appear callback ran. A closure, not a delegate, so the
    /// controller can capture itself weakly and this view never retains it.
    var didAttachToWindow: (() -> Void)?

    override var frame: CGRect {
        get { super.frame }
        set {
            let before = contentOffset
            isChangingFrame = true
            super.frame = newValue
            isChangingFrame = false
            if contentOffset != before { frameChangeMovedOffset = true }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { didAttachToWindow?() }
    }
}

/// The controller's state and commands for the SwiftUI chrome around it
/// (jump button, top-trailing controls, `onDisappear`).
@Observable
@MainActor
final class ChatTimelineBridge {
    private(set) var isFollowingTail = true
    /// Nothing is applied yet and the first rows are still being measured
    /// off main (Bugbot "Precompute skips live timeline applies"): ChatView
    /// keeps its loading spinner up, since `viewModel.rows` is already
    /// non-empty and the timeline would otherwise sit blank.
    private(set) var isLoadingFirstRows = false
    @ObservationIgnored weak var controller: ChatTimelineController?

    func setFollowing(_ following: Bool) {
        if isFollowingTail != following { isFollowingTail = following }
    }

    func setLoadingFirstRows(_ loading: Bool) {
        if isLoadingFirstRows != loading { isLoadingFirstRows = loading }
    }

    func jumpToBottom() { controller?.jumpToBottom() }

    /// `ChatView.onDisappear`: remember (or forget) this room's position
    /// from the controller's real follow state. A no-op once the controller
    /// is gone — its `tearDown` has already stored.
    func storeScrollPosition() { controller?.storeScrollPosition() }

    /// `ChatView.onDisappear` (final review MUST 1): store, then park the
    /// controller — a tab switch or a pushed sub-chat / item / mission keeps
    /// it alive off screen while `onDisappear` shrinks the window under it.
    func chatDidDisappear() { controller?.suspend() }

    /// `ChatView.onAppear`: the chat is back — re-arm the remembered
    /// position, as the SwiftUI path's `.task` does on every appear.
    func chatWillAppear() { controller?.resume() }

    /// A remembered position is still to land. ChatView's `.task` skips
    /// `beginEntryWindow()` then: shrinking to the entry slice could drop
    /// the restore target after its one widen (Bugbot, PR #243).
    var hasPendingRestore: Bool { controller?.hasPendingRestore ?? false }
}

/// The UIKit chat timeline (spec 2026-09-26). Reads the unchanged
/// `ChatViewModel` API through Observation, measures every row exactly
/// before applying it, and is the ONLY writer of the collection view's
/// `contentOffset` — always the value `TimelineScrollModel` decided. The
/// position rules live in `TimelineSession` (shared with the Mac); this
/// controller is its UIKit `TimelineSurface`.
@MainActor
final class ChatTimelineController: UIViewController, UICollectionViewDelegate, TimelineLayoutSource, TimelineSurface {
    /// Up to this many unmeasured text rows are measured on the spot (a new
    /// message, the streaming row); more wait for the background precompute
    /// (window growth, a prepend, a first open).
    static let synchronousMeasureLimit = 8

    let viewModel: ChatViewModel
    let stripViewModel: SubChatStripViewModel
    let bridge: ChatTimelineBridge

    private(set) var session: TimelineSession!
    var scrollModel: TimelineScrollModel { session.scrollModel }
    private(set) var collectionView: UICollectionView!
    private let layout = TimelineLayout()
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var factory: HostedRowFactory
    private let measurer: TimelineMeasurer
    private let heights: TimelineHeightProvider
    private lazy var coalescer = FrameCoalescer { [weak self] in self?.sync() }

    private var contents: [String: TimelineRowContent] { session.contents }
    private var measurements: [String: TimelineMeasurement] = [:]
    private var mainThreadOnlyIDs = Set<String>()
    private var footerHeights: [String: CGFloat] = [:]
    private var width: CGFloat = 0
    private var style = TimelineTextStyle(sizeCategory: .large)
    private var forceSynchronousMeasure = false
    /// Set when a precompute batch lands: the next sync applies no matter
    /// how many rows the cache says are missing (it may have evicted the
    /// batch already), so a precompute always ends in an apply.
    private var precomputeLanded = false
    private var isTornDown: Bool { session.isTornDown }
    private var precomputeTask: Task<Void, Never>?
    /// The text rows the in-flight precompute renders; a sync whose missing
    /// rows fall outside it supersedes (cancels) that batch.
    private var precomputeIDs = Set<String>()
    private var precomputeGeneration = 0
    // Test seams, forwarded to the session (`TimelinePaginationTests`,
    // `TimelineRestoreTests`, `TimelineInvariantTests`).
    var exhaustedHeadID: String? { session.exhaustedHeadID }
    var extendRequestCount: Int { session.extendRequestCount }
    var hasPendingRestore: Bool { session.hasPendingRestore }
    var isSuspended: Bool { session.isSuspended }
    var invariantSnapCount: Int { session.invariantSnapCount }

    init(viewModel: ChatViewModel, stripViewModel: SubChatStripViewModel, bridge: ChatTimelineBridge,
         actions: ChatTimelineActions, environment: TimelineHostedEnvironment,
         cache: TimelineMeasureCache = .shared, precomputeDelayNanosecondsForTesting: UInt64 = 0) {
        self.viewModel = viewModel
        self.stripViewModel = stripViewModel
        self.bridge = bridge
        let factory = HostedRowFactory(viewModel: viewModel, actions: actions, environment: environment)
        let measurer = TimelineMeasurer(factory: factory)
        self.factory = factory
        self.measurer = measurer
        self.heights = TimelineHeightProvider(roomID: viewModel.roomID, cache: cache, measurer: measurer,
                                              precomputeDelayNanoseconds: precomputeDelayNanosecondsForTesting)
        super.init(nibName: nil, bundle: nil)
        session = TimelineSession(viewModel: viewModel, surface: self)
        bridge.controller = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Lifecycle

    func update(actions: ChatTimelineActions, environment: TimelineHostedEnvironment) {
        factory.actions = actions
        factory.environment = environment
        measurer.factory = factory
    }

    /// Called by the representable when SwiftUI removes this timeline.
    func tearDown() {
        guard !isTornDown else { return }
        // The session stores the position (Review F6) and latches torn down.
        session.tearDown()
        coalescer.invalidate()
        cancelPrecompute()
    }

    var appliedRowIDs: [String] { scrollModel.rows.map(\.id) }
    var layoutDesyncCount: Int { layout.desyncCount }
    var hasPendingWork: Bool { precomputeTask != nil || coalescer.isPending }

    override func viewDidLoad() {
        super.viewDidLoad()
        layout.source = self
        let collectionView = TimelineCollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        // ChatKeyboardAvoidance resizes our frame; no automatic insets, so
        // every offset here is raw content space (TimelineLayout relies on it).
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.accessibilityIdentifier = "chat.timeline"
        collectionView.delegate = self
        collectionView.didAttachToWindow = { [weak self] in self?.resume() }
        view.addSubview(collectionView)
        self.collectionView = collectionView
        configureDataSource()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: ChatTimelineController, _: UITraitCollection) in
            controller.contentSizeCategoryChanged()
        }
        timelineLogger.breadcrumb("uikit timeline load room=\(viewModel.roomID) rows=\(viewModel.windowedRows.count)")
        session.mount()
    }

    #if DEBUG || MATRON_PERF_PROBE
    private var perfProbe: TimelinePerfProbe?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard perfProbe == nil,
              let config = TimelinePerfProbe.Config.fromEnvironment(ProcessInfo.processInfo.environment) else { return }
        let probe = TimelinePerfProbe(scrollView: collectionView, config: config) { [weak self] in
            // The auto-scroll is a "user" reading history: release follow-tail.
            self?.session.userDragBegan()
        }
        perfProbe = probe
        // Let the open (entry window → steady window → paginate) settle first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { probe.start() }
    }
    #endif

    // MARK: Off screen (final review MUST 1)

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        resume()
    }

    /// Final re-review backstop: `resume()` is idempotent, so calling it
    /// again here (and from `TimelineCollectionView.didAttachToWindow`) is
    /// free — but it means a missed `viewWillAppear` / `chatWillAppear` can
    /// never leave the timeline latched suspended while actually on screen.
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        resume()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        suspend()
    }

    /// Leaving the screen without a dismantle (`TimelineSession.suspend`).
    func suspend() { session.suspend() }

    /// Back on screen (`TimelineSession.resume`). Idempotent.
    func resume() { session.resume() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = collectionView.bounds.size
        // Final review MUST 2: rotation changes width AND height in one pass.
        // The width resync below keeps the TOP anchor, so the height change
        // must keep the top too — keeping the bottom row first would hand
        // the resync the wrong top message.
        let widthChanging = width > 0 && size.width > 0 && size.width != width
        if size.height != scrollModel.viewportHeight {
            // TimelineLayout ignores height-only bounds changes; the explicit
            // invalidate inside setContentOffset re-lays the hug/pin. The
            // session re-tries a pending restore (rows may have applied while
            // the viewport was still 0 tall).
            session.setViewportHeight(size.height, widthChanging: widthChanging)
        }
        if size.width != width, size.width > 0 {
            let hadWidth = width > 0
            width = size.width
            style = TimelineTextStyle(sizeCategory: resolvedSizeCategory())
            footerHeights.removeAll()
            if hadWidth { resyncSynchronously() } else { sync() }
        }
        // Whatever path ran above (or none — a suspended resync), the offset
        // on screen is the model's, never the one UIKit's resize picked.
        if let timeline = collectionView as? TimelineCollectionView, timeline.frameChangeMovedOffset {
            timeline.frameChangeMovedOffset = false
            if abs(collectionView.contentOffset.y - scrollModel.contentOffsetY) > 0.25 {
                session.performLayoutUpdate { _ in }
            }
        }
    }

    /// The Dynamic Type size rows are measured and rendered at. An
    /// unattached controller can report `.unspecified`; measure at the
    /// system default then (Task 25 re-measures on a trait change).
    private func resolvedSizeCategory() -> UIContentSizeCategory {
        let category = traitCollection.preferredContentSizeCategory
        return category == .unspecified ? .large : category
    }

    /// Dynamic Type changed: every row re-measures (the style is half of
    /// every cache key) synchronously, so the top anchor survives exactly.
    private func contentSizeCategoryChanged() {
        // Resolved, like every other style read: an `.unspecified` trait
        // must not become a style (or a cache key) of its own.
        let category = resolvedSizeCategory()
        guard category != style.sizeCategory else { return }
        style = TimelineTextStyle(sizeCategory: category)
        footerHeights.removeAll()
        mainThreadOnlyIDs.removeAll()
        timelineLogger.breadcrumb("timeline Dynamic Type → \(category.rawValue)")
        resyncSynchronously()
    }

    // MARK: Data source

    private func configureDataSource() {
        let textRegistration = UICollectionView.CellRegistration<TextMessageCell, String> { [weak self] cell, _, id in
            guard let self else { return }
            guard case .text(let render)? = self.measurements[id] else {
                timelineLogger.breadcrumb("timeline text cell \(id) has no text measurement")
                assertionFailure("text cell \(id) configured without a .text measurement")
                return
            }
            cell.configure(render: render, factory: self.factory) { [weak self] itemID in
                self?.viewModel.retrySend(itemID: itemID)
            }
        }
        let hostedRegistration = UICollectionView.CellRegistration<HostedRowCell, String> { [weak self] cell, _, id in
            guard let self, case .hosted(let content)? = self.contents[id] else { return }
            cell.onHeightChange = { [weak self] rowID, height in self?.hostedHeightChanged(rowID, to: height) }
            // Same factory + same size category the measurer used → render == measure.
            cell.configure(rowID: id, expectedHeight: self.measurements[id]?.height ?? 0,
                           content: self.factory.row(content, sizeCategory: self.style.sizeCategory))
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<TimelineFooterView>(
            elementKind: TimelineLayout.footerKind
        ) { [weak self] footer, _, _ in
            // TimelineFooterView has no prepareForReuse: always assign, and
            // an empty view when there is no activity, so nothing stale shows.
            footer.configure(content: self?.footerContent() ?? AnyView(EmptyView()))
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] view, indexPath, id in
            if case .text? = self?.contents[id] {
                return view.dequeueConfiguredReusableCell(using: textRegistration, for: indexPath, item: id)
            }
            return view.dequeueConfiguredReusableCell(using: hostedRegistration, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { view, _, indexPath in
            view.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
    }

    private func footerContent() -> AnyView {
        guard let label = viewModel.activityLabel else { return AnyView(EmptyView()) }
        return factory.footer(label: label, sizeCategory: style.sizeCategory)
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
            // The view models mutate on the main actor, so this normally
            // runs there: mark the frame pending synchronously (no hop in
            // which the change is invisible to `hasPendingWork`).
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.requestSync() }
            } else {
                Task { @MainActor in self?.requestSync() }
            }
        }
    }

    func requestSync() {
        guard !isTornDown, !isSuspended else { return }
        coalescer.request()
    }

    /// One pass: re-arm observation, build row contents, measure (or defer
    /// to the precompute), apply, then the post-apply position rules.
    func sync() {
        guard !isTornDown, !isSuspended else { return }
        observeViewModel()
        guard width > 0 else { return }
        let built = TimelineRowContentBuilder.build(TimelineRowSource(
            rows: viewModel.windowedRows,
            hasMultipleSenders: viewModel.hasMultipleSenders,
            children: stripViewModel.children,
            imagePixelSize: { [viewModel] url in viewModel.imagePixelSize(for: url) }))
        if !built.droppedDuplicates.isEmpty {
            timelineLogger.breadcrumb("timeline dropped duplicate row ids \(built.droppedDuplicates.prefix(5).joined(separator: ","))")
        }
        let missing = heights.missingText(in: built.contents, width: width, style: style, excluding: mainThreadOnlyIDs)
        let mustApply = forceSynchronousMeasure || precomputeLanded
        if missing.count > Self.synchronousMeasureLimit, !mustApply {
            schedulePrecompute(missing)
            // No estimates, so nothing partial to show: until the batch
            // lands, an empty timeline shows the loading spinner instead.
            bridge.setLoadingFirstRows(scrollModel.rows.isEmpty)
            return
        }
        if precomputeLanded, missing.count > Self.synchronousMeasureLimit {
            timelineLogger.breadcrumb("timeline precompute landed with \(missing.count) rows still missing — measuring on main")
        }
        precomputeLanded = false
        // A batch still in flight is moot once everything is measured here.
        if missing.count > Self.synchronousMeasureLimit { cancelPrecompute() }
        apply(built.contents)
        bridge.setLoadingFirstRows(false)
        session.afterApply()
    }

    private func resyncSynchronously() {
        forceSynchronousMeasure = true
        defer { forceSynchronousMeasure = false }
        cancelPrecompute()
        sync()
    }

    /// Background-renders the window's unmeasured text rows, then syncs. A
    /// batch already covering these rows is left to finish; one that
    /// doesn't (the window moved on) is cancelled and replaced.
    private func schedulePrecompute(_ texts: [TextRowContent]) {
        let ids = Set(texts.map(\.itemID))
        if precomputeTask != nil {
            if ids.isSubset(of: precomputeIDs) { return }
            cancelPrecompute()
        }
        precomputeGeneration += 1
        let generation = precomputeGeneration
        precomputeIDs = ids
        let heights = heights, width = width, style = style
        precomputeTask = Task { [weak self] in
            let signpost = timelineSignposter.beginInterval("timeline.precompute", id: timelineSignposter.makeSignpostID(),
                                                            "\(texts.count) rows")
            let needsMain = await heights.precompute(texts, width: width, style: style)
            timelineSignposter.endInterval("timeline.precompute", signpost)
            guard let self, generation == self.precomputeGeneration else { return }
            self.mainThreadOnlyIDs.formUnion(needsMain)
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

    /// Measures every row (exactly — no estimates), then hands the pass to
    /// the session, which diffs, applies through `applyRows` and runs the
    /// rescue breadcrumb and the blank-chat check.
    private func apply(_ newContents: [TimelineRowContent]) {
        let signpost = timelineSignposter.beginInterval("timeline.apply", id: timelineSignposter.makeSignpostID())
        defer { timelineSignposter.endInterval("timeline.apply", signpost) }
        var nextMeasurements: [String: TimelineMeasurement] = [:]
        for content in newContents {
            nextMeasurements[content.anchorID] = heights.measurement(content, width: width, style: style)
        }
        // Before the session applies: cells dequeued during the apply read it.
        measurements = nextMeasurements
        session.apply(newContents, heights: measurements.mapValues(\.height), footerHeight: currentFooterHeight(),
                      forceReconfigure: forceSynchronousMeasure)
        reconfigureFooter()
    }

    // MARK: TimelineSurface

    /// `contents` (before this pass) is exactly the applied snapshot: both
    /// only ever change in `TimelineSession.apply`, together.
    func applyRows(_ ids: [String], reconfigure: [String], reload: [String]) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        snapshot.reconfigureItems(reconfigure)
        snapshot.reloadItems(reload)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The single `contentOffset` write (the session's `performLayoutUpdate`
    /// calls it once per model change, inside its guard so UIKit's
    /// intermediate scroll callbacks can't feed back into the model):
    /// invalidate, write the model's offset, lay out.
    func setContentOffset(_ offsetY: CGFloat) {
        layout.invalidateLayout()
        if abs(collectionView.contentOffset.y - offsetY) > 0.25 {
            collectionView.contentOffset = CGPoint(x: 0, y: offsetY)
        }
        collectionView.layoutIfNeeded()
    }

    func followingChanged(_ following: Bool) {
        bridge.setFollowing(following)
    }

    /// The INVARIANT breadcrumb's real offset (diagnostics only).
    var currentOffsetY: CGFloat? { isViewLoaded ? collectionView.contentOffset.y : nil }

    /// The blank-chat tripwire's probe. Off window it never trips.
    func hasVisibleRows() -> Bool {
        guard view.window != nil else { return true }
        collectionView.layoutIfNeeded()
        return !collectionView.indexPathsForVisibleItems.isEmpty
    }

    private func currentFooterHeight() -> CGFloat {
        guard let label = viewModel.activityLabel else { return 0 }
        if let height = footerHeights[label] { return height }
        let height = measurer.footerHeight(label: label, width: width, style: style)
        footerHeights[label] = height
        return height
    }

    /// The footer on screen shows the current label (or nothing) — a label
    /// change doesn't go through the snapshot, so it's pushed here.
    private func reconfigureFooter() {
        guard let footer = collectionView.supplementaryView(forElementKind: TimelineLayout.footerKind,
                                                            at: TimelineLayout.footerIndexPath) as? TimelineFooterView
        else { return }
        footer.configure(content: footerContent())
    }

    // MARK: Position rules

    /// A hosted cell's content settled at a height other than measured (an
    /// ask card answered, an image landed): re-measure only that row.
    private func hostedHeightChanged(_ id: String, to height: CGFloat) {
        guard !isTornDown, let content = contents[id], !content.isText,
              let current = measurements[id]?.height, abs(current - height) > 0.5 else {
            return
        }
        heights.storeHostedHeight(height, for: content, width: width, style: style)
        measurements[id] = .hosted(height)
        session.updateHeight(ofRow: id, to: height)
    }

    /// The jump-to-latest button.
    func jumpToBottom() { session.jumpToBottom() }

    /// Zero-delta non-animated write: the canonical deceleration kill.
    func killMomentum() {
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
    }

    // MARK: UIScrollViewDelegate

    /// Every user-driven offset — drag, deceleration, bounce — lands in the
    /// model (anchor capture reads it). Offsets the controller writes itself
    /// are already the model's and are skipped.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // A resize's own offset write (see `TimelineCollectionView`).
        if (scrollView as? TimelineCollectionView)?.isChangingFrame == true { return }
        session.userScrolled(toOffset: scrollView.contentOffset.y)
    }

    /// A status-bar tap scrolls to the top with no drag callbacks; it is
    /// still the user leaving the tail, so it releases follow-tail here.
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        session.userWillScrollToTop()
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        session.userScrolledToTop()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        session.userDragBegan()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { session.userScrollSettled() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        session.userScrollSettled()
    }

    // MARK: Restoration

    /// Leaving the room (`TimelineSession.storeScrollPosition`).
    func storeScrollPosition() { session.storeScrollPosition() }

    // MARK: Jumps

    /// Internal (not private) only so `TimelineJumpTests` can flash twice.
    func flashRow(_ id: String) {
        guard let index = scrollModel.index(of: id),
              let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) else { return }
        // One flash per cell: a second jump onto the same cell replaces it.
        cell.removeJumpFlash()
        let flash = UIView(frame: cell.bounds)
        flash.tag = UICollectionViewCell.jumpFlashTag
        flash.backgroundColor = UIColor.tintColor.withAlphaComponent(0.15)
        flash.isUserInteractionEnabled = false
        flash.accessibilityIdentifier = "chat.timeline.flash"
        cell.addSubview(flash)
        UIView.animate(withDuration: 0.6, delay: 0.4, options: [.curveEaseOut]) {
            flash.alpha = 0
        } completion: { _ in
            flash.removeFromSuperview()
        }
    }

    // MARK: Context menu

    /// The markdown source a text row's Copy puts on the pasteboard.
    func copyText(forRowID id: String) -> String? {
        guard case .text(let text)? = contents[id] else { return nil }
        return text.body
    }

    /// Copy for presses outside the text (bubble padding, time, pills gap);
    /// presses on the text belong to the text view. Hosted rows: no menu,
    /// as on the SwiftUI path.
    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let indexPath = indexPaths.first,
              let id = dataSource.itemIdentifier(for: indexPath), let body = copyText(forRowID: id) else { return nil }
        if let cell = collectionView.cellForItem(at: indexPath) as? TextMessageCell,
           cell.isTextHit(collectionView.convert(point, to: cell)) {
            return nil
        }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                Pasteboard.copy(body)
            }])
        }
    }

    // MARK: Invariant

    /// The blank-chat tripwire (`TimelineSession.verifyVisibleRows`).
    func verifyVisibleRows() { session.verifyVisibleRows() }
}

extension UICollectionViewCell {
    /// Tags the jump flash overlay so reuse can find it (Bugbot "Jump flash
    /// survives cell reuse": its animation completion alone removed it, so a
    /// cell recycled mid-animation flashed another message).
    static let jumpFlashTag = 0x6A_46_4C

    /// Called from both timeline cells' `prepareForReuse` and before a new
    /// flash is added.
    func removeJumpFlash() {
        for view in subviews where view.tag == Self.jumpFlashTag {
            view.layer.removeAllAnimations()
            view.removeFromSuperview()
        }
    }
}

private extension TimelineRowContent {
    var isText: Bool {
        if case .text = self { return true }
        return false
    }
}
