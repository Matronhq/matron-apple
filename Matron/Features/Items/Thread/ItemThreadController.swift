import UIKit
import SwiftUI
import MatronDesignSystem
import MatronModels

/// Whether the item thread is the native one (`ItemThreadController`) or
/// the SwiftUI stack. On in Debug builds, off in Release until it has been
/// tried; Settings ▸ Device ▸ Advanced switches it.
enum ItemThreadFlag {
    static let key = "items.thread.native"

    static var defaultValue: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}

/// Exact frames from `ItemThreadFrames`: no estimates, no self-sizing.
final class ItemThreadLayout: UICollectionViewLayout {
    var frames = ItemThreadFrames(heights: [])
    private var attributes: [UICollectionViewLayoutAttributes] = []

    override func prepare() {
        super.prepare()
        guard let collectionView else { return attributes = [] }
        let width = collectionView.bounds.width
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        attributes = (0..<min(count, frames.heights.count)).map { index in
            let attribute = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attribute.frame = frames.frame(at: index, width: width)
            return attribute
        }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: frames.contentHeight)
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

/// The item thread as a recycling list: only the rows on screen exist as
/// views, each card's text is measured once per width and cached, and the
/// rows' frames are exact from the first layout, so nothing moves as the
/// thread scrolls. The SwiftUI `ItemDetailView` draws the rows that are not
/// cards and every card's non-text pieces.
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
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.register(ItemCardCell.self, forCellWithReuseIdentifier: "card")
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
    func update(factory: ItemThreadPieceFactory) {
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
            measuredWidth = width
        }
        // Where the reader is: the first row on screen and how far its top
        // is from the viewport's.
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        var anchor: (id: String, offset: CGFloat)?
        if keep == .position, let index = layout.frames.firstRow(endingAfter: top), index < shownIDs.count {
            anchor = (shownIDs[index], layout.frames.minYs[index] - top)
        }

        measured = contents.map(measure)
        cache = cache.filter { entry in contents.contains { $0.row.id == entry.key } }
        let ids = contents.map(\.row.id)
        let sameRows = ids == shownIDs
        shownIDs = ids
        layout.frames = ItemThreadFrames(heights: measured.map(\.height))
        if sameRows {
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
            if let anchor, let index = ids.firstIndex(of: anchor.id) {
                setOffset(top: layout.frames.minYs[index] - anchor.offset)
            }
        case .nothing:
            break
        }
        reportGeometry()
    }

    private var shownIDs: [String] = []

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
    private func remeasure(rowID: String) {
        guard cache[rowID] != nil else { return }
        cache[rowID] = nil
        relayout(keeping: geometry.atBottom && geometry.scrollable ? .tail : .position)
    }

    // MARK: Scrolling

    private func placeInitiallyIfNeeded() {
        guard !geometry.placed, collectionView.bounds.width > 0, !contents.isEmpty, !measured.isEmpty else { return }
        geometry.placed = true
        if factory.detail.threadStartsAtBottom {
            scrollToBottom(animated: false)
            geometry.atBottom = true
        }
        onGeometryChange(geometry)
        reportGeometry()
    }

    private var maxOffsetY: CGFloat {
        let inset = collectionView.adjustedContentInset
        return max(-inset.top, layout.frames.contentHeight - collectionView.bounds.height + inset.bottom)
    }

    private func setOffset(top: CGFloat) {
        let inset = collectionView.adjustedContentInset
        let y = min(max(top - inset.top, -inset.top), maxOffsetY)
        collectionView.contentOffset = CGPoint(x: 0, y: y)
    }

    func scrollToBottom(animated: Bool) {
        collectionView.setContentOffset(CGPoint(x: 0, y: maxOffsetY), animated: animated)
        if !animated { reportGeometry() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportGeometry()
    }

    private func reportGeometry() {
        let inset = collectionView.adjustedContentInset
        let visibleHeight = collectionView.bounds.height - inset.top - inset.bottom
        var next = geometry
        next.scrollable = layout.frames.contentHeight > visibleHeight + 8
        next.atBottom = collectionView.contentOffset.y >= maxOffsetY - 8
        guard next != geometry else { return }
        let bottomChanged = next.atBottom != geometry.atBottom
        geometry = next
        onGeometryChange(next)
        if bottomChanged { factory.detail.reportBottomVisibility(next.atBottom) }
    }

    // MARK: Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        min(contents.count, measured.count)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let identifier: String
        switch measured[indexPath.item] {
        case .card: identifier = "card"
        case .hosted: identifier = "hosted"
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: identifier, for: indexPath)
        configure(cell, at: indexPath.item)
        return cell
    }

    private func configure(_ cell: UICollectionViewCell, at index: Int) {
        guard index < measured.count, index < contents.count else { return }
        switch measured[index] {
        case .card(let render):
            guard let cell = cell as? ItemCardCell else { return collectionView.reloadData() }
            cell.configure(render: render, factory: factory)
            cell.onPieceHeightChange = { [weak self] rowID in self?.remeasure(rowID: rowID) }
        case .hosted(let height):
            guard let cell = cell as? HostedRowCell else { return collectionView.reloadData() }
            let row = contents[index].row
            cell.configure(rowID: row.id, expectedHeight: height,
                           content: factory.view(.detail(.row(row)), sizeCategory: style.sizeCategory))
            cell.onHeightChange = { [weak self] rowID, _ in self?.remeasure(rowID: rowID) }
        }
    }

    // MARK: Test seams

    var framesForTesting: ItemThreadFrames { layout.frames }
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
        controller.update(factory: factory(context))
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
