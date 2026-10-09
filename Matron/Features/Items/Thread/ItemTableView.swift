import UIKit
import MatronDesignSystem

/// Where a card's table goes: `Theme.matronItem`'s table worked out as
/// plain arithmetic. A column is as wide as its widest cell, a cell's text
/// capped at `ItemTypography.tableCellMaxWidth` before it wraps; a row is as
/// tall as its tallest cell; cells sit one point apart with a hairline
/// border each. A pure function of the table, so a card measures its tables
/// without building a view.
struct ItemTableLayout {
    static let cellPadding = CGSize(width: 8, height: 4)
    static let gap: CGFloat = 1
    private static let drawing: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    /// Every cell's text as it is drawn: the header row semibold.
    let texts: [[NSAttributedString]]
    let alignments: [MarkdownTable.Alignment]
    let columnXs: [CGFloat]
    let columnWidths: [CGFloat]
    let rowYs: [CGFloat]
    let rowHeights: [CGFloat]
    /// Each cell's text size inside its padding.
    let textSizes: [[CGSize]]
    let size: CGSize

    init(table: MarkdownTable) {
        let columns = table.columnCount
        var texts: [[NSAttributedString]] = []
        for (rowIndex, row) in table.rows.enumerated() {
            texts.append((0..<columns).map { column in
                let text = column < row.count ? row[column] : NSAttributedString()
                return rowIndex == 0 ? Self.header(text) : text
            })
        }
        let cap = ItemTypography.tableCellMaxWidth
        var widths = Array(repeating: CGFloat(0), count: columns)
        for row in texts {
            for (column, text) in row.enumerated() {
                let natural = ceil(text.boundingRect(with: CGSize(width: cap, height: .greatestFiniteMagnitude),
                                                     options: Self.drawing, context: nil).width)
                widths[column] = max(widths[column], min(natural, cap))
            }
        }
        var sizes: [[CGSize]] = []
        var heights: [CGFloat] = []
        for row in texts {
            var rowSizes: [CGSize] = []
            var height: CGFloat = 0
            for (column, text) in row.enumerated() {
                // An empty cell still holds a line.
                let measured = text.length > 0 ? text : NSAttributedString(string: " ", attributes: Self.lineAttributes(texts))
                let rect = measured.boundingRect(with: CGSize(width: widths[column], height: .greatestFiniteMagnitude),
                                                 options: Self.drawing, context: nil)
                let size = CGSize(width: min(ceil(rect.width), widths[column]), height: ceil(rect.height))
                rowSizes.append(size)
                height = max(height, size.height)
            }
            sizes.append(rowSizes)
            heights.append(height + 2 * Self.cellPadding.height)
        }
        var xs: [CGFloat] = []
        var x = Self.gap
        var cellWidths: [CGFloat] = []
        for width in widths {
            xs.append(x)
            let cellWidth = width + 2 * Self.cellPadding.width
            cellWidths.append(cellWidth)
            x += cellWidth + Self.gap
        }
        var ys: [CGFloat] = []
        var y = Self.gap
        for height in heights {
            ys.append(y)
            y += height + Self.gap
        }
        self.texts = texts
        self.alignments = (0..<columns).map { $0 < table.alignments.count ? table.alignments[$0] : .left }
        self.columnXs = xs
        self.columnWidths = cellWidths
        self.rowYs = ys
        self.rowHeights = heights
        self.textSizes = sizes
        self.size = CGSize(width: x, height: y)
    }

    func cellFrame(row: Int, column: Int) -> CGRect {
        CGRect(x: columnXs[column], y: rowYs[row], width: columnWidths[column], height: rowHeights[row])
    }

    /// Where a cell's text is drawn: at the top of its cell, placed across
    /// it by its column's alignment.
    func textFrame(row: Int, column: Int) -> CGRect {
        let cell = cellFrame(row: row, column: column).insetBy(dx: Self.cellPadding.width, dy: Self.cellPadding.height)
        let size = textSizes[row][column]
        let x: CGFloat
        switch alignments[column] {
        case .left: x = cell.minX
        case .center: x = cell.midX - size.width / 2
        case .right: x = cell.maxX - size.width
        }
        return CGRect(x: x, y: cell.minY, width: size.width, height: size.height)
    }

    func draw(row: Int, column: Int, in context: CGContext) {
        let cell = cellFrame(row: row, column: column)
        if row == 0 {
            context.setFillColor(UIColor.label.withAlphaComponent(0.05).cgColor)
            context.fill(cell)
        }
        context.setStrokeColor(UIColor.label.withAlphaComponent(0.18).cgColor)
        context.setLineWidth(0.5)
        context.stroke(cell.insetBy(dx: 0.25, dy: 0.25))
        texts[row][column].draw(with: textFrame(row: row, column: column), options: Self.drawing, context: nil)
    }

    /// The table as text: a row a line, its cells tab-separated. What
    /// "Copy table" puts on the pasteboard (it pastes into a spreadsheet as
    /// cells) and what VoiceOver reads.
    var plainText: String {
        texts.map { row in
            row.map { $0.string.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// The link under `point`, if a cell's text has one there.
    func link(at point: CGPoint) -> URL? {
        for row in texts.indices {
            for column in texts[row].indices {
                let frame = textFrame(row: row, column: column)
                guard frame.contains(point), texts[row][column].length > 0 else { continue }
                let (manager, container, storage) = Self.laidOut(texts[row][column], width: frame.width)
                let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
                var fraction: CGFloat = 0
                let glyph = manager.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
                guard manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                    .contains(local) else { return nil }
                return storage.attribute(.link, at: manager.characterIndexForGlyph(at: glyph), effectiveRange: nil) as? URL
            }
        }
        return nil
    }

    /// A link in a cell: what it says and where it is drawn.
    struct Link: Equatable {
        let row: Int
        let url: URL
        let text: String
        let frame: CGRect
    }

    /// Every link of the table in reading order, so VoiceOver can stop on
    /// each one. A link wrapped over lines takes the box round its lines.
    var links: [Link] {
        var links: [Link] = []
        for row in texts.indices {
            for column in texts[row].indices {
                let text = texts[row][column]
                guard text.length > 0 else { continue }
                let frame = textFrame(row: row, column: column)
                var laidOut: (manager: NSLayoutManager, container: NSTextContainer, storage: NSTextStorage)?
                text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                    guard let url = value as? URL else { return }
                    // Laid out once, and only for a cell that has a link.
                    let layout = laidOut ?? Self.laidOut(text, width: frame.width)
                    laidOut = layout
                    let glyphs = layout.manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    let box = layout.manager.boundingRect(forGlyphRange: glyphs, in: layout.container)
                    links.append(Link(row: row, url: url,
                                      text: text.attributedSubstring(from: range).string,
                                      frame: box.offsetBy(dx: frame.minX, dy: frame.minY)))
                }
            }
        }
        return links
    }

    private static func laidOut(_ text: NSAttributedString, width: CGFloat)
        -> (manager: NSLayoutManager, container: NSTextContainer, storage: NSTextStorage) {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return (manager, container, storage)
    }

    private static func header(_ text: NSAttributedString) -> NSAttributedString {
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

    /// The font an empty cell's line takes: the table's first.
    private static func lineAttributes(_ texts: [[NSAttributedString]]) -> [NSAttributedString.Key: Any] {
        for row in texts {
            for text in row where text.length > 0 { return text.attributes(at: 0, effectiveRange: nil) }
        }
        return [.font: UIFont.preferredFont(forTextStyle: .body)]
    }
}

/// A card's table drawn natively inside a sideways scroller. Its cells are
/// drawn in tiles, off the main thread and only where the table is on
/// screen, so a table scrolling in builds no SwiftUI views, a long one does
/// not hold the scroll up while every row is drawn, and a tall one is never
/// one huge bitmap. Links in cells open on a tap. VoiceOver reads it a row
/// at a time, and stops on each link after its row.
final class ItemTableView: UIView, UIContextMenuInteractionDelegate {
    /// A link of the table as VoiceOver meets it: activating it opens it.
    private final class LinkElement: UIAccessibilityElement {
        var open: (() -> Void)?

        override func accessibilityActivate() -> Bool {
            open?()
            return open != nil
        }
    }

    private final class Tiles: CATiledLayer {
        // Tiles appear as they are drawn; a fade would read as flicker.
        override class func fadeDuration() -> CFTimeInterval { 0 }
    }

    private final class Canvas: UIView {
        override class var layerClass: AnyClass { Tiles.self }

        /// Read on the tile threads: replaced whole, never mutated.
        var drawing: (layout: ItemTableLayout, traits: UITraitCollection)? {
            didSet {
                layer.contents = nil
                setNeedsDisplay()
                elements = nil
            }
        }

        var onOpenLink: ((URL) -> Void)?
        var copyTable: (() -> Void)?
        /// Built when accessibility first asks, so a table nobody reads
        /// with VoiceOver lays out none of its links.
        private var elements: [Any]?

        override var accessibilityElements: [Any]? {
            get {
                if let elements { return elements }
                guard let layout = drawing?.layout else { return nil }
                let links = layout.links
                var built: [Any] = []
                for row in layout.texts.indices {
                    let element = UIAccessibilityElement(accessibilityContainer: self)
                    element.accessibilityLabel = layout.texts[row]
                        .map { $0.string.replacingOccurrences(of: "\n", with: " ") }
                        .joined(separator: ", ")
                    element.accessibilityTraits = row == 0 ? [.staticText, .header] : .staticText
                    element.accessibilityFrameInContainerSpace = CGRect(x: 0, y: layout.rowYs[row],
                                                                        width: layout.size.width,
                                                                        height: layout.rowHeights[row])
                    element.accessibilityCustomActions = [
                        UIAccessibilityCustomAction(name: "Copy Table") { [weak self] _ in
                            self?.copyTable?()
                            return self?.copyTable != nil
                        },
                    ]
                    built.append(element)
                    for link in links where link.row == row {
                        let element = LinkElement(accessibilityContainer: self)
                        element.accessibilityLabel = link.text
                        element.accessibilityTraits = .link
                        element.accessibilityFrameInContainerSpace = link.frame
                        element.open = { [weak self] in self?.onOpenLink?(link.url) }
                        built.append(element)
                    }
                }
                elements = built
                return built
            }
            set { elements = newValue }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            contentScaleFactor = traitCollection.displayScale
            (layer as? CATiledLayer)?.tileSize = CGSize(width: 1024, height: 512)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        // Called on a tile thread, once per tile.
        override func draw(_ rect: CGRect) {
            guard let drawing, let context = UIGraphicsGetCurrentContext() else { return }
            let layout = drawing.layout
            // Dynamic colours resolve against the table's own appearance,
            // not whatever the tile thread last had.
            drawing.traits.performAsCurrent {
                for row in layout.rowYs.indices {
                    let rowFrame = CGRect(x: 0, y: layout.rowYs[row] - 1, width: layout.size.width,
                                          height: layout.rowHeights[row] + 2)
                    guard rowFrame.intersects(rect) else { continue }
                    for column in layout.columnXs.indices
                    where layout.cellFrame(row: row, column: column).insetBy(dx: -1, dy: -1).intersects(rect) {
                        layout.draw(row: row, column: column, in: context)
                    }
                }
            }
        }
    }

    private let scrollView = UIScrollView()
    private let canvas = Canvas()
    private var layout: ItemTableLayout?
    var onOpenLink: ((URL) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = false
        addSubview(scrollView)
        scrollView.addSubview(canvas)
        scrollView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        // The cells are drawn, not text views, so they cannot be selected:
        // a long press offers the whole table instead.
        addInteraction(UIContextMenuInteraction(delegate: self))
        canvas.onOpenLink = { [weak self] in self?.onOpenLink?($0) }
        canvas.copyTable = { [weak self] in
            guard let layout = self?.layout else { return }
            Pasteboard.copy(layout.plainText)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: ItemTableView, _) in
            guard let layout = self.layout else { return }
            self.canvas.drawing = (layout, self.traitCollection)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ layout: ItemTableLayout) {
        // The same table again (the thread refreshed round it): keep its
        // tiles and how far it is scrolled sideways.
        if let current = self.layout, current.texts == layout.texts, current.size == layout.size {
            self.layout = layout
            return
        }
        self.layout = layout
        canvas.frame = CGRect(origin: .zero, size: layout.size)
        canvas.drawing = (layout, traitCollection)
        scrollView.contentSize = layout.size
        scrollView.contentOffset = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
    }

    var scrollViewForTesting: UIScrollView { scrollView }
    var accessibilityElementsForTesting: [Any] { canvas.accessibilityElements ?? [] }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let layout, let url = layout.link(at: recognizer.location(in: scrollView)) else { return }
        onOpenLink?(url)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let layout else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [UIAction(title: "Copy Table", image: UIImage(systemName: "doc.on.doc")) { _ in
                Pasteboard.copy(layout.plainText)
            }])
        })
    }
}
