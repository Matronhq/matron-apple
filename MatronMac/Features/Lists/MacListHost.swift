import AppKit
import MatronModels
import QuartzCore
import os

/// How a list row is drawn. Each kind is one `NSTableView` reuse
/// identifier: a recycled cell is only ever handed back to rows of its
/// own kind.
enum MacListCellKind: Hashable {
    /// A hand-built `NSTableCellView` (high-count, high-churn rows).
    case native(NSUserInterfaceItemIdentifier)
    /// A cell drawn by SwiftUI (`MacHostedRowView`): rare rows such as
    /// empty states and "Show more".
    case hosted(NSUserInterfaceItemIdentifier)

    var identifier: NSUserInterfaceItemIdentifier {
        switch self {
        case .native(let identifier), .hosted(let identifier): return identifier
        }
    }
}

/// The table's look.
enum MacListStyle {
    /// An ordinary list on the window background.
    case plain
    /// A sidebar list: `.sourceList` with a clear background, so the
    /// split view sidebar's vibrancy shows through.
    case sourceList
}

/// What a list surface supplies to `MacListHost`: how its rows look,
/// measure, read to VoiceOver, and what they do. The rows themselves come
/// from the `ListPublication`s the host is given; the provider never
/// mirrors the index.
@MainActor
protocol MacListRows: AnyObject {
    associatedtype Row: Identifiable & Equatable & Sendable where Row.ID: Sendable

    /// The cell kind `row` is drawn with.
    func cellKind(for row: Row) -> MacListCellKind
    /// A new cell of `kind`. The host sets its reuse identifier.
    func makeCell(_ kind: MacListCellKind) -> NSTableCellView
    /// Shows `row` in `cell` (a cell of `row`'s kind, fresh or reused).
    /// Must be idempotent and cheap: it runs on mount, on every content
    /// change of a mounted row, and on the minute tick for visible rows.
    func configure(_ cell: NSTableCellView, with row: Row)

    /// Every row's height when the list is fixed-height (the sidebar);
    /// `nil` (the default) asks `height(for:width:)`.
    var fixedRowHeight: CGFloat? { get }
    /// `row`'s exact height at column width `width`. The host caches it
    /// by (id, content, width), and the table asks for every row's height
    /// up front, so it must not lay out a view.
    func height(for row: Row, width: CGFloat) -> CGFloat

    /// One label for the whole row ("title, snippet, 2 unread, 5 minutes
    /// ago"); `nil` leaves the cell's own accessibility as it is.
    func accessibilityLabel(for row: Row) -> String?
    /// Type-select text (NSTableView's `typeSelectStringFor`); `nil` (the
    /// default) leaves the row out of type-select.
    func typeSelectString(for row: Row) -> String?
    /// Whether `row` can be selected (by a click or the keyboard); `false`
    /// for a row that is only a button, such as "Show more". Default true.
    func canSelect(_ row: Row) -> Bool

    /// A section's header title: a group row above the section's rows.
    /// `nil` (the default) shows no header. Empty sections never show one.
    func sectionHeaderTitle(_ key: String) -> String?
    /// The header row's height.
    func sectionHeaderHeight(_ key: String) -> CGFloat
    /// The header title's inset from the cell's leading edge, and from its
    /// bottom edge.
    var sectionHeaderInsets: (leading: CGFloat, bottom: CGFloat) { get }
    /// Space above every header but the list's first, added to its height.
    var sectionSpacing: CGFloat { get }
    /// Whether a header draws a hairline along its bottom, inset like its
    /// title on both sides.
    var sectionHeaderHasSeparator: Bool { get }

    /// The context menu's items for `ids`: the clicked row, or the whole
    /// selection when the clicked row is in it, in table order. Never
    /// called for a click on empty space or on a header.
    func menuItems(for ids: [Row.ID]) -> [NSMenuItem]
    /// Return, Enter or a double-click, with the selection (or the
    /// double-clicked row) in table order.
    func activate(_ ids: [Row.ID])

    // MARK: Drag (opt-in)

    /// The pasteboard types the table accepts drops of; `[]` (the
    /// default) registers none.
    var draggedTypes: [NSPasteboard.PasteboardType] { get }
    /// `row`'s drag item; `nil` (the default) makes it not draggable.
    func pasteboardWriter(for row: Row) -> NSPasteboardWriting?
    /// Whether a drop may land before the row at `path` (a row past a
    /// section's last row means the end of that section).
    func validateDrop(_ info: NSDraggingInfo, at path: ListPath) -> NSDragOperation
    func acceptDrop(_ info: NSDraggingInfo, at path: ListPath) -> Bool
}

extension MacListRows {
    var fixedRowHeight: CGFloat? { nil }
    func accessibilityLabel(for row: Row) -> String? { nil }
    func typeSelectString(for row: Row) -> String? { nil }
    func canSelect(_ row: Row) -> Bool { true }
    func sectionHeaderTitle(_ key: String) -> String? { nil }
    func sectionHeaderHeight(_ key: String) -> CGFloat { 28 }
    var sectionHeaderInsets: (leading: CGFloat, bottom: CGFloat) { (8, 4) }
    var sectionSpacing: CGFloat { 0 }
    var sectionHeaderHasSeparator: Bool { false }
    func menuItems(for ids: [Row.ID]) -> [NSMenuItem] { [] }
    var draggedTypes: [NSPasteboard.PasteboardType] { [] }
    func pasteboardWriter(for row: Row) -> NSPasteboardWriting? { nil }
    func validateDrop(_ info: NSDraggingInfo, at path: ListPath) -> NSDragOperation { [] }
    func acceptDrop(_ info: NSDraggingInfo, at path: ListPath) -> Bool { false }
}

/// Where each section of a sectioned list sits in a flat table whose
/// section headers are rows of their own (group rows), and in the flat
/// row array of a `ListPublication` (which has no headers).
struct MacListLayout: Equatable {
    /// Per section: whether it has a header row.
    private(set) var hasHeader: [Bool] = []
    /// Per section: its first table row (its header's, when it has one).
    private(set) var tableStart: [Int] = []
    /// Per section: its first row's index in the publication's rows.
    private(set) var rowStart: [Int] = []
    /// Per section: its row count.
    private(set) var counts: [Int] = []
    private(set) var tableRowCount = 0
    /// Rows, headers not counted.
    private(set) var rowCount = 0

    init() {}

    init(counts: [Int], hasHeader: [Bool]) {
        precondition(counts.count == hasHeader.count)
        self.counts = counts
        self.hasHeader = hasHeader
        tableStart.reserveCapacity(counts.count)
        rowStart.reserveCapacity(counts.count)
        var table = 0, rows = 0
        for (count, header) in zip(counts, hasHeader) {
            tableStart.append(table)
            rowStart.append(rows)
            table += count + (header ? 1 : 0)
            rows += count
        }
        tableRowCount = table
        rowCount = rows
    }

    /// The table row of `path`, if the path is in range.
    func tableRow(for path: ListPath) -> Int? {
        guard counts.indices.contains(path.section), path.row >= 0, path.row < counts[path.section] else {
            return nil
        }
        return tableStart[path.section] + (hasHeader[path.section] ? 1 : 0) + path.row
    }

    /// `path`'s index in the publication's flat rows (no range check
    /// beyond the section's).
    func rowIndex(for path: ListPath) -> Int { rowStart[path.section] + path.row }

    /// The section a table row falls in, and the row within it (`nil` for
    /// the section's header row).
    func location(ofTableRow row: Int) -> (section: Int, row: Int?)? {
        guard row >= 0, row < tableRowCount else { return nil }
        var low = 0, high = tableStart.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if tableStart[mid] <= row { low = mid } else { high = mid - 1 }
        }
        // Empty sections share a start with the next one: take the last
        // section starting at or before `row` that actually holds it.
        let offset = row - tableStart[low]
        if hasHeader[low] {
            return offset == 0 ? (low, nil) : (low, offset - 1)
        }
        return (low, offset)
    }

    /// The insertion point a drop "above" table row `row` means:
    /// `(section, index)`, where `index == count` is the section's end.
    /// Above a header is the end of the shown section before it, and past
    /// the last row the end of the last shown one: an empty section shows
    /// nothing, so a drop never lands in it.
    func insertionPath(aboveTableRow row: Int) -> ListPath? {
        guard !counts.isEmpty else { return nil }
        if row >= tableRowCount {
            let last = lastShownSection(before: counts.count) ?? counts.count - 1
            return ListPath(section: last, row: counts[last])
        }
        guard let location = location(ofTableRow: row) else { return nil }
        if let index = location.row { return ListPath(section: location.section, row: index) }
        guard let previous = lastShownSection(before: location.section) else {
            return ListPath(section: location.section, row: 0)
        }
        return ListPath(section: previous, row: counts[previous])
    }

    /// The last section before `section` that has rows.
    private func lastShownSection(before section: Int) -> Int? {
        counts[..<section].lastIndex { $0 > 0 }
    }
}

private let listHostLogger = Logger(subsystem: "chat.matron", category: "list-host")

/// The table behind every Mac list: keyboard activation, a window hook
/// for the minute tick, a width hook for heights, and test seams.
final class MacListTableView: NSTableView {
    /// Return or Enter.
    var onActivate: (() -> Void)?
    /// The table moved into or out of a window.
    var onWindowChange: ((NSWindow?) -> Void)?
    /// The table's width changed.
    var onWidthChange: (() -> Void)?

    /// Stands in for `clickedRow` (tests: a menu or a double-click on a row).
    var clickedRowOverrideForTesting: Int?
    override var clickedRow: Int { clickedRowOverrideForTesting ?? super.clickedRow }

    override func keyDown(with event: NSEvent) {
        // 36: Return, 76: keypad Enter. Modified Returns pass through.
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty, let onActivate {
            onActivate()
            return
        }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { onWidthChange?() }
    }
}

/// A section header: one line of secondary text, read as a heading.
final class MacListHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("MacListHost.header")
    /// `NSAccessibility.Role.heading` is macOS 26 SDK only; the raw value
    /// is what it names, and builds on every SDK.
    static let headingRole = NSAccessibility.Role(rawValue: "AXHeading")

    let label = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!
    private var bottom: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        bottom = label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        NSLayoutConstraint.activate([
            leading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            bottom,
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(Self.headingRole)
        label.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The title's inset from the leading and bottom edges.
    var insets: (leading: CGFloat, bottom: CGFloat) {
        get { (leading.constant, -bottom.constant) }
        set {
            if leading.constant != newValue.leading { leading.constant = newValue.leading }
            if bottom.constant != -newValue.bottom { bottom.constant = -newValue.bottom }
        }
    }

    /// A hairline along the bottom, inset like the title on both sides.
    var hasSeparator = false {
        didSet { if hasSeparator != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard hasSeparator else { return }
        let scale = window?.backingScaleFactor ?? 2
        let inset = insets.leading
        NSColor.separatorColor.setFill()
        NSRect(x: inset, y: bounds.height - 1 / scale, width: max(0, bounds.width - 2 * inset), height: 1 / scale).fill()
    }

    var title: String {
        get { label.stringValue }
        set {
            guard newValue != label.stringValue else { return }
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }
}

/// The shared AppKit list host: one manually driven, single-column,
/// view-based `NSTableView` that applies the `ListUpdate`s an index
/// publishes, touching only the rows an update names.
///
/// - **Updates.** `apply(_:)` takes a `ListPublication` (an update and the
///   rows it describes) and turns its paths into table steps at once:
///   removes, moves and inserts in flat table rows, where section headers
///   are rows of their own (`MacListLayout`). O(changed rows); nothing
///   walks the whole list. The steps of every publication since the last
///   frame then run as one pass (`MacFrameCoalescer`), through
///   `TableRowsApplier.perform(_:)` inside one `beginUpdates`. A reset (or
///   an update that does not fit the previous state) reloads instead.
/// - **Content** is read by position from the newest shown publication's
///   rows, so a pass never copies rows into a dictionary. Changed rows
///   that have a view re-render in place; the rest render when they mount.
/// - **Selection** is by id (`selection`) and survives every update: the
///   table carries selected rows through removes, moves and inserts, a
///   reload re-applies it by id, and a selected row that leaves the list
///   is selected again if it comes back. A selection set from outside
///   never calls `onSelectionChange`, and scrolls its first row into view;
///   the user's own selection never scrolls.
/// - **Heights** are the provider's fixed height, or answered from a cache
///   keyed by (id, content, width); a content change that moves a row's
///   height notes just that row.
/// - **Keyboard** is NSTableView's (arrows, page, home/end, type-select,
///   ⌘/⇧-click when `allowsMultipleSelection`), plus Return/Enter and
///   double-click calling `activate`.
/// - **Context menu:** one `NSMenu`, filled in `menuNeedsUpdate` from
///   `clickedRow` (`menuTargets(forClickedRow:)`).
/// - **Live data:** one minute timer per host reconfigures the visible
///   rows only ("5 minutes ago"); `reconfigure(_:)` re-renders named rows
///   whose look depends on state beside the row (silenced, "New").
@MainActor
final class MacListHost<Rows: MacListRows>: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate {
    typealias Row = Rows.Row
    typealias ID = Row.ID
    typealias Publication = ListPublication<Row, ID>

    /// A table row: a section header (by section key) or a model row.
    enum Key: Hashable {
        case header(String)
        case row(ID)
    }

    typealias Edit = TableRowsApplier<Key>.Edit

    let rows: Rows
    let style: MacListStyle
    /// Settable, so `MacListView` can follow a SwiftUI change of mode
    /// without a new view identity. Leaving multiple selection keeps the
    /// first selected row in table order.
    var allowsMultipleSelection: Bool {
        didSet {
            guard allowsMultipleSelection != oldValue, isViewLoaded else { return }
            tableView.allowsMultipleSelection = allowsMultipleSelection
            if !allowsMultipleSelection, selectedIDs.count > 1 {
                let kept = orderedSelection.first.map { Set([$0]) } ?? Set(selectedIDs.prefix(1))
                selectedIDs = kept
                applySelectionToTable(scroll: false)
                onSelectionChange?(kept)
            }
        }
    }
    let listAccessibilityIdentifier: String

    /// The user changed the selection (never called for a selection set
    /// through `selection`).
    var onSelectionChange: ((Set<ID>) -> Void)?

    let tableView = MacListTableView()
    let scrollView = NSScrollView()
    let contextMenu = NSMenu()
    let applier: TableRowsApplier<Key>

    // MARK: What the table shows

    /// The rows of the publication the table shows, section after section.
    private var shownRows: [Row] = []
    /// Where `shownRows`' sections sit in the table.
    private(set) var shownLayout = MacListLayout()

    // MARK: Published, not yet shown

    private var latestSections: [ListSection<ID>] = []
    private var latestLayout = MacListLayout()
    private var latestRows: [Row] = []
    /// A reload is due (a reset, or an update that did not fit).
    private var pendingReload = false
    /// Every publication's table steps since the last pass, in order.
    private var pendingEdits: [Edit] = []
    /// Ids whose mounted views must re-render (moved, changed, named).
    private var pendingReconfigure: Set<ID> = []
    /// Ids inserted since the last pass.
    private var pendingInserted: Set<ID> = []
    private var pendingWidthCheck = false
    /// A selection set from outside waits for its row to arrive.
    private var pendingScrollToSelection = false

    // MARK: Selection

    private var selectedIDs: Set<ID> = []
    /// The host is writing the table's selection: the table's
    /// notification is not the user's.
    private var isApplyingSelection = false
    /// A pass is editing the table.
    private(set) var isInPass = false

    // MARK: Heights

    private struct CachedHeight {
        var row: Row
        var width: CGFloat
        var height: CGFloat
    }

    private var heights: [ID: CachedHeight] = [:]
    private var measuredWidth: CGFloat = 0

    // MARK: Timers

    private var coalescer: MacFrameCoalescer?
    nonisolated(unsafe) private var minuteTimer: Timer?

    // MARK: Test seams

    private(set) var passCountForTesting = 0
    private(set) var minuteTickCountForTesting = 0
    private(set) var heightMeasureCountForTesting = 0
    private(set) var reloadCountForTesting = 0
    #if DEBUG
    /// Seconds the last pass spent inside the table's own edit or reload
    /// calls (AppKit re-framing and mounting rows), as against the host's
    /// work around them (perf harness).
    private(set) var lastPassTableSecondsForTesting: Double = 0
    #endif

    init(rows: Rows, style: MacListStyle = .plain, allowsMultipleSelection: Bool = false,
         accessibilityIdentifier: String) {
        self.rows = rows
        self.style = style
        self.allowsMultipleSelection = allowsMultipleSelection
        self.listAccessibilityIdentifier = accessibilityIdentifier
        self.applier = TableRowsApplier<Key>(label: "MacListHost[\(accessibilityIdentifier)]")
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        let timer = minuteTimer
        if Thread.isMainThread {
            timer?.invalidate()
        } else {
            nonisolated(unsafe) let orphan = timer
            DispatchQueue.main.async { orphan?.invalidate() }
        }
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MacListHost.column"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.intercellSpacing = .zero
        tableView.usesAutomaticRowHeights = false
        tableView.floatsGroupRows = false
        tableView.allowsMultipleSelection = allowsMultipleSelection
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = true
        tableView.focusRingType = .none
        switch style {
        case .plain:
            tableView.style = .plain
        case .sourceList:
            tableView.style = .sourceList
            tableView.backgroundColor = .clear
            scrollView.drawsBackground = false
        }
        tableView.setAccessibilityIdentifier(listAccessibilityIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        contextMenu.delegate = self
        tableView.menu = contextMenu
        let types = rows.draggedTypes
        if !types.isEmpty { tableView.registerForDraggedTypes(types) }
        tableView.onActivate = { [weak self] in self?.activateSelection() }
        tableView.onWindowChange = { [weak self] window in self?.windowChanged(window) }
        tableView.onWidthChange = { [weak self] in self?.widthMayHaveChanged() }

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        view = scrollView

        applier.tableView = tableView
        coalescer = MacFrameCoalescer(view: scrollView) { [weak self] in self?.runPass() }
        // Whatever arrived before the view existed is shown as a reload.
        pendingReload = true
        runPass()
    }

    // MARK: - Applying publications

    /// Takes `publication`'s changes now and shows them on the next frame.
    func apply(_ publication: Publication) {
        let update = publication.update
        if update.isReset || pendingReload || !isViewLoaded {
            // A reload shows the newest state whatever came before it.
            takeReload(update.sections, rows: publication.rows)
        } else if !fits(update, rowCount: publication.rows.count) {
            listHostLogger.breadcrumb(
                "list host \(listAccessibilityIdentifier): an update did not fit the previous state; reloading")
            takeReload(update.sections, rows: publication.rows)
        } else if update.hasChanges {
            take(update, rows: publication.rows)
        } else {
            return
        }
        requestPass()
    }

    /// Re-renders `ids`' mounted views on the next frame: for state the
    /// provider reads beside the row (a chat's notification setting, the
    /// "New" marker).
    func reconfigure(_ ids: some Sequence<ID>) {
        pendingReconfigure.formUnion(ids)
        requestPass()
    }

    /// Runs a pending pass now (tests, and callers that must see the table
    /// current before reading it).
    func flushPendingUpdates() {
        guard isViewLoaded, hasPendingWork else { return }
        runPass()
    }

    private var hasPendingWork: Bool {
        pendingReload || !pendingEdits.isEmpty || !pendingReconfigure.isEmpty || pendingWidthCheck
    }

    private func requestPass() {
        guard isViewLoaded else { return }
        coalescer?.request()
    }

    /// Whether `update` is an edit of `latestSections`.
    private func fits(_ update: ListUpdate<ID>, rowCount: Int) -> Bool {
        let old = latestSections, new = update.sections
        guard old.count == new.count, rowCount == update.rowCount else { return false }
        for (a, b) in zip(old, new) where a.key != b.key { return false }
        func inOld(_ p: ListPath) -> Bool {
            old.indices.contains(p.section) && p.row >= 0 && p.row < old[p.section].ids.count
        }
        func inNew(_ p: ListPath) -> Bool {
            new.indices.contains(p.section) && p.row >= 0 && p.row < new[p.section].ids.count
        }
        for path in update.removed where !inOld(path) { return false }
        for path in update.inserted where !inNew(path) { return false }
        for move in update.moved where !inOld(move.from) || !inNew(move.to) { return false }
        return true
    }

    private func takeReload(_ sections: [ListSection<ID>], rows newRows: [Row]) {
        pendingReload = true
        pendingEdits.removeAll()
        pendingInserted.removeAll()
        latestSections = sections
        latestLayout = layout(for: sections)
        latestRows = newRows
    }

    /// The table steps that bring the table from `latestSections` to
    /// `update.sections`: O(k log k) for k changed rows, plus O(m²) for m
    /// moved rows (one or two in practice).
    private func take(_ update: ListUpdate<ID>, rows newRows: [Row]) {
        let old = latestSections, new = update.sections
        let oldLayout = latestLayout
        let newLayout = layout(for: new)

        // Rows (and headers) that leave, in old table rows; rows (and
        // headers) that arrive, in new table rows.
        var removed: [Int] = []
        removed.reserveCapacity(update.removed.count)
        for path in update.removed {
            removed.append(oldLayout.tableRow(for: path)!)
            let id = old[path.section].ids[path.row]
            heights[id] = nil
            pendingReconfigure.remove(id)
            pendingInserted.remove(id)
        }
        var inserted: [(row: Int, key: Key)] = []
        inserted.reserveCapacity(update.inserted.count)
        for path in update.inserted {
            let id = new[path.section].ids[path.row]
            inserted.append((newLayout.tableRow(for: path)!, .row(id)))
            pendingInserted.insert(id)
        }
        for section in new.indices where oldLayout.hasHeader[section] != newLayout.hasHeader[section] {
            if oldLayout.hasHeader[section] {
                removed.append(oldLayout.tableStart[section])
            } else {
                inserted.append((newLayout.tableStart[section], .header(new[section].key)))
            }
        }
        removed.sort()
        inserted.sort { $0.row < $1.row }

        var edits: [Edit] = []
        edits.reserveCapacity(removed.count + inserted.count + update.moved.count)
        for row in removed.reversed() { edits.append(.remove(at: row)) }

        if !update.moved.isEmpty {
            // In survivor coordinates: the table once `removed` is gone
            // (source), and the new table without `inserted` (target).
            let insertedRows = inserted.map(\.row)
            var movers: [(source: Int, target: Int)] = update.moved.map { move in
                let from = oldLayout.tableRow(for: move.from)!
                let to = newLayout.tableRow(for: move.to)!
                pendingReconfigure.insert(new[move.to.section].ids[move.to.row])
                return (from - Self.countBelow(from, in: removed), to - Self.countBelow(to, in: insertedRows))
            }
            movers.sort { $0.target < $1.target }
            edits += Self.moveSteps(movers)
        }
        for (row, key) in inserted { edits.append(.insert(key, at: row)) }

        for id in update.reconfigured { pendingReconfigure.insert(id) }
        pendingEdits += edits
        latestSections = new
        latestLayout = newLayout
        latestRows = newRows
    }

    /// How many of `sorted` are below `value`.
    private static func countBelow(_ value: Int, in sorted: [Int]) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The `moveRow(at:to:)` steps that take each mover from `source` to
    /// `target` (survivor coordinates; `movers` sorted by target), where
    /// every other survivor keeps its order.
    ///
    /// Movers are placed in target order, each right after its target
    /// predecessor, which is already in place (a non-mover, or a mover
    /// placed before it), as `TableRowsApplier.moves(from:to:)` does; so
    /// every mover moves at most once. Positions are tracked
    /// arithmetically through the moves made so far, so nothing scans the
    /// list.
    static func moveSteps(_ movers: [(source: Int, target: Int)]) -> [Edit] {
        var done: [(from: Int, to: Int)] = []
        func current(_ position: Int) -> Int {
            var p = position
            for (from, to) in done {
                if p == from {
                    p = to
                } else if from < p, p <= to {
                    p -= 1
                } else if to <= p, p < from {
                    p += 1
                }
            }
            return p
        }
        var moverAtTarget: [Int: Int] = [:]
        for (index, mover) in movers.enumerated() { moverAtTarget[mover.target] = index }
        let sources = movers.map(\.source).sorted()
        var steps: [Edit] = []
        for (index, mover) in movers.enumerated() {
            let from = current(mover.source)
            let to: Int
            if mover.target == 0 {
                to = 0
            } else {
                let predecessor: Int
                if let other = moverAtTarget[mover.target - 1] {
                    predecessor = current(movers[other].source)
                } else {
                    // A non-mover: its rank among non-movers is the same in
                    // both orders. Movers with a smaller target are exactly
                    // the ones placed before this one.
                    var source = mover.target - 1 - index
                    for hole in sources {
                        if hole <= source { source += 1 } else { break }
                    }
                    predecessor = current(source)
                }
                to = from > predecessor ? predecessor + 1 : predecessor
            }
            guard from != to else { continue }
            steps.append(.move(from: from, to: to))
            done.append((from, to))
        }
        return steps
    }

    private func layout(for sections: [ListSection<ID>]) -> MacListLayout {
        MacListLayout(counts: sections.map(\.ids.count),
                      hasHeader: sections.map { !$0.ids.isEmpty && rows.sectionHeaderTitle($0.key) != nil })
    }

    private func flatKeys(_ sections: [ListSection<ID>], _ layout: MacListLayout) -> [Key] {
        var keys: [Key] = []
        keys.reserveCapacity(layout.tableRowCount)
        for (index, section) in sections.enumerated() {
            if layout.hasHeader[index] { keys.append(.header(section.key)) }
            for id in section.ids { keys.append(.row(id)) }
        }
        return keys
    }

    // MARK: - The pass

    /// Brings the table to the newest publication: once per frame at most.
    private func runPass() {
        // A frame after a flush finds nothing to do.
        guard isViewLoaded, hasPendingWork else { return }
        passCountForTesting += 1
        isInPass = true
        defer { isInPass = false }

        let reload = pendingReload
        let edits = pendingEdits
        let reconfigure = pendingReconfigure
        let inserted = pendingInserted
        let widthCheck = pendingWidthCheck
        pendingReload = false
        pendingEdits = []
        pendingReconfigure = []
        pendingInserted = []
        pendingWidthCheck = false

        // The table asks for what it shows only after the edits (inside
        // `endUpdates`), so the content switches first.
        shownRows = latestRows
        shownLayout = latestLayout
        if shownRows.count != shownLayout.rowCount {
            listHostLogger.breadcrumb(
                "list host \(listAccessibilityIdentifier): \(shownRows.count) rows for \(shownLayout.rowCount) ids")
        }

        if reload {
            reloadCountForTesting += 1
            if heights.count > shownLayout.rowCount * 2 { heights.removeAll(keepingCapacity: true) }
            measuredWidth = columnWidth
            let keys = flatKeys(latestSections, latestLayout)
            timingTable { applier.reloadData(keys) }
        } else {
            let firstBefore = applier.ids.first
            timingTable { applier.perform(edits) }
            if !reconfigure.isEmpty { reconfigureRows(reconfigure) }
            if rows.sectionSpacing != 0 { noteFirstRowChange(from: firstBefore) }
        }
        if widthCheck { noteAllHeightsIfWidthChanged() }
        reconcileSelection(after: reload, inserted: inserted)
    }

    @inline(__always)
    private func timingTable(_ body: () -> Void) {
        #if DEBUG
        let start = CACurrentMediaTime()
        body()
        lastPassTableSecondsForTesting = CACurrentMediaTime() - start
        #else
        body()
        #endif
    }

    /// Re-renders the mounted rows among `ids` in place (O(mounted rows));
    /// a row whose cell kind changed reloads. Then notes the rows among
    /// `ids` whose new content changed their height (variable-height lists).
    private func reconfigureRows(_ ids: Set<ID>) {
        let variable = rows.fixedRowHeight == nil
        var reloadRows = IndexSet()
        var heightRows = IndexSet()
        var mounted: Set<ID> = []
        tableView.enumerateAvailableRowViews { rowView, tableRow in
            guard case .row(let id)? = applier.id(atTableRow: tableRow), ids.contains(id),
                  let row = content(atTableRow: tableRow) else { return }
            mounted.insert(id)
            if variable, heightChanged(row) { heightRows.insert(tableRow) }
            guard let cell = rowView.view(atColumn: 0) as? NSTableCellView,
                  cell.identifier == rows.cellKind(for: row).identifier else {
                reloadRows.insert(tableRow)
                return
            }
            configure(cell, with: row, rowView: rowView)
        }
        if !reloadRows.isEmpty {
            applier.assertOutsideDelegate("reloadData(forRowIndexes:)")
            tableView.reloadData(forRowIndexes: reloadRows, columnIndexes: IndexSet(integer: 0))
        }
        if variable, mounted.count < ids.count {
            heightRows.formUnion(offscreenRowsWithNewHeights(ids.subtracting(mounted)))
        }
        applier.noteHeightOfRows(heightRows)
    }

    /// A header's height counts `sectionSpacing` unless it is the list's
    /// first row: when the first row changed, the header that was first,
    /// and the one that is now, are re-measured.
    private func noteFirstRowChange(from before: Key?) {
        let ids = applier.ids
        guard let first = ids.first, first != before else { return }
        var changed = IndexSet()
        if case .header = first { changed.insert(0) }
        if let before, case .header = before, let index = ids.firstIndex(of: before) { changed.insert(index) }
        applier.noteHeightOfRows(changed)
    }

    /// Whether `row`'s content changed its cached height (re-measured).
    private func heightChanged(_ row: Row) -> Bool {
        guard let before = heights[row.id]?.height else { return false }
        return height(of: row) != before
    }

    /// The table rows of the changed rows in `ids` that have no view, whose
    /// new content changed their height. The update names them by id only,
    /// so this walks the shown order once, stopping when all are found:
    /// variable-height lists only, and only when off-screen rows changed.
    private func offscreenRowsWithNewHeights(_ wanted: Set<ID>) -> IndexSet {
        var found = 0
        var changed = IndexSet()
        var flat = 0
        walk: for (section, ids) in latestSections.map(\.ids).enumerated() {
            for (index, id) in ids.enumerated() {
                defer { flat += 1 }
                guard wanted.contains(id) else { continue }
                found += 1
                if heightChanged(shownRows[flat]),
                   let tableRow = shownLayout.tableRow(for: ListPath(section: section, row: index)) {
                    changed.insert(tableRow)
                }
                if found == wanted.count { break walk }
            }
        }
        return changed
    }

    private func configure(_ cell: NSTableCellView, with row: Row, rowView: NSTableRowView?) {
        rows.configure(cell, with: row)
        guard let label = rows.accessibilityLabel(for: row) else { return }
        cell.setAccessibilityLabel(label)
        rowView?.setAccessibilityLabel(label)
    }

    // MARK: - Content

    /// The row the table shows at `tableRow` (`nil` for headers).
    private func content(atTableRow tableRow: Int) -> Row? {
        guard let location = shownLayout.location(ofTableRow: tableRow), let index = location.row else { return nil }
        let flat = shownLayout.rowStart[location.section] + index
        guard shownRows.indices.contains(flat) else { return nil }
        let row = shownRows[flat]
        #if DEBUG
        if case .row(let id)? = applier.id(atTableRow: tableRow) {
            assert(row.id == id, "the shown rows and the table disagree at row \(tableRow)")
        }
        #endif
        return row
    }

    // MARK: - Heights

    private var columnWidth: CGFloat { tableView.tableColumns.first?.width ?? tableView.bounds.width }

    private func height(atTableRow tableRow: Int, id: ID) -> CGFloat {
        if let fixed = rows.fixedRowHeight { return fixed }
        guard let row = content(atTableRow: tableRow) else { return heights[id]?.height ?? 1 }
        return height(of: row)
    }

    private func height(of row: Row) -> CGFloat {
        let width = columnWidth
        if let cached = heights[row.id], cached.width == width, cached.row == row { return cached.height }
        heightMeasureCountForTesting += 1
        let height = max(1, rows.height(for: row, width: width))
        heights[row.id] = CachedHeight(row: row, width: width, height: height)
        return height
    }

    private func widthMayHaveChanged() {
        guard rows.fixedRowHeight == nil, isViewLoaded else { return }
        pendingWidthCheck = true
        requestPass()
    }

    private func noteAllHeightsIfWidthChanged() {
        let width = columnWidth
        guard width != measuredWidth else { return }
        measuredWidth = width
        applier.noteHeightOfRows(IndexSet(integersIn: 0..<tableView.numberOfRows))
    }

    // MARK: - Selection

    /// The selected ids. Setting it is a selection from outside: it never
    /// calls `onSelectionChange`, and scrolls its first row into view.
    var selection: Set<ID> {
        get { selectedIDs }
        set { setSelection(newValue, fromOutside: true) }
    }

    /// The selected ids the table shows, in table order.
    var orderedSelection: [ID] {
        tableView.selectedRowIndexes.compactMap { rowID(atTableRow: $0) }
    }

    func setSelection(_ ids: Set<ID>, fromOutside: Bool) {
        guard ids != selectedIDs else { return }
        selectedIDs = ids
        // A newer selection replaces an outside one still waiting for its
        // row; only an outside selection scrolls.
        if !fromOutside { pendingScrollToSelection = false }
        guard isViewLoaded else {
            pendingScrollToSelection = fromOutside
            return
        }
        applySelectionToTable(scroll: fromOutside)
    }

    /// The model id at a table row (`nil` for headers and out of range).
    func rowID(atTableRow row: Int) -> ID? {
        if case .row(let id)? = applier.id(atTableRow: row) { return id }
        return nil
    }

    /// The table row of `id`, if the table holds it.
    func tableRow(of id: ID) -> Int? { applier.tableRow(of: .row(id)) }

    /// The row content the table shows for `id`.
    func row(for id: ID) -> Row? { tableRow(of: id).flatMap(content(atTableRow:)) }

    private func applySelectionToTable(scroll: Bool) {
        var indexes = IndexSet()
        var missing = false
        for id in selectedIDs {
            if let row = applier.tableRow(of: .row(id)) { indexes.insert(row) } else { missing = true }
        }
        if !allowsMultipleSelection, let first = indexes.first {
            indexes = IndexSet(integer: first)
            // A single-selection list given several ids keeps the one it
            // shows, and says so: reported after the current turn, since
            // this can run inside a SwiftUI update.
            if selectedIDs.count > 1, let kept = rowID(atTableRow: first) {
                selectedIDs = [kept]
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.selectedIDs == [kept] else { return }
                    self.onSelectionChange?([kept])
                }
            }
        }
        if tableView.selectedRowIndexes != indexes {
            isApplyingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
        }
        if scroll {
            if let first = indexes.first { tableView.scrollRowToVisible(first) }
            pendingScrollToSelection = missing
        }
    }

    /// After a pass. The table carries its selected rows through removes,
    /// moves and inserts; a reload, a selected id arriving, or an outside
    /// selection still waiting for its row needs it re-applied by id.
    private func reconcileSelection(after reload: Bool, inserted: Set<ID>) {
        guard !selectedIDs.isEmpty || !tableView.selectedRowIndexes.isEmpty else { return }
        if reload || pendingScrollToSelection || !selectedIDs.isDisjoint(with: inserted) {
            applySelectionToTable(scroll: pendingScrollToSelection)
            return
        }
        // O(selected rows): the table shows only selected ids.
        if !Set(orderedSelection).isSubset(of: selectedIDs) { applySelectionToTable(scroll: false) }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, !isInPass else { return }
        let ids = Set(orderedSelection)
        guard ids != selectedIDs else { return }
        selectedIDs = ids
        // The user's selection replaces an outside one still waiting for
        // its row, so a later pass must not scroll to it.
        pendingScrollToSelection = false
        onSelectionChange?(ids)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        applier.delegateCall { content(atTableRow: row).map(rows.canSelect) ?? false }
    }

    // MARK: - Activation and menus

    /// Return / Enter: the selection, in table order.
    func activateSelection() {
        let ids = orderedSelection
        guard !ids.isEmpty else { return }
        rows.activate(ids)
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        let ids = menuTargets(forClickedRow: tableView.clickedRow)
        guard !ids.isEmpty else { return }
        rows.activate(ids)
    }

    /// What a click on `clickedRow` acts on: the whole selection when the
    /// row is in it, the row alone when it is not, nothing on empty space
    /// (`-1`) or a header.
    func menuTargets(forClickedRow clickedRow: Int) -> [ID] {
        guard clickedRow >= 0, let id = rowID(atTableRow: clickedRow) else { return [] }
        if tableView.selectedRowIndexes.contains(clickedRow) { return orderedSelection }
        return [id]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let targets = menuTargets(forClickedRow: tableView.clickedRow)
        guard !targets.isEmpty else { return }
        for item in rows.menuItems(for: targets) {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    // MARK: - Minute tick

    private func windowChanged(_ window: NSWindow?) {
        minuteTimer?.invalidate()
        minuteTimer = nil
        guard window != nil else { return }
        // On the minute, so every host's "5 minutes ago" turns together.
        let now = Date().timeIntervalSinceReferenceDate
        let next = Date(timeIntervalSinceReferenceDate: (now / 60).rounded(.down) * 60 + 60)
        let timer = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.minuteTick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    var hasMinuteTimerForTesting: Bool { minuteTimer?.isValid == true }

    /// Re-renders the visible rows (relative times); the others render
    /// when they mount.
    func minuteTick() {
        minuteTickCountForTesting += 1
        guard isViewLoaded, !isInPass else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for tableRow in visible.location..<(visible.location + visible.length) {
            guard let row = content(atTableRow: tableRow),
                  let rowView = tableView.rowView(atRow: tableRow, makeIfNecessary: false),
                  let cell = rowView.view(atColumn: 0) as? NSTableCellView,
                  cell.identifier == rows.cellKind(for: row).identifier else { continue }
            configure(cell, with: row, rowView: rowView)
        }
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { applier.ids.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        applier.delegateCall {
            switch applier.id(atTableRow: row) {
            case .header(let key)?: return rows.sectionHeaderHeight(key) + (row > 0 ? rows.sectionSpacing : 0)
            case .row(let id)?: return height(atTableRow: row, id: id)
            case nil: return 1
            }
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        applier.delegateCall {
            if case .header? = applier.id(atTableRow: row) { return true }
            return false
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        applier.delegateCall {
            switch applier.id(atTableRow: row) {
            case .header(let key)?:
                let header = tableView.makeView(withIdentifier: MacListHeaderCell.identifier, owner: nil)
                    as? MacListHeaderCell ?? MacListHeaderCell(frame: .zero)
                header.title = rows.sectionHeaderTitle(key) ?? ""
                header.insets = rows.sectionHeaderInsets
                header.hasSeparator = rows.sectionHeaderHasSeparator
                return header
            case .row?:
                guard let content = content(atTableRow: row) else { return nil }
                let kind = rows.cellKind(for: content)
                let cell = tableView.makeView(withIdentifier: kind.identifier, owner: nil) as? NSTableCellView
                    ?? {
                        let cell = rows.makeCell(kind)
                        cell.identifier = kind.identifier
                        return cell
                    }()
                configure(cell, with: content, rowView: nil)
                return cell
            case nil:
                return nil
            }
        }
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        applier.delegateCall {
            switch applier.id(atTableRow: row) {
            case .header(let key)?:
                rowView.setAccessibilityLabel(rows.sectionHeaderTitle(key))
            case .row?:
                rowView.setAccessibilityLabel(content(atTableRow: row).flatMap { rows.accessibilityLabel(for: $0) })
            case nil:
                break
            }
        }
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        applier.delegateCall { content(atTableRow: row).flatMap { rows.typeSelectString(for: $0) } }
    }

    // MARK: Drag (opt-in): the items pane's task reorder.

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        applier.delegateCall { content(atTableRow: row).flatMap { rows.pasteboardWriter(for: $0) } }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        applier.delegateCall {
            // Over a row's middle is a drop above it: the list reorders,
            // it never drops onto a row.
            if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
            guard let path = shownLayout.insertionPath(aboveTableRow: row) else { return [] }
            return rows.validateDrop(info, at: path)
        }
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        // Not inside the guard: accepting a drop is where a client writes
        // its model; the update it publishes arrives on a later turn.
        guard dropOperation == .above, let path = shownLayout.insertionPath(aboveTableRow: row) else { return false }
        return rows.acceptDrop(info, at: path)
    }
}
