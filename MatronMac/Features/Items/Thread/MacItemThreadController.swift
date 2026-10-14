import AppKit
import SwiftUI
import MatronDesignSystem
import MatronModels

/// The Mac item thread as a table: only the rows on screen exist as views,
/// each card's text is measured once per width and cached, and every row's
/// height is final from its first layout, so nothing moves as the thread
/// scrolls. Cards (the body and comments) are native text on a bubble
/// ground; every other row, and each card's non-text pieces, are the
/// SwiftUI item view's own (`ItemDetailView.showing(only:)`). The Mac twin
/// of iOS `ItemThreadController`.
@MainActor
final class MacItemThreadController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    struct Geometry: Equatable {
        var atBottom = false
        var scrollable = false
        var placed = false
    }

    private enum Measured: Equatable {
        case card(MacItemCardLayout)
        case hosted(CGFloat)

        var height: CGFloat {
            switch self {
            case .card(let layout): return layout.height
            case .hosted(let height): return height
            }
        }
    }

    private struct CacheEntry {
        let content: ItemThreadRowContent
        let width: CGFloat
        let measured: Measured
    }

    /// What a row's hosted pieces took on screen, where a cell reported
    /// it, for as long as the row's content stays the same.
    private struct ScreenHeights {
        let content: ItemThreadRowContent
        var row: CGFloat?
        var pieces: [ItemDetailView.Piece: CGFloat] = [:]
    }

    private enum Keep { case nothing, position, tail }

    private(set) var factory: MacItemPieceFactory
    var onGeometryChange: (Geometry) -> Void = { _ in }

    private(set) var scrollView: MacTimelineScrollView!
    private(set) var tableView: TimelineTableView!
    private var coalescer: MacFrameCoalescer?
    private let sizer = MacItemPieceSizer()
    private var contents: [ItemThreadRowContent] = []
    private var measured: [Measured] = []
    private var rowIDs: [String] = []
    private var cache: [String: CacheEntry] = [:]
    private var screenHeights: [String: ScreenHeights] = [:]
    /// Selection id → markdown source of every drawn text part, for the
    /// cross-card selection over rows that are not on screen.
    private var sourceBySelectionID: [String: String] = [:]
    private var measuredWidth: CGFloat = 0
    private var shownItemID: String?
    private var threadWasLoaded = false
    private var isInSwiftUIUpdate = false
    private var isApplying = false
    private(set) var geometry = Geometry()
    /// Test seams.
    /// Stands in for the off-window sizer: what a piece measures there,
    /// which can differ from what it takes on screen.
    var measurePieceForTesting: ((ItemDetailView.Piece, CGFloat) -> CGSize?)?
    private(set) var measureCount = 0
    private(set) var builtCellCount = 0
    var rowCount: Int { rowIDs.count }
    func rowIndex(of id: String) -> Int? { rowIDs.firstIndex(of: id) }

    init(factory: MacItemPieceFactory) {
        self.factory = factory
        super.init(nibName: nil, bundle: nil)
        contents = buildContents()
        installSelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: View

    override func loadView() {
        let scrollView = MacTimelineScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        let tableView = TimelineTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("thread"))
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
        tableView.setAccessibilityIdentifier("item.thread")
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        self.scrollView = scrollView
        self.tableView = tableView
        applyInsets()
        view = scrollView
        coalescer = MacFrameCoalescer(view: scrollView) { [weak self] in self?.widthSettled() }
    }

    /// The SwiftUI thread's `.padding()`, and on Decisions its clearance
    /// under the clear title bar; the stack's 1-point anchor row at the foot.
    private func applyInsets() {
        let top = ItemTypography.threadPadding + (factory.environment.fillsTitleBar ? ItemDetailView.titleBarClearance : 0)
        let insets = NSEdgeInsets(top: top, left: 0, bottom: 1 + ItemTypography.threadPadding, right: 0)
        let current = scrollView.contentInsets
        guard current.top != insets.top || current.bottom != insets.bottom else { return }
        scrollView.contentInsets = insets
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentView.bounds.width
        guard width > 0, width != measuredWidth else { return }
        if measuredWidth == 0 {
            tableView.sizeLastColumnToFit()
            relayout(keeping: .nothing)
        } else {
            // A window or split-view drag steps the width once per pixel:
            // one relayout per frame, keeping the reader's row.
            coalescer?.request()
        }
    }

    private func widthSettled() {
        tableView.sizeLastColumnToFit()
        relayout(keeping: geometry.placed ? (geometry.atBottom && geometry.scrollable ? .tail : .position) : .nothing)
    }

    // MARK: Updates

    /// Takes the thread's new state. Rows whose content is unchanged keep
    /// their measurement; a reader at the tail follows a reply that lands.
    func update(factory: MacItemPieceFactory, inSwiftUIUpdate: Bool = false) {
        isInSwiftUIUpdate = inSwiftUIUpdate
        defer { isInSwiftUIUpdate = false }
        let swapped = shownItemID != nil && shownItemID != factory.detail.threadModel.item.id
        self.factory = factory
        installSelection()
        guard isViewLoaded else { return }
        applyInsets()
        if swapped {
            // Decisions swaps items under one controller: start over.
            geometry = Geometry()
            cache.removeAll()
            screenHeights.removeAll()
            contents = []
            rowIDs = []
            measured = []
            tableView.reloadData()
        }
        let oldCount = rowCountForFollowing
        let showedWorking = contents.last?.row == .working
        let wasLoaded = threadWasLoaded
        let detail = factory.detail
        threadWasLoaded = detail.threadModel.loadedCommentCount != nil
        contents = buildContents()
        guard measuredWidth > 0 || scrollView.contentView.bounds.width > 0 else { return }
        if !geometry.placed {
            relayout(keeping: .nothing)
            return
        }
        let follow = ItemDetailView.shouldFollowTail(
            loadedCount: detail.threadModel.loadedCommentCount, startsAtBottom: detail.threadStartsAtBottom,
            placed: geometry.placed, atBottom: geometry.atBottom, oldCount: oldCount, newCount: rowCountForFollowing)
        // A reader at the tail stays there when a row changes height where
        // they are (a voice note's transcript arriving).
        let pinned = oldCount == rowCountForFollowing && geometry.atBottom && geometry.scrollable
        let followWorking = ItemDetailView.shouldFollowWorking(
            appeared: contents.last?.row == .working && !showedWorking, startsAtBottom: detail.threadStartsAtBottom,
            placed: geometry.placed, atBottom: geometry.atBottom, wasLoaded: wasLoaded)
        relayout(keeping: follow || pinned || followWorking ? .tail : .position)
    }

    private func buildContents() -> [ItemThreadRowContent] {
        let detail = factory.detail
        return ItemThreadContentBuilder.contents(rows: detail.threadRows, model: detail.threadModel,
                                                 answersCommentActions: detail.answersCommentActions)
    }

    /// Comments and pending replies: what "the thread grew" counts.
    private var rowCountForFollowing: Int {
        contents.reduce(0) { count, content in
            switch content.row {
            case .comment, .pending: return count + 1
            default: return count
            }
        }
    }

    private func relayout(keeping keep: Keep) {
        let width = scrollView.contentView.bounds.width
        guard width > 0, !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        if width != measuredWidth {
            cache.removeAll()
            screenHeights.removeAll()
            measuredWidth = width
        }
        let anchor = keep == .position ? currentAnchor() : nil

        let oldIDs = rowIDs
        let oldMeasured = measured
        measured = contents.map(measure)
        rowIDs = contents.map(\.row.id)
        let ids = Set(rowIDs)
        cache = cache.filter { ids.contains($0.key) }
        screenHeights = screenHeights.filter { ids.contains($0.key) }
        indexSources()
        shownItemID = factory.detail.threadModel.item.id

        scrollView.isApplyingProgrammaticScroll = true
        defer { scrollView.isApplyingProgrammaticScroll = false }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        if oldIDs == rowIDs {
            var changed = IndexSet()
            for index in rowIDs.indices where oldMeasured[index] != measured[index] { changed.insert(index) }
            if !changed.isEmpty { tableView.noteHeightOfRows(withIndexesChanged: changed) }
            reconfigureVisibleRows()
        } else {
            tableView.reloadData()
        }
        NSAnimationContext.endGrouping()
        tableView.layoutSubtreeIfNeeded()

        switch keep {
        case .tail:
            scrollToBottom()
        case .position:
            if let anchor, let index = rowIDs.firstIndex(of: anchor.id) {
                setOffset(tableView.rect(ofRow: index).minY - anchor.offset)
            }
        case .nothing:
            break
        }
        placeInitiallyIfNeeded()
        isApplying = false
        reportGeometry()
    }

    private func indexSources() {
        sourceBySelectionID.removeAll(keepingCapacity: true)
        for case .card(let layout) in measured {
            for case .text(let id, let source) in layout.parts { sourceBySelectionID[id] = source }
        }
    }

    private func measure(_ content: ItemThreadRowContent) -> Measured {
        let id = content.row.id
        if let entry = cache[id], entry.content == content, entry.width == measuredWidth { return entry.measured }
        measureCount += 1
        let onScreen = screenHeights[id].flatMap { $0.content == content ? $0 : nil }
        if onScreen == nil { screenHeights[id] = nil }
        let width = measuredWidth
        let result: Measured
        switch content {
        case .card(let card):
            result = .card(MacItemCardGeometry.layout(card, textSelectionIDs: textSelectionIDs(for: card.row),
                                                      rowWidth: width) { piece, pieceWidth in
                var size = self.measurePieceForTesting?(piece, pieceWidth)
                    ?? self.sizer.size(of: self.factory.view(piece), maxWidth: pieceWidth)
                if let height = onScreen?.pieces[piece] { size.height = height }
                return size
            })
        case .hosted(let row, _):
            result = .hosted(onScreen?.row ?? sizer.size(of: factory.view(.row(row)), maxWidth: width).height)
        }
        cache[id] = CacheEntry(content: content, width: width, measured: result)
        return result
    }

    private func textSelectionIDs(for row: ItemThreadRow) -> [String] {
        let model = factory.detail.threadModel
        switch row {
        case .body:
            return MacItemCardGeometry.textSelectionIDs(cardID: ItemDetailView.bodySelectionID(for: model.item.id),
                                                        body: model.item.body, attachments: model.item.attachments)
        case .comment(let id):
            guard let comment = model.comments.first(where: { $0.id == id }) else { return [] }
            return MacItemCardGeometry.textSelectionIDs(cardID: id, body: comment.body, attachments: comment.attachments)
        default:
            return []
        }
    }

    // MARK: Hosted height reports

    /// A hosted row settled at a height other than measured: what is on
    /// screen is what the reader sees, so the row is laid out again with it,
    /// for as long as its content stays the same.
    func hostedRowReported(rowID: String, height: CGFloat) {
        guard let entry = cache[rowID] else { return }
        var known = screenHeights[rowID].flatMap { $0.content == entry.content ? $0 : nil }
            ?? ScreenHeights(content: entry.content)
        known.row = height
        screenHeights[rowID] = known
        cache[rowID] = nil
        relayout(keeping: geometry.atBottom && geometry.scrollable ? .tail : .position)
    }

    /// The same for one hosted piece of a card.
    func hostedPieceReported(rowID: String, piece: ItemDetailView.Piece, height: CGFloat) {
        guard let entry = cache[rowID] else { return }
        var known = screenHeights[rowID].flatMap { $0.content == entry.content ? $0 : nil }
            ?? ScreenHeights(content: entry.content)
        known.pieces[piece] = height
        screenHeights[rowID] = known
        cache[rowID] = nil
        relayout(keeping: geometry.atBottom && geometry.scrollable ? .tail : .position)
    }

    // MARK: Scrolling

    private var minOffset: CGFloat { -scrollView.contentInsets.top }

    private var maxOffset: CGFloat {
        max(minOffset, tableView.frame.height - scrollView.contentView.bounds.height + scrollView.contentInsets.bottom)
    }

    /// The first row on screen, and how far its top is below the viewport's.
    private func currentAnchor() -> (id: String, offset: CGFloat)? {
        let top = scrollView.contentView.bounds.minY
        let visible = tableView.rows(in: NSRect(x: 0, y: max(0, top), width: 1, height: 1))
        let index = visible.length > 0 ? visible.location : (top < 0 ? 0 : NSNotFound)
        guard index != NSNotFound, index < rowIDs.count else { return nil }
        return (rowIDs[index], tableView.rect(ofRow: index).minY - top)
    }

    private func setOffset(_ y: CGFloat) {
        let clamped = min(max(y, minOffset), maxOffset)
        guard abs(scrollView.contentView.bounds.minY - clamped) > 0.5 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func scrollToBottom() {
        setOffset(maxOffset)
        reportGeometry()
    }

    private func placeInitiallyIfNeeded() {
        guard !geometry.placed, measuredWidth > 0, !rowIDs.isEmpty else { return }
        geometry.placed = true
        if factory.detail.threadStartsAtBottom {
            setOffset(maxOffset)
        } else {
            setOffset(minOffset)
        }
        let placed = geometry
        notify { [onGeometryChange] in onGeometryChange(placed) }
    }

    /// The reader scrolled. A move made while rows are being applied is the
    /// table settling, half-updated: `relayout` reports once it is done.
    @objc private func clipBoundsChanged() {
        guard !isApplying else { return }
        reportGeometry()
    }

    /// Tells SwiftUI: at once, or after the view update it is in the
    /// middle of.
    private func notify(_ report: @escaping @MainActor () -> Void) {
        if isInSwiftUIUpdate {
            DispatchQueue.main.async(execute: report)
        } else {
            report()
        }
    }

    private func reportGeometry() {
        guard geometry.placed else { return }
        let clip = scrollView.contentView.bounds
        var next = geometry
        let insets = scrollView.contentInsets
        next.scrollable = tableView.frame.height + insets.top + insets.bottom > clip.height + 8
        next.atBottom = clip.minY >= maxOffset - 8
        guard next != geometry else { return }
        let bottomChanged = next.atBottom != geometry.atBottom
        geometry = next
        notify { [onGeometryChange, detail = factory.detail] in
            onGeometryChange(next)
            if bottomChanged { detail.reportBottomVisibility(next.atBottom) }
        }
    }

    // MARK: Selection

    /// The cross-card selection over this thread: the SwiftUI thread's row
    /// order and transcript, and the text of cards not on screen.
    private func installSelection() {
        let selection = factory.selection
        let model = factory.detail.threadModel
        let order = ItemDetailView.selectionOrder(item: model.item, comments: model.comments)
        if selection.orderedIDs != order { selection.orderedIDs = order }
        selection.transcriptProvider = { [weak selection] in
            guard let selection else { return SelectionTranscript(text: "", messageCount: 0) }
            return ItemDetailView.transcript(item: model.item, comments: model.comments, spans: selection.selectedSpans())
        }
        selection.contentProvider = { [weak self] id in
            guard let source = self?.sourceBySelectionID[id] else { return nil }
            return (MacItemCardGeometry.rendered(source).attributed, source)
        }
    }

    func tearDown() {
        factory.selection.clear()
        coalescer?.invalidate()
    }

    // MARK: Table

    private var routing: MacTimelineLinkRouting {
        let environment = factory.environment
        return MacTimelineLinkRouting(openTrackerItem: environment.openTrackerItem,
                                      openConversation: environment.openConversation,
                                      openPageLink: environment.openPageLink,
                                      trackerNumberLinks: environment.trackerNumberLinks,
                                      conversationLinkHost: environment.conversationLinkHost)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { measured.count }

    /// The row and the gap below it.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < measured.count else { return 1 }
        return max(1, measured[row].height + ItemTypography.threadSpacing)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < measured.count else { return nil }
        let view: NSView
        switch measured[row] {
        case .card:
            let cell = tableView.makeView(withIdentifier: MacItemCardCell.identifier, owner: nil) as? MacItemCardCell
                ?? makeCardCell()
            view = cell
        case .hosted:
            let cell = tableView.makeView(withIdentifier: MacItemHostedCell.identifier, owner: nil) as? MacItemHostedCell
                ?? makeHostedCell()
            view = cell
        }
        configure(view, row: row)
        return view
    }

    private func makeCardCell() -> MacItemCardCell {
        builtCellCount += 1
        let cell = MacItemCardCell(frame: .zero)
        cell.identifier = MacItemCardCell.identifier
        cell.onHeightChange = { [weak self] id, piece, height in
            self?.hostedPieceReported(rowID: id, piece: piece, height: height)
        }
        return cell
    }

    private func makeHostedCell() -> MacItemHostedCell {
        builtCellCount += 1
        let cell = MacItemHostedCell(frame: .zero)
        cell.identifier = MacItemHostedCell.identifier
        cell.onHeightChange = { [weak self] id, height in self?.hostedRowReported(rowID: id, height: height) }
        return cell
    }

    private func configure(_ view: NSView, row: Int) {
        let id = rowIDs[row]
        switch (measured[row], contents[row], view) {
        case (.card(let layout), .card(let card), let cell as MacItemCardCell):
            cell.configure(rowID: id, layout: layout, mine: card.mine, dimmed: card.hasDelivery, factory: factory,
                           selection: factory.selection, routing: routing)
        case (.hosted(let height), .hosted(let threadRow, _), let cell as MacItemHostedCell):
            cell.configure(rowID: id, expectedHeight: height, view: factory.view(.row(threadRow)))
        default:
            break
        }
    }

    /// Visible rows whose kind still matches their cell take the new state
    /// in place; the rest are reloaded.
    private func reconfigureVisibleRows() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        var reload = IndexSet()
        for row in visible.location..<min(visible.location + visible.length, measured.count) {
            guard let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
            switch (measured[row], view) {
            case (.card, is MacItemCardCell), (.hosted, is MacItemHostedCell):
                configure(view, row: row)
            default:
                reload.insert(row)
            }
        }
        if !reload.isEmpty { tableView.reloadData(forRowIndexes: reload, columnIndexes: IndexSet(integer: 0)) }
    }
}
