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
    /// The window head an extend last came back with unchanged: history is
    /// exhausted there, so near-top stops asking until the head moves.
    private var exhaustedHeadID: String?
    private(set) var extendRequestCount = 0

    init(viewModel: ChatViewModel, stripViewModel: SubChatStripViewModel, bridge: ChatTimelineBridge,
         actions: ChatTimelineActions, environment: TimelineHostedEnvironment,
         cache: TimelineMeasureCache = .shared) {
        self.viewModel = viewModel
        self.stripViewModel = stripViewModel
        self.bridge = bridge
        let factory = HostedRowFactory(viewModel: viewModel, actions: actions, environment: environment)
        let measurer = TimelineMeasurer(factory: factory)
        self.factory = factory
        self.measurer = measurer
        self.heights = TimelineHeightProvider(roomID: viewModel.roomID, cache: cache, measurer: measurer)
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
        isTornDown = true
        coalescer.invalidate()
        cancelPrecompute()
    }

    var appliedRowIDs: [String] { scrollModel.rows.map(\.id) }
    var hasPendingWork: Bool { precomputeTask != nil || coalescer.isPending }

    override func viewDidLoad() {
        super.viewDidLoad()
        layout.source = self
        let collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
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
        timelineLogger.breadcrumb("uikit timeline load room=\(viewModel.roomID) rows=\(viewModel.windowedRows.count)")
        coalescer.request()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = collectionView.bounds.size
        if size.height != scrollModel.viewportHeight {
            // TimelineLayout ignores height-only bounds changes; the explicit
            // invalidate inside performLayoutUpdate re-lays the hug/pin.
            performLayoutUpdate { scrollModel.setViewportHeight(size.height) }
        }
        if size.width != width, size.width > 0 {
            let hadWidth = width > 0
            width = size.width
            style = TimelineTextStyle(sizeCategory: resolvedSizeCategory())
            footerHeights.removeAll()
            if hadWidth { resyncSynchronously() } else { sync() }
        }
    }

    /// The Dynamic Type size rows are measured and rendered at. An
    /// unattached controller can report `.unspecified`; measure at the
    /// system default then (Task 25 re-measures on a trait change).
    private func resolvedSizeCategory() -> UIContentSizeCategory {
        let category = traitCollection.preferredContentSizeCategory
        return category == .unspecified ? .large : category
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
        guard !isTornDown else { return }
        coalescer.request()
    }

    /// One pass: re-arm observation, build row contents, measure (or defer
    /// to the precompute), apply, then the post-apply position rules.
    func sync() {
        guard !isTornDown else { return }
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
            let needsMain = await heights.precompute(texts, width: width, style: style)
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
            scrollModel.replaceRows(rows, footerHeight: currentFooterHeight())
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        reconfigureFooter()
        if let rescue = scrollModel.lastRescue {
            timelineLogger.breadcrumb("timeline anchor \(rescue.lostRowID) vanished → \(rescue.survivorID ?? "bottom")")
        }
    }

    private func afterApply() {
        handleTailChange()
        // A prepend that lands while the reader is still near the top keeps
        // revealing; a detached window's bottom keeps sliding.
        if !scrollModel.isFollowingTail { evaluateEdgeTriggers() }
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
        scrollModel.noteUserOffset(scrollView.contentOffset.y)
        evaluateEdgeTriggers()
    }

    /// A status-bar tap scrolls to the top with no drag callbacks; it is
    /// still the user leaving the tail, so it releases follow-tail here.
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        if scrollModel.isFollowingTail {
            scrollModel.stopFollowing()
            timelineLogger.breadcrumb("follow-tail OFF (scroll to top)")
            bridge.setFollowing(false)
        }
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        settleAfterScroll()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
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
            timelineLogger.breadcrumb("follow-tail ON (settled at tail)")
            bridge.setFollowing(true)
        }
    }

    // MARK: Pagination

    /// Spec §2 Pagination. Older: not following and within 1.5 screens of
    /// the top → `extendHistoryWindow()` (local growth first, network when
    /// the window already shows everything). Newer: a window detached from
    /// the tail, viewport near its bottom → `revealNewerHistory()`. Both
    /// prepends and slides keep the viewport by anchor — no pin, no retry.
    private func evaluateEdgeTriggers() {
        if !scrollModel.isFollowingTail, scrollModel.isNearTop { requestOlderHistory() }
        if !viewModel.windowContainsTail, scrollModel.isNearBottom,
           !viewModel.isExtendingWindow, !viewModel.isPaginatingBackward {
            timelineLogger.breadcrumb("reveal newer (window detached, tail anchor \(viewModel.windowTailAnchorID ?? "nil"))")
            viewModel.revealNewerHistory()
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
            self.exhaustedHeadID = (newHead == head) ? head : nil
            self.extendInFlight = false
            timelineLogger.diag("history reveal → head \(newHead ?? "nil") (was \(head ?? "nil"))")
        }
    }
}

private extension TimelineRowContent {
    var isText: Bool {
        if case .text = self { return true }
        return false
    }
}
