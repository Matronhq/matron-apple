import AppKit
import MatronDesignSystem
import MatronModels

extension NSPasteboard.PasteboardType {
    /// A task dragged inside the items pane: its item id.
    static let matronItemsPaneTask = NSPasteboard.PasteboardType("chat.matron.items-pane.task")
}

/// The AppKit items pane list's `MacListRows`: native `MacItemRowCell`
/// rows in the pane's style and `MacPendingItemCell`s for unsent creates,
/// a header per section, the row menu (Open conversation, in the All
/// scope), and drag to reorder inside Tasks.
@MainActor
final class MacItemsPaneRows: MacListRows {
    typealias Row = MacItemsPaneRow

    static let itemKind = MacListCellKind.native(MacItemRowCell.identifier)
    static let pendingKind = MacListCellKind.native(MacPendingItemCell.identifier)

    /// `ItemsListView`'s inset `List`: 28 pt headers, 16 pt in, with a
    /// hairline under them and 20 pt between sections.
    static let headerHeight: CGFloat = 28
    static let headerSpacing: CGFloat = 20

    struct Actions {
        /// A click, Return, Enter or a double-click on an item: open it.
        var open: (TrackerItem) -> Void = { _ in }
        var openConversation: (String) -> Void = { _ in }
        /// A task dropped in Tasks: its id and its new index, counted
        /// without it.
        var move: (String, Int) -> Void = { _, _ in }
    }

    var actions = Actions()
    /// The Tasks section's item ids as shown, for a drop's source index.
    var taskIDs: () -> [String] = { [] }

    /// The shown rows' items by row id, for the menu and activation.
    private var itemsByRowID: [String: (item: TrackerItem, origin: String?)] = [:]

    init() {}

    static func presentation(origin: String?) -> MacItemRowCell.Presentation {
        MacItemRowCell.Presentation(style: .pane, origin: origin, isClosedTab: false, offersSeen: false)
    }

    func cellKind(for row: MacItemsPaneRow) -> MacListCellKind {
        row.item == nil ? Self.pendingKind : Self.itemKind
    }

    func makeCell(_ kind: MacListCellKind) -> NSTableCellView {
        kind == Self.pendingKind ? MacPendingItemCell(frame: .zero) : MacItemRowCell(frame: .zero)
    }

    func configure(_ cell: NSTableCellView, with row: MacItemsPaneRow) {
        switch row.content {
        case .item(let item, let origin):
            itemsByRowID[row.id] = (item, origin)
            (cell as? MacItemRowCell)?.configure(item, presentation: Self.presentation(origin: origin), now: Date())
        case .pending(let pending):
            (cell as? MacPendingItemCell)?.configure(pending)
        }
    }

    func height(for row: MacItemsPaneRow, width: CGFloat) -> CGFloat {
        switch row.content {
        case .item(let item, let origin):
            MacItemRowCell.height(for: item, presentation: Self.presentation(origin: origin), width: width)
        case .pending(let pending):
            MacPendingItemCell.height(for: pending, width: width)
        }
    }

    func accessibilityLabel(for row: MacItemsPaneRow) -> String? {
        switch row.content {
        case .item(let item, let origin):
            MacItemRowCell.accessibilityLabel(for: item, origin: origin, isClosedTab: false, now: Date())
        case .pending(let pending):
            MacPendingItemCell.accessibilityLabel(for: pending)
        }
    }

    func typeSelectString(for row: MacItemsPaneRow) -> String? {
        switch row.content {
        case .item(let item, _): item.title
        case .pending(let pending): pending.title
        }
    }

    /// A pending create has nothing to open yet.
    func canSelect(_ row: MacItemsPaneRow) -> Bool { row.item != nil }

    func sectionHeaderTitle(_ key: String) -> String? { MacItemsPaneSection(rawValue: key)?.title }
    func sectionHeaderHeight(_ key: String) -> CGFloat { Self.headerHeight }
    var sectionHeaderInsets: (leading: CGFloat, bottom: CGFloat) { (16, 7) }
    var sectionSpacing: CGFloat { Self.headerSpacing }
    var sectionHeaderHasSeparator: Bool { true }

    /// `ItemsListView`'s row menu: Open conversation, in the All scope.
    func menuItems(for ids: [String]) -> [NSMenuItem] {
        guard let id = ids.first, let (item, origin) = itemsByRowID[id], origin != nil else { return [] }
        let openConversation = actions.openConversation
        let convo = item.originConvoID
        return [MacActionMenuItem("Open conversation") { openConversation(convo) }]
    }

    func activate(_ ids: [String]) {
        guard let id = ids.first, let (item, _) = itemsByRowID[id] else { return }
        actions.open(item)
    }

    // MARK: Drag: reorder inside Tasks

    var draggedTypes: [NSPasteboard.PasteboardType] { [.matronItemsPaneTask] }

    func pasteboardWriter(for row: MacItemsPaneRow) -> NSPasteboardWriting? {
        guard row.section == .tasks, let item = row.item else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.id, forType: .matronItemsPaneTask)
        return pasteboardItem
    }

    /// The task a drag carries, when it came from this list.
    private func draggedTaskID(_ info: NSDraggingInfo) -> String? {
        guard let id = info.draggingPasteboard.string(forType: .matronItemsPaneTask), taskIDs().contains(id) else {
            return nil
        }
        return id
    }

    func validateDrop(_ info: NSDraggingInfo, at path: ListPath) -> NSDragOperation {
        path.section == MacItemsPaneSection.tasks.index && draggedTaskID(info) != nil ? .move : []
    }

    func acceptDrop(_ info: NSDraggingInfo, at path: ListPath) -> Bool {
        guard path.section == MacItemsPaneSection.tasks.index, let id = draggedTaskID(info),
              let from = taskIDs().firstIndex(of: id) else { return false }
        Self.drop(id, from: from, at: path.row, move: actions.move)
        return true
    }

    /// A drop above index `to` of the shown tasks, as `ItemsListView`'s
    /// `onMove` reports it: the new index without the moved task. A drop
    /// just above or below itself moves nothing.
    static func drop(_ id: String, from: Int, at to: Int, move: (String, Int) -> Void) {
        guard to != from, to != from + 1 else { return }
        move(id, to > from ? to - 1 : to)
    }
}

/// A create the outbox has not sent yet: `PendingItemRow` drawn by hand,
/// in the pane's row: the kind glyph (tertiary), the title on up to two
/// lines (secondary) and "Sending…" or "Failed — will retry" (red).
final class MacPendingItemCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("itemsPane.pending")
    static let sending = "Sending…"
    static let failed = "Failed — will retry"

    private(set) var row: ItemsListView.PendingRow?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(_ row: ItemsListView.PendingRow) {
        guard row != self.row else { return }
        self.row = row
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    struct Layout: Equatable {
        var height: CGFloat
        var glyph: NSRect
        var title: NSRect
        var titleLines: Int
        var caption: NSRect
    }

    private typealias M = MacItemRowCell.Metrics

    static func titleString(_ row: ItemsListView.PendingRow, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: row.title, attributes: [.font: MacItemRowCell.Fonts.title, .foregroundColor: color])
    }

    static func layout(for row: ItemsListView.PendingRow, width: CGFloat) -> Layout {
        let style = MacItemRowCell.Style.pane
        let top = style.vertical
        let textLeft = style.leading + M.glyphWidth + M.columnSpacing
        let textWidth = max(0, width - style.trailing - M.columnSpacing - textLeft)
        let lines = max(1, MacItemRowCell.titleLines(titleString(row, color: .labelColor), width: textWidth).count)
        let title = NSRect(x: textLeft, y: top, width: textWidth, height: CGFloat(lines) * M.titleLineHeight)
        let caption = NSRect(x: textLeft, y: title.maxY + M.lineSpacing, width: textWidth, height: M.captionLineHeight)
        let glyph = NSRect(x: style.leading, y: top + M.glyphTop, width: M.glyphWidth, height: M.glyphLineHeight)
        let height = max(caption.maxY, glyph.maxY) + style.vertical
        return Layout(height: height, glyph: glyph, title: title, titleLines: lines, caption: caption)
    }

    static func height(for row: ItemsListView.PendingRow, width: CGFloat) -> CGFloat {
        layout(for: row, width: width).height
    }

    static func accessibilityLabel(for row: ItemsListView.PendingRow) -> String {
        "\(row.title), \(row.isFailed ? "failed, will retry" : "sending")"
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let layout = Self.layout(for: row, width: bounds.width)
        if let glyph = MacItemRowCell.glyphImage(row.kind) {
            MacChatListCell.drawSymbol(glyph, color: .tertiaryLabelColor, in: layout.glyph)
        }
        let title = Self.titleString(row, color: .secondaryLabelColor)
        for (index, line) in MacItemRowCell.titleLines(title, width: layout.title.width).enumerated() {
            let frame = NSRect(x: layout.title.minX, y: layout.title.minY + CGFloat(index) * M.titleLineHeight,
                               width: layout.title.width, height: M.titleLineHeight)
            MacItemRowCell.draw(line, in: frame)
        }
        let caption = MacItemRowCell.captionString(row.isFailed ? Self.failed : Self.sending,
                                                   color: row.isFailed ? .systemRed : .secondaryLabelColor)
        MacChatListCell.drawLine(caption, in: layout.caption, lineHeight: M.captionLineHeight)
        let scale = window?.backingScaleFactor ?? 2
        NSColor.separatorColor.setFill()
        NSRect(x: layout.title.minX, y: bounds.height - 1 / scale,
               width: max(0, bounds.width - MacItemRowCell.Style.pane.trailing - layout.title.minX),
               height: 1 / scale).fill()
    }
}
