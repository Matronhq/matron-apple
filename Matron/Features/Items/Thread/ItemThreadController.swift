import UIKit
import SwiftUI
import MatronDesignSystem
import MatronModels

/// Whether the item thread is the native one (`ItemThreadController`) or
/// the SwiftUI stack. On unless switched off in Settings ▸ Device ▸
/// Advanced, which keeps the SwiftUI stack to fall back on.
enum ItemThreadFlag {
    static let key = "items.thread.native"

    static let defaultValue = true

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        // `bool(forKey:)`, not a cast: a launch argument arrives as text.
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }
}

/// One cell of the native thread: a row the SwiftUI view draws whole, a
/// card's ground, or one piece of a card.
struct ItemThreadCellItem: Equatable {
    enum Kind: Equatable {
        case hostedRow
        case ground
        case piece(Int)
    }

    let row: Int
    let kind: Kind
    /// Row id, kind and, for a piece, what it is: two layouts with the
    /// same ids in the same order differ only in frames and content.
    let id: String
    let frame: CGRect
}

/// Exact frames, worked out by the controller: no estimates, no
/// self-sizing. A card's ground lies under its pieces.
final class ItemThreadLayout: UICollectionViewLayout {
    var items: [ItemThreadCellItem] = []
    var contentHeight: CGFloat = 0
    private var attributes: [UICollectionViewLayoutAttributes] = []

    override func prepare() {
        super.prepare()
        guard let collectionView else { return attributes = [] }
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        attributes = items.prefix(count).enumerated().map { index, item in
            let attribute = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attribute.frame = item.frame
            attribute.zIndex = item.kind == .ground ? 0 : 1
            return attribute
        }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        attributes.indices.contains(indexPath.item) ? attributes[indexPath.item] : nil
    }

    /// The controller re-measures and invalidates on a width change itself.
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { false }
}

/// The item thread as a recycling list: only what is on screen exists as
/// views, each card's text is measured once per width and cached, and
/// every frame is exact from the first layout, so nothing moves as the
/// thread scrolls. A card is a ground cell and one cell per piece (a run of
/// paragraphs, a code block, a table, an attachment), so a card several
/// screens tall costs what is on screen of it. The SwiftUI `ItemDetailView`
/// draws the rows that are not cards and every card's non-text pieces.
@MainActor
final class ItemThreadController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    struct Geometry: Equatable {
        var atBottom = false
        var scrollable = false
        var placed = false
    }

    private enum Measured {
        case card(ItemCardRender)
        case hosted(CGFloat)

        var height: CGFloat {
            switch self {
            case .card(let render): return render.height
            case .hosted(let height): return height
            }
        }
    }

    private struct CacheEntry {
        let content: ItemThreadRowContent
        let measured: Measured
    }

    private(set) var factory: ItemThreadPieceFactory
    var onGeometryChange: (Geometry) -> Void = { _ in }

    private let layout = ItemThreadLayout()
    private(set) lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let sizer = ItemPieceSizer()
    private var contents: [ItemThreadRowContent] = []
    private var measured: [Measured] = []
    private var cache: [String: CacheEntry] = [:]
    private var measuredWidth: CGFloat = 0
    /// Heights a hosted cell reported that measuring its row did not
    /// change (see `remeasure`).
    private var unconfirmedReports: [String: CGFloat] = [:]
    /// Set while SwiftUI is updating the view: its state must not be
    /// written until the update is over.
    private var isInSwiftUIUpdate = false
    private var style = ItemThreadTextStyle(sizeCategory: .large)
    private(set) var geometry = Geometry()
    private var lastViewportHeight: CGFloat = 0
    /// Rows measured since the controller was made: a test seam.
    private(set) var measureCount = 0

    init(factory: ItemThreadPieceFactory) {
        self.factory = factory
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "item.thread"
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.register(ItemCardGroundCell.self, forCellWithReuseIdentifier: "ground")
        collectionView.register(ItemTextCell.self, forCellWithReuseIdentifier: "text")
        collectionView.register(ItemCodeCell.self, forCellWithReuseIdentifier: "code")
        collectionView.register(ItemTableCell.self, forCellWithReuseIdentifier: "table")
        collectionView.register(HostedRowCell.self, forCellWithReuseIdentifier: "hosted")
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(collectionView)
        style = ItemThreadTextStyle(sizeCategory: traitCollection.preferredContentSizeCategory)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: ItemThreadController, _) in
            self.style = ItemThreadTextStyle(sizeCategory: self.traitCollection.preferredContentSizeCategory)
            self.cache.removeAll()
            self.relayout(keeping: .position)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = collectionView.bounds.width
        let height = collectionView.bounds.height
        if width > 0, width != measuredWidth {
            relayout(keeping: geometry.placed ? .position : .nothing)
        } else if height != lastViewportHeight, geometry.placed, geometry.atBottom {
            // The keyboard or the composer took room: a reader at the tail
            // stays there.
            scrollToBottom(animated: false)
        }
        lastViewportHeight = height
        placeInitiallyIfNeeded()
    }

    // MARK: Updates

    /// Takes the thread's new state. Rows whose content is unchanged keep
    /// their measurement; a reader at the tail follows a reply that lands.
    func update(factory: ItemThreadPieceFactory, inSwiftUIUpdate: Bool = false) {
        isInSwiftUIUpdate = inSwiftUIUpdate
        defer { isInSwiftUIUpdate = false }
        self.factory = factory
        let oldCount = rowCountForFollowing
        let detail = factory.detail
        contents = ItemThreadContentBuilder.contents(rows: detail.threadRows, model: detail.threadModel,
                                                     answersCommentActions: detail.answersCommentActions)
        guard isViewLoaded, collectionView.bounds.width > 0 else { return }
        let follow = ItemDetailView.shouldFollowTail(
            loadedCount: detail.threadModel.loadedCommentCount, startsAtBottom: detail.threadStartsAtBottom,
            placed: geometry.placed, atBottom: geometry.atBottom, oldCount: oldCount, newCount: rowCountForFollowing)
        relayout(keeping: follow ? .tail : .position)
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

    private enum Keep { case nothing, position, tail }

    private func relayout(keeping keep: Keep) {
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        if width != measuredWidth {
            cache.removeAll()
            unconfirmedReports.removeAll()
            measuredWidth = width
        }
        // Where the reader is: the first row on screen and how far its top
        // is from the viewport's.
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        var anchor: (id: String, offset: CGFloat)?
        if keep == .position, let index = frames.firstRow(endingAfter: top), index < rowIDs.count {
            anchor = (rowIDs[index], frames.minYs[index] - top)
        }

        measured = contents.map(measure)
        cache = cache.filter { entry in contents.contains { $0.row.id == entry.key } }
        rowIDs = contents.map(\.row.id)
        frames = ItemThreadFrames(heights: measured.map(\.height))
        let items = Self.items(measured: measured, contents: contents, frames: frames, width: width)
        let sameCells = items.map(\.id) == layout.items.map(\.id)
        layout.items = items
        layout.contentHeight = frames.contentHeight
        if sameCells {
            layout.invalidateLayout()
            for cell in collectionView.visibleCells {
                guard let indexPath = collectionView.indexPath(for: cell) else { continue }
                configure(cell, at: indexPath.item)
            }
        } else {
            collectionView.reloadData()
        }
        collectionView.layoutIfNeeded()

        switch keep {
        case .tail:
            scrollToBottom(animated: false)
        case .position:
            if let anchor, let index = rowIDs.firstIndex(of: anchor.id) {
                setOffset(top: frames.minYs[index] - anchor.offset)
            }
        case .nothing:
            break
        }
        reportGeometry()
    }

    /// The cells of the measured rows, top to bottom; within a card, its
    /// ground and then its pieces.
    private static func items(measured: [Measured], contents: [ItemThreadRowContent], frames: ItemThreadFrames,
                              width: CGFloat) -> [ItemThreadCellItem] {
        var items: [ItemThreadCellItem] = []
        for (row, measurement) in measured.enumerated() {
            let id = contents[row].row.id
            let y = frames.minYs[row]
            switch measurement {
            case .hosted:
                items.append(.init(row: row, kind: .hostedRow, id: id, frame: frames.frame(at: row, width: width)))
            case .card(let render):
                items.append(.init(row: row, kind: .ground, id: id + "|ground", frame: render.cardFrame.offsetBy(dx: 0, dy: y)))
                for (index, piece) in render.pieces.enumerated() {
                    items.append(.init(row: row, kind: .piece(index), id: "\(id)|\(index)|\(Self.reuseIdentifier(piece.kind))",
                                       frame: piece.frame.offsetBy(dx: 0, dy: y)))
                }
            }
        }
        return items
    }

    private static func reuseIdentifier(_ kind: ItemCardRender.Kind) -> String {
        switch kind {
        case .text: return "text"
        case .code: return "code"
        case .table: return "table"
        case .hosted: return "hosted"
        }
    }

    private var rowIDs: [String] = []
    private var frames = ItemThreadFrames(heights: [])

    private func measure(_ content: ItemThreadRowContent) -> Measured {
        let id = content.row.id
        if let entry = cache[id], entry.content == content { return entry.measured }
        measureCount += 1
        let result: Measured
        switch content {
        case .card(let card):
            result = .card(ItemCardRenderer.render(card, rowWidth: measuredWidth, style: style) { piece, width in
                self.sizer.size(of: self.factory.view(piece, sizeCategory: self.style.sizeCategory), maxWidth: width)
            })
        case .hosted(let row, _):
            result = .hosted(sizer.size(of: factory.view(.detail(.row(row)), sizeCategory: style.sizeCategory),
                                        maxWidth: measuredWidth).height)
        }
        cache[id] = CacheEntry(content: content, measured: result)
        return result
    }

    /// A row's own content changed height on screen (a hosted piece
    /// reported it): measure that row again.
    ///
    /// The row is measured off screen, and that can disagree with the cell
    /// on screen. A report that measuring did not bear out is remembered,
    /// so the same report is not answered with the same measurement for
    /// ever.
    private func remeasure(rowID: String, reported: CGFloat) {
        guard let before = cache[rowID], unconfirmedReports[rowID] != reported else { return }
        cache[rowID] = nil
        relayout(keeping: geometry.atBottom && geometry.scrollable ? .tail : .position)
        unconfirmedReports[rowID] = cache[rowID]?.measured.height == before.measured.height ? reported : nil
    }

    // MARK: Scrolling

    private func placeInitiallyIfNeeded() {
        guard !geometry.placed, collectionView.bounds.width > 0, !contents.isEmpty, !measured.isEmpty else { return }
        geometry.placed = true
        if factory.detail.threadStartsAtBottom {
            scrollToBottom(animated: false)
            geometry.atBottom = true
        }
        let placed = geometry
        notify { [onGeometryChange] in onGeometryChange(placed) }
        reportGeometry()
    }

    private var maxOffsetY: CGFloat {
        let inset = collectionView.adjustedContentInset
        return max(-inset.top, frames.contentHeight - collectionView.bounds.height + inset.bottom)
    }

    private func setOffset(top: CGFloat) {
        let inset = collectionView.adjustedContentInset
        let y = min(max(top - inset.top, -inset.top), maxOffsetY)
        // Only when it moves: writing the offset stops a flick, and most
        // updates change nothing above the reader.
        guard abs(collectionView.contentOffset.y - y) > 0.5 else { return }
        collectionView.contentOffset = CGPoint(x: 0, y: y)
    }

    func scrollToBottom(animated: Bool) {
        collectionView.setContentOffset(CGPoint(x: 0, y: maxOffsetY), animated: animated)
        if !animated { reportGeometry() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
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
        let inset = collectionView.adjustedContentInset
        let visibleHeight = collectionView.bounds.height - inset.top - inset.bottom
        var next = geometry
        next.scrollable = frames.contentHeight > visibleHeight + 8
        next.atBottom = collectionView.contentOffset.y >= maxOffsetY - 8
        guard next != geometry else { return }
        let bottomChanged = next.atBottom != geometry.atBottom
        geometry = next
        notify { [onGeometryChange, detail = factory.detail] in
            onGeometryChange(next)
            if bottomChanged { detail.reportBottomVisibility(next.atBottom) }
        }
    }

    // MARK: Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        layout.items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let item = layout.items[indexPath.item]
        let identifier: String
        switch (item.kind, measured[item.row]) {
        case (.ground, _): identifier = "ground"
        case (.piece(let index), .card(let render)): identifier = Self.reuseIdentifier(render.pieces[index].kind)
        default: identifier = "hosted"
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: identifier, for: indexPath)
        configure(cell, at: indexPath.item)
        return cell
    }

    private func configure(_ cell: UICollectionViewCell, at index: Int) {
        guard index < layout.items.count else { return }
        let item = layout.items[index]
        let row = contents[item.row].row
        var dimmed = false
        switch (item.kind, measured[item.row]) {
        case (.hostedRow, .hosted(let height)):
            guard let cell = cell as? HostedRowCell else { return }
            cell.configure(rowID: row.id, expectedHeight: height,
                           content: factory.view(.detail(.row(row)), sizeCategory: style.sizeCategory))
            cell.onHeightChange = { [weak self] rowID, height in self?.remeasure(rowID: rowID, reported: height) }
        case (.ground, .card(let render)):
            (cell as? ItemCardGroundCell)?.configure(mine: render.content.mine)
            dimmed = render.content.hasDelivery
        case (.piece(let pieceIndex), .card(let render)):
            let piece = render.pieces[pieceIndex]
            dimmed = render.content.hasDelivery
            switch piece.kind {
            case .text(let text):
                (cell as? ItemTextCell)?.configure(text: text, router: factory.router)
            case .code(let language, let code):
                (cell as? ItemCodeCell)?.configure(language: language, code: code, style: render.style.code)
            case .table(let table):
                (cell as? ItemTableCell)?.configure(layout: table, router: factory.router)
            case .hosted(let hosted):
                guard let cell = cell as? HostedRowCell else { return }
                // Leading in its frame, as in the card's stack.
                let view = factory.view(hosted, sizeCategory: style.sizeCategory)
                    .frame(maxWidth: .infinity, alignment: .leading)
                cell.configure(rowID: row.id, expectedHeight: piece.frame.height, content: AnyView(view))
                cell.onHeightChange = { [weak self] rowID, height in self?.remeasure(rowID: rowID, reported: height) }
                // The comment's own buttons sit under the card, undimmed.
                if case .detail(.commentActions) = hosted { dimmed = false }
            }
        default:
            break
        }
        // Not yet with the agent: drawn like an outbox row.
        cell.contentView.alpha = dimmed ? 0.85 : 1
    }

    // MARK: Test seams

    var framesForTesting: ItemThreadFrames { frames }
    var itemsForTesting: [ItemThreadCellItem] { layout.items }
}

/// Hosts `ItemThreadController` in SwiftUI.
struct ItemThreadRepresentable: UIViewControllerRepresentable {
    let detail: ItemDetailView
    let proxy: ItemThreadProxy
    let onGeometryChange: (ItemThreadController.Geometry) -> Void

    func makeUIViewController(context: Context) -> ItemThreadController {
        let controller = ItemThreadController(factory: factory(context))
        controller.onGeometryChange = onGeometryChange
        proxy.controller = controller
        controller.loadViewIfNeeded()
        controller.update(factory: factory(context))
        return controller
    }

    func updateUIViewController(_ controller: ItemThreadController, context: Context) {
        controller.onGeometryChange = onGeometryChange
        proxy.controller = controller
        controller.update(factory: factory(context), inSwiftUIUpdate: true)
    }

    private func factory(_ context: Context) -> ItemThreadPieceFactory {
        ItemThreadPieceFactory(detail: detail, environment: TimelineHostedEnvironment(context.environment))
    }
}

/// The jump-to-bottom button's way to the controller.
@MainActor
final class ItemThreadProxy {
    weak var controller: ItemThreadController?
}

/// The item's detail surface with the native thread: the recycling list,
/// then the same rule, reply composer and ground as `ItemDetailView`.
struct ItemNativeThreadView: View {
    let detail: ItemDetailView
    @State private var geometry = ItemThreadController.Geometry()
    @State private var proxy = ItemThreadProxy()

    var body: some View {
        VStack(spacing: 0) {
            ItemThreadRepresentable(detail: detail, proxy: proxy) { geometry = $0 }
                .ignoresSafeArea(.container, edges: .top)
                .overlay(alignment: .bottomTrailing) {
                    if ItemDetailView.showsJumpToBottom(placed: geometry.placed, scrollable: geometry.scrollable,
                                                        atBottom: geometry.atBottom) {
                        JumpToBottomButton { proxy.controller?.scrollToBottom(animated: true) }
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: geometry.atBottom)
                .animation(.easeInOut(duration: 0.18), value: geometry.scrollable)
            Divider()
            detail.replyComposer()
        }
        .background(MatronTimelineBackground())
    }
}
