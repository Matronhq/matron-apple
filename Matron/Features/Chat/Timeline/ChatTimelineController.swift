import UIKit
import SwiftUI
import os
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// Un-gated breadcrumbs for the UIKit timeline — same subsystem as the
/// SwiftUI path's `ios-chat-view`, so field traces read as one story.
let timelineLogger = Logger(subsystem: "chat.matron", category: "ios-chat-timeline")

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

    private var link: CADisplayLink?
    private let target = Target()
    private let action: () -> Void
    private var isInvalidated = false

    init(action: @escaping () -> Void) {
        self.action = action
        target.owner = self
    }

    /// Dropped without `invalidate()` (a controller released without
    /// `tearDown()`): take the link off the run loop.
    isolated deinit {
        link?.invalidate()
    }

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
}

/// The controller's state and commands for the SwiftUI chrome around it
/// (jump button, top-trailing controls, `onDisappear`).
@Observable
@MainActor
final class ChatTimelineBridge {
    private(set) var isFollowingTail = true
    @ObservationIgnored weak var controller: ChatTimelineController?

    func setFollowing(_ following: Bool) {
        if isFollowingTail != following { isFollowingTail = following }
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
}

/// The UIKit chat timeline (spec 2026-09-26). Reads the unchanged
/// `ChatViewModel` API through Observation, measures every row exactly
/// before applying it, and is the ONLY writer of the collection view's
/// `contentOffset` — always the value `TimelineScrollModel` decided.
@MainActor
final class ChatTimelineController: UIViewController, UICollectionViewDelegate, TimelineLayoutSource {
    /// Up to this many unmeasured text rows are measured on the spot (a new
    /// message, the streaming row); more wait for the background precompute
    /// (window growth, a prepend, a first open).
    static let synchronousMeasureLimit = 8

    let viewModel: ChatViewModel
    let stripViewModel: SubChatStripViewModel
    let bridge: ChatTimelineBridge

    private(set) var scrollModel = TimelineScrollModel()
    private(set) var collectionView: UICollectionView!
    private let layout = TimelineLayout()
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var factory: HostedRowFactory
    private let measurer: TimelineMeasurer
    private let heights: TimelineHeightProvider
    private lazy var coalescer = FrameCoalescer { [weak self] in self?.sync() }

    private var contents: [String: TimelineRowContent] = [:]
    private var measurements: [String: TimelineMeasurement] = [:]
    private var mainThreadOnlyIDs = Set<String>()
    private var footerHeights: [String: CGFloat] = [:]
    private var width: CGFloat = 0
    private var style = TimelineTextStyle(sizeCategory: .large)
    private var isApplyingLayout = false
    private var forceSynchronousMeasure = false
    /// Set when a precompute batch lands: the next sync applies no matter
    /// how many rows the cache says are missing (it may have evicted the
    /// batch already), so a precompute always ends in an apply.
    private var precomputeLanded = false
    private var isTornDown = false
    private var precomputeTask: Task<Void, Never>?
    /// The text rows the in-flight precompute renders; a sync whose missing
    /// rows fall outside it supersedes (cancels) that batch.
    private var precomputeIDs = Set<String>()
    private var precomputeGeneration = 0
    private var lastTailID: String?
    private var extendInFlight = false
    /// The window head an extend last came back with unchanged AND the
    /// view model confirmed exhausted: near-top stops asking until the
    /// head moves. `private(set)` only for `TimelinePaginationTests` — a
    /// test seam, never written from outside the controller.
    private(set) var exhaustedHeadID: String?
    private(set) var extendRequestCount = 0
    /// Set when a jump lands: `afterApply` must not fire pagination edge
    /// triggers off the back of that same apply (spec §2 Jumps — a jump
    /// landing near the top or bottom must not read as the user paging).
    /// Cleared the moment the user actually starts dragging.
    private var suppressEdgeTriggersUntilScroll = false
    /// A jump just landed and the user hasn't scrolled since: viewport
    /// resizes keep the landed row at the top (controller ruling, Task 28
    /// fix rounds 1–2; restores keep spec §2's bottom-row rule). Cleared by
    /// the user's next scroll.
    private var landedAnchorHoldsTop = false
    /// The remembered position this mount still has to land (spec §2 Scroll
    /// restoration). Read in `viewDidLoad`; cleared when it lands, when the
    /// target proves gone, or when the user / a jump takes over.
    private var pendingRestore: ChatScrollPosition?
    /// The one `ensureWindowContains` a restore may ask for. A target still
    /// missing on the apply after that gives up (no timers).
    private var restoreWidened = false
    var hasPendingRestore: Bool { pendingRestore != nil }
    /// Set by an explicit `storeScrollPosition()` (ChatView's `onDisappear`,
    /// which runs BEFORE it shrinks the window): `tearDown` must not then
    /// overwrite that entry with a post-shrink position. Cleared by anything
    /// that moves the viewport on the user's behalf afterwards — a drag, the
    /// jump button, a jump or restore landing, follow-tail re-arming (own
    /// send, settling at the tail), a status-bar scroll-to-top, the invariant
    /// snap — and by `resume()` (final review MUST 4).
    private var storedSinceLastMove = false
    /// Off screen but not dismantled (tab switch, a push): no applies, so the
    /// window shrink `onDisappear` makes can't move — or rescue — an unseen
    /// viewport. `resume()` re-arms the remembered position and resyncs.
    private(set) var isSuspended = false
    /// The blank-chat tripwire's fire count (spec §2 invariant). A test seam
    /// and a field-diagnostics counter; should stay 0 forever.
    private(set) var invariantSnapCount = 0

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
        // Review F6: store here too — SwiftUI may dismantle before
        // `onDisappear`, whose store goes through the bridge's WEAK controller.
        if !storedSinceLastMove { storeScrollPosition() }
        isTornDown = true
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
        view.addSubview(collectionView)
        self.collectionView = collectionView
        configureDataSource()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: ChatTimelineController, _: UITraitCollection) in
            controller.contentSizeCategoryChanged()
        }
        timelineLogger.breadcrumb("uikit timeline load room=\(viewModel.roomID) rows=\(viewModel.windowedRows.count)")
        // Read at mount, not in `init`: a controller can exist before its
        // room's position is stored (`TimelineHarness(attach: false)`).
        pendingRestore = ChatScrollPositionMemory.retrievePosition(roomID: viewModel.roomID)
        if pendingRestore != nil {
            // Same as the SwiftUI path: a remembered position opens released.
            scrollModel.stopFollowing()
            bridge.setFollowing(false)
        }
        coalescer.request()
    }

    #if DEBUG || MATRON_PERF_PROBE
    private var perfProbe: TimelinePerfProbe?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard perfProbe == nil,
              let config = TimelinePerfProbe.Config.fromEnvironment(ProcessInfo.processInfo.environment) else { return }
        let probe = TimelinePerfProbe(scrollView: collectionView, config: config) { [weak self] in
            // The auto-scroll is a "user" reading history: release follow-tail.
            guard let self, self.scrollModel.beginUserDrag() else { return }
            self.bridge.setFollowing(false)
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

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        suspend()
    }

    /// Leaving the screen without a dismantle: remember the position (unless
    /// `onDisappear` just did) and stop applying until `resume()`. Idempotent
    /// — `ChatView.onDisappear` and `viewDidDisappear` both call it.
    func suspend() {
        guard !isTornDown, !isSuspended else { return }
        if !storedSinceLastMove { storeScrollPosition() }
        isSuspended = true
        timelineLogger.breadcrumb("timeline suspended room=\(viewModel.roomID) following=\(scrollModel.isFollowingTail)")
    }

    /// Back on screen: re-arm the remembered position exactly like a fresh
    /// mount's `viewDidLoad` (the SwiftUI path re-restores in `.task` on
    /// every appear), widen for it BEFORE the first apply so the anchor never
    /// leaves the window, then resync. Idempotent; a no-op on first appear.
    func resume() {
        guard !isTornDown, isSuspended else { return }
        isSuspended = false
        storedSinceLastMove = false
        restoreWidened = false
        pendingRestore = ChatScrollPositionMemory.retrievePosition(roomID: viewModel.roomID)
        if let position = pendingRestore {
            scrollModel.stopFollowing()
            bridge.setFollowing(false)
            if viewModel.pendingFocusID == nil,
               !viewModel.windowedRows.contains(where: { TimelineRowContentBuilder.anchorID(for: $0) == position.itemID }),
               viewModel.rowAnchorIDs.contains(position.itemID) {
                restoreWidened = true
                viewModel.ensureWindowContains(position.itemID)
            }
        }
        timelineLogger.breadcrumb("timeline resumed room=\(viewModel.roomID) restore=\(pendingRestore?.itemID ?? "none")")
        coalescer.request()
    }

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
            // invalidate inside performLayoutUpdate re-lays the hug/pin.
            performLayoutUpdate {
                scrollModel.setViewportHeight(size.height, keepingTop: landedAnchorHoldsTop || widthChanging)
            }
            // Rows may have applied while the viewport was still 0 tall.
            if pendingRestore != nil { handlePendingRestore() }
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
                performLayoutUpdate {}
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

    private func requestSync() {
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
            return
        }
        if precomputeLanded, missing.count > Self.synchronousMeasureLimit {
            timelineLogger.breadcrumb("timeline precompute landed with \(missing.count) rows still missing — measuring on main")
        }
        precomputeLanded = false
        // A batch still in flight is moot once everything is measured here.
        if missing.count > Self.synchronousMeasureLimit { cancelPrecompute() }
        apply(built.contents)
        afterApply()
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

    private func apply(_ newContents: [TimelineRowContent]) {
        let signpost = timelineSignposter.beginInterval("timeline.apply", id: timelineSignposter.makeSignpostID())
        defer { timelineSignposter.endInterval("timeline.apply", signpost) }
        var rows: [TimelineScrollModel.Row] = []
        rows.reserveCapacity(newContents.count)
        var reconfigure: [String] = []
        var reload: [String] = []
        var nextContents: [String: TimelineRowContent] = [:]
        var nextMeasurements: [String: TimelineMeasurement] = [:]
        for content in newContents {
            let id = content.anchorID
            if let old = contents[id], old != content || forceSynchronousMeasure {
                // A reconfigure must dequeue the same cell class it already
                // shows; a row switching text ↔ hosted is reloaded instead.
                if old.isText == content.isText { reconfigure.append(id) } else { reload.append(id) }
            }
            let measurement = heights.measurement(content, width: width, style: style)
            nextContents[id] = content
            nextMeasurements[id] = measurement
            rows.append(.init(id: id, height: measurement.height))
        }
        contents = nextContents
        measurements = nextMeasurements

        // `contents` (before this pass) is exactly the applied snapshot:
        // both only ever change here, together.
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows.map(\.id))
        snapshot.reconfigureItems(reconfigure)
        snapshot.reloadItems(reload)
        performLayoutUpdate {
            scrollModel.windowContainsTail = viewModel.windowContainsTail
            scrollModel.replaceRows(rows, footerHeight: currentFooterHeight(), holdingBottom: pendingRestore != nil)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        reconfigureFooter()
        if let rescue = scrollModel.lastRescue {
            timelineLogger.breadcrumb("timeline anchor \(rescue.lostRowID) vanished → \(rescue.survivorID ?? "bottom")")
        }
        // Brief's `changed` = rows this pass actually reconfigured or reloaded
        // (the current code tracks those as two separate arrays, not one).
        timelineLogger.diag("timeline apply rows=\(rows.count) changed=\(reconfigure.count + reload.count) following=\(scrollModel.isFollowingTail) offset=\(Int(scrollModel.contentOffsetY)) contentH=\(Int(scrollModel.contentHeight))")
        verifyVisibleRows()
    }

    private func afterApply() {
        // Restore first: it yields to a pending focus jump, which then lands
        // in the same pass (a focus handled first would be overwritten).
        handlePendingRestore()
        handlePendingFocus()
        handleTailChange()
        // A prepend that lands while the reader is still near the top keeps
        // revealing; a detached window's bottom keeps sliding. A jump's own
        // landing apply is excluded (`suppressEdgeTriggersUntilScroll`):
        // see `handlePendingFocus`.
        if !scrollModel.isFollowingTail, !suppressEdgeTriggersUntilScroll { evaluateEdgeTriggers() }
    }

    /// The single `contentOffset` write path: mutate the model, invalidate,
    /// write the model's offset, lay out — all inside one guard so UIKit's
    /// intermediate scroll callbacks can't feed back into the model.
    private func performLayoutUpdate(_ changes: () -> Void) {
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        changes()
        layout.invalidateLayout()
        let target = scrollModel.contentOffsetY
        if abs(collectionView.contentOffset.y - target) > 0.25 {
            collectionView.contentOffset = CGPoint(x: 0, y: target)
        }
        collectionView.layoutIfNeeded()
        bridge.setFollowing(scrollModel.isFollowingTail)
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

    /// Your own outgoing message always returns you to the bottom.
    private func handleTailChange() {
        let tail = viewModel.lastRenderableItemID
        defer { lastTailID = tail }
        guard let tail, let previous = lastTailID, tail != previous,
              viewModel.lastRenderableItemIsOwn, !scrollModel.isFollowingTail else { return }
        timelineLogger.breadcrumb("follow-tail ON (own send)")
        storedSinceLastMove = false
        if !viewModel.windowContainsTail { viewModel.resetHistoryWindow() }
        performLayoutUpdate { scrollModel.followTail() }
    }

    /// A hosted cell's content settled at a height other than measured (an
    /// ask card answered, an image landed): re-measure only that row.
    private func hostedHeightChanged(_ id: String, to height: CGFloat) {
        guard !isTornDown, let content = contents[id], !content.isText,
              let current = measurements[id]?.height, abs(current - height) > 0.5 else {
            return
        }
        heights.storeHostedHeight(height, for: content, width: width, style: style)
        measurements[id] = .hosted(height)
        performLayoutUpdate { scrollModel.updateHeight(ofRow: id, to: height) }
    }

    /// The jump-to-latest button.
    func jumpToBottom() {
        cancelPendingRestore("jump button")
        landedAnchorHoldsTop = false
        storedSinceLastMove = false
        ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
        timelineLogger.breadcrumb("follow-tail ON (jump button)")
        performLayoutUpdate {
            killMomentum()
            scrollModel.followTail()
        }
        if !viewModel.windowContainsTail { viewModel.resetHistoryWindow() }
    }

    /// Zero-delta non-animated write: the canonical deceleration kill.
    private func killMomentum() {
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
    }

    // MARK: UIScrollViewDelegate

    /// Every user-driven offset — drag, deceleration, bounce — lands in the
    /// model (anchor capture reads it). Offsets the controller writes itself
    /// are already the model's and are skipped.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isApplyingLayout else { return }
        // A resize's own offset write (see `TimelineCollectionView`).
        if (scrollView as? TimelineCollectionView)?.isChangingFrame == true { return }
        scrollModel.noteUserOffset(scrollView.contentOffset.y)
        evaluateEdgeTriggers()
    }

    /// A status-bar tap scrolls to the top with no drag callbacks; it is
    /// still the user leaving the tail, so it releases follow-tail here.
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        landedAnchorHoldsTop = false
        if scrollModel.isFollowingTail {
            scrollModel.stopFollowing()
            timelineLogger.breadcrumb("follow-tail OFF (scroll to top)")
            bridge.setFollowing(false)
        }
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        // The status-bar tap moved the reader: an earlier explicit store is
        // stale now (final review MUST 4).
        storedSinceLastMove = false
        settleAfterScroll()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        suppressEdgeTriggersUntilScroll = false
        landedAnchorHoldsTop = false
        storedSinceLastMove = false
        cancelPendingRestore("user drag")
        if scrollModel.beginUserDrag() {
            timelineLogger.breadcrumb("follow-tail OFF (user drag)")
            bridge.setFollowing(false)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settleAfterScroll() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleAfterScroll()
    }

    private func settleAfterScroll() {
        scrollModel.windowContainsTail = viewModel.windowContainsTail
        if scrollModel.endUserScroll() {
            storedSinceLastMove = false
            timelineLogger.breadcrumb("follow-tail ON (settled at tail)")
            bridge.setFollowing(true)
        }
    }

    // MARK: Restoration

    /// Spec §2 Scroll restoration: exact (id, offset) when the row is
    /// applied; widen once when it is loaded but outside the window;
    /// otherwise the entry is gone — forget it and open at the tail.
    /// A pending focus jump wins (review F5).
    private func handlePendingRestore() {
        guard let position = pendingRestore, !scrollModel.rows.isEmpty,
              scrollModel.viewportHeight > 0 else { return }
        if viewModel.pendingFocusID != nil {
            // Back to the no-memory state; `handlePendingFocus` runs next.
            cancelPendingRestore("pending focus")
            performLayoutUpdate { scrollModel.followTail() }
            return
        }
        if let index = scrollModel.index(of: position.itemID) {
            pendingRestore = nil
            storedSinceLastMove = false
            var landed = false
            performLayoutUpdate {
                if let offset = position.offsetInRow {
                    // The row may be shorter than when it was stored.
                    let clamped = min(max(0, CGFloat(offset)), scrollModel.rows[index].height)
                    landed = scrollModel.restore(.init(rowID: position.itemID, offsetInRow: clamped))
                } else {
                    landed = scrollModel.restoreBottomAligned(rowID: position.itemID)
                }
                if !landed { scrollModel.followTail() }
            }
            // Task 22 ruling: the landing apply must not fire the edge
            // triggers; only the user's next scroll may.
            suppressEdgeTriggersUntilScroll = true
            // Fix round 2 ruling: a restore does NOT hold the top — tapping
            // the composer after reopening must keep the bottom row the
            // reader was on (spec §2 Keyboard). Only jumps hold the top.
            landedAnchorHoldsTop = false
            timelineLogger.breadcrumb("restore → \(position.itemID) +\(position.offsetInRow.map { Int($0) } ?? -1) landed=\(landed)")
            return
        }
        if !restoreWidened, viewModel.rowAnchorIDs.contains(position.itemID) {
            restoreWidened = true
            viewModel.ensureWindowContains(position.itemID)
            // Synchronous: if the window now holds the row, the apply this
            // triggers lands it; if widening couldn't, give up now.
            if viewModel.windowedRows.contains(where: { TimelineRowContentBuilder.anchorID(for: $0) == position.itemID }) {
                return
            }
        } else if restoreWidened, hasPendingWork {
            // The widened window hasn't applied yet (e.g. a viewport-height
            // retry landed first); the apply that lands it decides.
            return
        }
        pendingRestore = nil
        storedSinceLastMove = false
        ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
        timelineLogger.breadcrumb("restore target \(position.itemID) gone (widened=\(restoreWidened)) → tail")
        performLayoutUpdate { scrollModel.followTail() }
    }

    private func cancelPendingRestore(_ reason: String) {
        guard let position = pendingRestore else { return }
        pendingRestore = nil
        timelineLogger.breadcrumb("restore → \(position.itemID) cancelled (\(reason))")
    }

    /// Leaving the room: remember the top anchor, or nothing while following.
    func storeScrollPosition() {
        guard !isTornDown else { return }                // tearDown already stored
        guard pendingRestore == nil else { return }      // never overwrite an unapplied entry
        storedSinceLastMove = true
        guard !scrollModel.isFollowingTail, let anchor = scrollModel.topAnchor() else {
            ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
            return
        }
        ChatScrollPositionMemory.store(roomID: viewModel.roomID, itemID: anchor.rowID,
                                       offsetInRow: Double(anchor.offsetInRow))
    }

    // MARK: Jumps

    /// Spec §2 Jumps. `focus(seq:)` has already widened the window; if our
    /// apply of that window is still pending (precompute), the next sync
    /// lands it. A target the view model no longer has at all is dropped.
    private func handlePendingFocus() {
        guard let target = viewModel.pendingFocusID else { return }
        guard scrollModel.index(of: target) != nil else {
            if !viewModel.rowAnchorIDs.contains(target) {
                timelineLogger.breadcrumb("jump target \(target) not loaded — dropped")
                viewModel.clearPendingFocus()
            } else if !viewModel.windowedRows.contains(where: { TimelineRowContentBuilder.anchorID(for: $0) == target }) {
                viewModel.ensureWindowContains(target)
            }
            return
        }
        viewModel.clearPendingFocus()
        storedSinceLastMove = false
        performLayoutUpdate {
            killMomentum()
            _ = scrollModel.jumpOffset(toRow: target)
            // Ruling: a jump that clamps to the very bottom while the
            // window still ends at the live tail means the user is sitting
            // at the bottom — re-arm follow-tail rather than leaving them
            // detached there.
            if scrollModel.windowContainsTail, scrollModel.contentOffsetY >= scrollModel.maxOffsetY - 0.5 {
                scrollModel.followTail()
            }
        }
        // Ruling: no paging off the back of a jump — this apply must not
        // fire the pagination edge triggers; only the user's next scroll
        // may (cleared in `scrollViewWillBeginDragging`).
        suppressEdgeTriggersUntilScroll = true
        landedAnchorHoldsTop = !scrollModel.isFollowingTail
        timelineLogger.breadcrumb("jump → \(target) (offset \(Int(scrollModel.contentOffsetY)))")
        flashRow(target)
    }

    private func flashRow(_ id: String) {
        guard let index = scrollModel.index(of: id),
              let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) else { return }
        let flash = UIView(frame: cell.bounds)
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

    // MARK: Pagination

    /// Spec §2 Pagination. Older: not following and within 1.5 screens of
    /// the top → `extendHistoryWindow()` (local growth first, network when
    /// the window already shows everything). Newer: a window detached from
    /// the tail, viewport near its bottom → `revealNewerHistory()`. Both
    /// prepends and slides keep the viewport by anchor — no pin, no retry.
    ///
    /// Review fix: `extendInFlight` / `isExtendingWindow` clear a fixed
    /// 150ms after the model change, but a big batch's precompute (and the
    /// apply that follows it) can easily outlive that hold. A scroll frame
    /// landing in that gap saw every guard clear and re-fired — 120 rows,
    /// then 240, then 360. `hasPendingWork` covers exactly that gap (the
    /// precompute in flight, or a sync already coalesced waiting for the
    /// next frame); `afterApply` re-evaluates once the batch actually lands.
    private func evaluateEdgeTriggers() {
        // No paging while a remembered position is still to land: the
        // viewport isn't the user's yet (review F5).
        guard !hasPendingWork, pendingRestore == nil else { return }
        if !scrollModel.isFollowingTail, scrollModel.isNearTop { requestOlderHistory() }
        if !viewModel.windowContainsTail, scrollModel.isNearBottom,
           !viewModel.isExtendingWindow, !viewModel.isPaginatingBackward {
            timelineLogger.breadcrumb("reveal newer (window detached, tail anchor \(viewModel.windowTailAnchorID ?? "nil"))")
            viewModel.revealNewerHistory()
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

    private func requestOlderHistory() {
        let head = scrollModel.rows.first { !$0.id.hasPrefix("sep:") }?.id
        guard !extendInFlight, !viewModel.isExtendingWindow, !viewModel.isPaginatingBackward,
              head != exhaustedHeadID else { return }
        extendInFlight = true
        extendRequestCount += 1
        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.extendHistoryWindow()
            let newHead = self.viewModel.windowedRows.lazy.compactMap { row -> String? in
                if case .message(let item) = row { return item.id }
                return nil
            }.first
            // Latch only when BOTH this call made no progress (the head is
            // exactly where it started) AND the view model's own verdict is
            // real exhaustion. Neither alone is enough: `reachedHistoryStart`
            // stays true for the life of the view model, so gating on it
            // alone latched the head of a later, perfectly SUCCESSFUL local
            // grow too (review fix round 2) — which could then block a
            // legitimate reveal that walks back onto that same head. And
            // "head didn't move" alone also fires on a local slide that
            // merely *held* (120+ consecutive transient rows, no network
            // call at all) — not real exhaustion either (review fix round 1).
            self.exhaustedHeadID = (self.viewModel.reachedHistoryStart && newHead == head) ? head : nil
            self.extendInFlight = false
            timelineLogger.diag("history reveal → head \(newHead ?? "nil") (was \(head ?? "nil")), reachedHistoryStart=\(self.viewModel.reachedHistoryStart)")
        }
    }

    // MARK: Invariant

    /// The blank-chat tripwire: rows exist but no cell is on screen. With
    /// exact heights and one offset writer this should never fire; if it
    /// does, leave a full breadcrumb and put the reader somewhere real.
    ///
    /// Review fix: rows can apply while the viewport is still 0 tall (mount,
    /// or a resize mid-flight) — `sync()` only requires `width > 0`. Without
    /// the viewport-height guard that state reads as "rows but no visible
    /// cells" and snaps for no reason, even over a pending restore.
    func verifyVisibleRows() {
        guard !scrollModel.rows.isEmpty, scrollModel.viewportHeight > 0, view.window != nil else { return }
        collectionView.layoutIfNeeded()
        guard collectionView.indexPathsForVisibleItems.isEmpty else { return }
        invariantSnapCount += 1
        storedSinceLastMove = false
        timelineLogger.breadcrumb("INVARIANT rows=\(scrollModel.rows.count) visible=0 offset=\(Int(collectionView.contentOffset.y)) contentH=\(Int(scrollModel.contentHeight)) viewport=\(Int(scrollModel.viewportHeight)) following=\(scrollModel.isFollowingTail) → snap to bottom")
        // Review fix: mirror `jumpToBottom` — kill any residual momentum
        // inside the same offset write, and never re-arm follow-tail on a
        // window detached from the live tail.
        performLayoutUpdate {
            killMomentum()
            scrollModel.followTail()
        }
        if !viewModel.windowContainsTail { viewModel.resetHistoryWindow() }
    }
}

private extension TimelineRowContent {
    var isText: Bool {
        if case .text = self { return true }
        return false
    }
}
