import UIKit
import SwiftUI
import MatronDesignSystem

/// Builds the SwiftUI pieces the native thread hosts, with the environment
/// a hosted view does not inherit across the UIKit boundary.
@MainActor
struct ItemThreadPieceFactory {
    var detail: ItemDetailView
    var environment: TimelineHostedEnvironment

    var router: TimelineLinkRouter {
        TimelineLinkRouter(openTrackerItem: environment.openTrackerItem,
                           openConversation: environment.openConversation,
                           openPageLink: environment.openPageLink)
    }

    func view(_ piece: ItemHostedPiece, sizeCategory: UIContentSizeCategory) -> AnyView {
        switch piece {
        case .detail(let piece):
            return AnyView(detail.showing(only: piece)
                .timelineHostedEnvironment(environment)
                .timelineDynamicTypeSize(sizeCategory))
        case .table(let table):
            return AnyView(ItemThreadTable(table: table, router: router)
                .timelineDynamicTypeSize(sizeCategory))
        }
    }
}

/// A card's markdown table: `Theme.matronItem`'s table (columns sized to
/// their text and capped, a sideways scroller, a hairline border on every
/// cell, a tint on the header row) over the native renderer's cell text.
struct ItemThreadTable: View {
    let table: MarkdownTable
    let router: TimelineLinkRouter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            ItemTableCellWidth(maxWidth: ItemTypography.tableCellMaxWidth) {
                                Text(MarkdownTableGrid.attributed(cell(row, column)))
                                    .multilineTextAlignment(textAlignment(column))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment(column))
                            .background(row == 0 ? Color.primary.opacity(0.05) : Color.clear)
                            .border(Color.primary.opacity(0.18), width: 0.5)
                        }
                    }
                }
            }
            .padding(1)
            .fixedSize(horizontal: false, vertical: true)
        }
        .environment(\.openURL, OpenURLAction { url in
            MainActor.assumeIsolated { router.route(url) }
            return .handled
        })
    }

    /// The header row reads semibold, as in the SwiftUI thread.
    private func cell(_ row: Int, _ column: Int) -> NSAttributedString {
        guard column < table.rows[row].count else { return NSAttributedString() }
        let text = table.rows[row][column]
        guard row == 0 else { return text }
        let header = NSMutableAttributedString(attributedString: text)
        header.enumerateAttribute(.font, in: NSRange(location: 0, length: header.length)) { value, range, _ in
            guard let font = value as? UIFont else { return }
            // Inline code keeps its monospaced face.
            let semibold: UIFont = font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
                ? .monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
                : .systemFont(ofSize: font.pointSize, weight: .semibold)
            header.addAttribute(.font, value: semibold, range: range)
        }
        return header
    }

    private func alignment(_ column: Int) -> MarkdownTable.Alignment {
        column < table.alignments.count ? table.alignments[column] : .left
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch alignment(column) {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func frameAlignment(_ column: Int) -> Alignment {
        switch alignment(column) {
        case .left: return .topLeading
        case .center: return .top
        case .right: return .topTrailing
        }
    }
}

/// Measures a hosted piece: its height at a width and the width it takes
/// there (a caption or an image hugs its content; a table fills the
/// width). One reused hosting controller; main thread only.
@MainActor
final class ItemPieceSizer {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))

    init() {
        host.sizingOptions = []
        host.view.backgroundColor = .clear
    }

    func size(of view: AnyView, maxWidth: CGFloat) -> CGSize {
        host.rootView = AnyView(view.fixedSize(horizontal: false, vertical: true))
        let size = host.sizeThatFits(in: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: min(ceil(size.width), maxWidth), height: ceil(size.height))
    }
}

/// One card of the native item thread: the card's ground, native text and
/// code for its body, and the SwiftUI pieces (caption, attachments, tables,
/// delivery line, buttons) hosted at the frames the render gives them.
final class ItemCardCell: UICollectionViewCell, UITextViewDelegate {
    private enum SlotKind: Equatable { case text, code, hosted }

    private let card = UIView()
    private var slots: [UIView] = []
    private var slotKinds: [SlotKind] = []
    private var spares: [SlotKind: [UIView]] = [:]
    private var appliedTexts: [NSAttributedString?] = []
    private(set) var render: ItemCardRender?
    private var router = TimelineLinkRouter()
    /// A hosted piece whose own height stopped matching its frame (an
    /// image with no recorded size arriving, a delivery line changing):
    /// the row's id, for the controller to measure again.
    var onPieceHeightChange: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.layer.cornerRadius = 10
        card.layer.shadowColor = UIColor.matronBubbleShadow.cgColor
        card.layer.shadowOpacity = 1
        card.layer.shadowRadius = 2
        card.layer.shadowOffset = CGSize(width: 0, height: 1)
        contentView.addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(render: ItemCardRender, factory: ItemThreadPieceFactory) {
        self.render = render
        router = factory.router
        card.backgroundColor = render.content.mine ? .matronBubbleMe : .matronBubbleBot
        // Not yet with the agent: drawn like an outbox row.
        contentView.alpha = render.content.hasDelivery ? 0.85 : 1

        let kinds = render.pieces.map { Self.slotKind($0.kind) }
        if kinds != slotKinds { rebuildSlots(kinds) }
        for (index, piece) in render.pieces.enumerated() {
            switch piece.kind {
            case .text(let text):
                guard let textView = slots[index] as? UITextView else { continue }
                if appliedTexts[index] !== text {
                    textView.attributedText = text
                    appliedTexts[index] = text
                }
            case .code(let language, let code):
                (slots[index] as? CodeBlockSegmentView)?.configure(language: language, code: code, style: render.style.code)
            case .hosted(let hosted):
                let expected = piece.frame.height
                let rowID = render.content.row.id
                let view = factory.view(hosted, sizeCategory: render.style.sizeCategory)
                (slots[index] as? (UIView & UIContentView))?.configuration = TimelineHosting.configuration(AnyView(
                    view.fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { [weak self] height in
                            self?.report(height: height, expected: expected, rowID: rowID)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)))
            }
        }
        setNeedsLayout()
    }

    private func report(height: CGFloat, expected: CGFloat, rowID: String) {
        guard abs(ceil(height) - expected) > 0.5, render?.content.row.id == rowID else { return }
        // Never re-enter the collection view's layout pass from inside it.
        DispatchQueue.main.async { [weak self] in
            guard self?.render?.content.row.id == rowID else { return }
            self?.onPieceHeightChange?(rowID)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let render else { return }
        card.frame = render.cardFrame
        card.layer.shadowPath = UIBezierPath(roundedRect: card.bounds, cornerRadius: 10).cgPath
        for (view, piece) in zip(slots, render.pieces) { view.frame = piece.frame }
    }

    private static func slotKind(_ kind: ItemCardRender.Kind) -> SlotKind {
        switch kind {
        case .text: return .text
        case .code: return .code
        case .hosted: return .hosted
        }
    }

    private func rebuildSlots(_ kinds: [SlotKind]) {
        var attached: [SlotKind: [UIView]] = [:]
        for (view, kind) in zip(slots, slotKinds) { attached[kind, default: []].append(view) }
        slots = kinds.map { kind -> UIView in
            if var views = attached[kind], !views.isEmpty {
                let view = views.removeFirst()
                attached[kind] = views
                return view
            }
            if var pool = spares[kind], let view = pool.popLast() {
                spares[kind] = pool
                view.isHidden = false
                return view
            }
            let view = makeSlot(kind)
            contentView.addSubview(view)
            return view
        }
        for (kind, views) in attached {
            for view in views {
                Self.reset(view)
                view.isHidden = true
                spares[kind, default: []].append(view)
            }
        }
        slotKinds = kinds
        appliedTexts = Array(repeating: nil, count: kinds.count)
    }

    private func makeSlot(_ kind: SlotKind) -> UIView {
        switch kind {
        case .text:
            let view = TimelineTextViewFactory.make()
            view.delegate = self
            return view
        case .code:
            return CodeBlockSegmentView()
        case .hosted:
            return TimelineHosting.makeContentView(TimelineHosting.placeholder)
        }
    }

    private static func reset(_ view: UIView) {
        if let textView = view as? UITextView {
            textView.resignFirstResponder()
            textView.selectedTextRange = nil
        } else if let code = view as? CodeBlockSegmentView {
            code.clearSelectionForReuse()
        } else if let hosted = view as? (UIView & UIContentView) {
            hosted.configuration = TimelineHosting.placeholder
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        slots.forEach(Self.reset)
        appliedTexts = Array(repeating: nil, count: appliedTexts.count)
        render = nil
        onPieceHeightChange = nil
        router = TimelineLinkRouter()
    }

    // MARK: Links

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                  defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content, !TimelineLinkRouter.isSystemLink(url) else { return defaultAction }
        let router = router
        return UIAction { _ in router.route(url) }
    }

    // MARK: Test seams

    var slotsForTesting: [UIView] { slots }
    var cardForTesting: UIView { card }
}
