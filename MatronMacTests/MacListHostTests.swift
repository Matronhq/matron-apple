import XCTest
import AppKit
import SwiftUI
import QuartzCore
import MatronModels
@testable import MatronMac

// MARK: - Test-only rows provider

/// One test row: a title, a line count (its height: 20 pt a line) and
/// whether SwiftUI draws it.
struct TestListRow: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var lines = 1
    var hosted = false
}

/// A native cell showing a row's title.
final class TestListCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    private(set) var rowID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.frame = bounds
        label.autoresizingMask = [.width, .height]
        addSubview(label)
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ row: TestListRow) {
        rowID = row.id
        if label.stringValue != row.title { label.stringValue = row.title }
    }
}

/// The smallest `MacListRows`: native rows with a title, an optional
/// hosted kind, headers by section key, and a log of everything the host
/// asked of it.
@MainActor
final class TestListRows: MacListRows, HostedRowBodyProvider {
    static let nativeKind = MacListCellKind.native(NSUserInterfaceItemIdentifier("test.row"))
    static let hostedKind = MacListCellKind.hosted(NSUserInterfaceItemIdentifier("test.hosted"))

    var fixed: CGFloat?
    var headers: [String: String] = [:]
    /// Every `configure`, by row id, in order.
    var configured: [String] = []
    var activated: [[String]] = []
    var menuRequests: [[String]] = []

    init(fixed: CGFloat? = nil, headers: [String: String] = [:]) {
        self.fixed = fixed
        self.headers = headers
    }

    var fixedRowHeight: CGFloat? { fixed }

    func cellKind(for row: TestListRow) -> MacListCellKind { row.hosted ? Self.hostedKind : Self.nativeKind }

    func makeCell(_ kind: MacListCellKind) -> NSTableCellView {
        switch kind {
        case .native: return TestListCell(frame: .zero)
        case .hosted: return MacHostedRowView<TestListRows>(frame: .zero)
        }
    }

    func configure(_ cell: NSTableCellView, with row: TestListRow) {
        configured.append(row.id)
        if let cell = cell as? TestListCell {
            cell.show(row)
        } else if let cell = cell as? MacHostedRowView<TestListRows> {
            cell.configure(rowID: row.id, expectedHeight: height(for: row, width: 0), content: row.title, source: self)
        }
    }

    func height(for row: TestListRow, width: CGFloat) -> CGFloat { CGFloat(20 * row.lines) }

    func accessibilityLabel(for row: TestListRow) -> String? { "\(row.title), \(row.lines) line(s)" }

    func typeSelectString(for row: TestListRow) -> String? { row.title }

    func sectionHeaderTitle(_ key: String) -> String? { headers[key] }

    func menuItems(for ids: [String]) -> [NSMenuItem] {
        menuRequests.append(ids)
        return [NSMenuItem(title: "Act on \(ids.joined(separator: ","))", action: nil, keyEquivalent: "")]
    }

    func activate(_ ids: [String]) { activated.append(ids) }

    func hostedCellBody(_ content: String) -> some View { Text(content) }
}

/// The published state of a test list, and the publications its edits make.
@MainActor
final class TestListModel {
    var sections: [ListSection<String>]
    var content: [String: TestListRow] = [:]

    init(_ sections: [(key: String, ids: [String])]) {
        self.sections = sections.map { ListSection(key: $0.key, ids: $0.ids) }
        for section in sections {
            for id in section.ids { content[id] = TestListRow(id: id, title: id) }
        }
    }

    var rows: [TestListRow] { sections.flatMap { $0.ids.map { content[$0]! } } }

    func reset() -> ListPublication<TestListRow, String> {
        ListPublication(update: .reset(sections), rows: rows)
    }

    /// An edit as an index would publish it: the update from the old state
    /// to the new one, given the ids it touched.
    func edit(touching touched: Set<String>, resetFraction: Double = 1,
              _ body: (inout [ListSection<String>], inout [String: TestListRow]) -> Void)
        -> ListPublication<TestListRow, String> {
        let old = sections
        body(&sections, &content)
        let update = ListUpdate(from: old, to: sections, touched: touched, resetFraction: resetFraction)
        return ListPublication(update: update, rows: rows)
    }

    /// Moves `id` to `index` of section `section`.
    func move(_ id: String, toSection section: Int, at index: Int) -> ListPublication<TestListRow, String> {
        edit(touching: [id]) { sections, _ in
            for s in sections.indices { sections[s].ids.removeAll { $0 == id } }
            sections[section].ids.insert(id, at: min(index, sections[section].ids.count))
        }
    }

    func insert(_ id: String, section: Int = 0, at index: Int, title: String? = nil)
        -> ListPublication<TestListRow, String> {
        edit(touching: [id]) { sections, content in
            sections[section].ids.insert(id, at: index)
            content[id] = TestListRow(id: id, title: title ?? id)
        }
    }

    func remove(_ id: String) -> ListPublication<TestListRow, String> {
        edit(touching: [id]) { sections, content in
            for s in sections.indices { sections[s].ids.removeAll { $0 == id } }
            content[id] = nil
        }
    }

    func change(_ id: String, _ body: (inout TestListRow) -> Void) -> ListPublication<TestListRow, String> {
        edit(touching: [id]) { _, content in body(&content[id]!) }
    }
}

// MARK: - Tests

/// `MacListHost` against a real table in a test window, fed by the
/// `ListUpdate`s an index would publish.
@MainActor final class MacListHostTests: XCTestCase {
    @MainActor final class Fixture {
        let window: NSWindow
        let rows: TestListRows
        let host: MacListHost<TestListRows>
        let model: TestListModel
        var userSelections: [Set<String>] = []

        var table: MacListTableView { host.tableView }

        init(_ sections: [(key: String, ids: [String])], rows: TestListRows? = nil,
             multiple: Bool = false, style: MacListStyle = .plain, height: CGFloat = 400) {
            let rows = rows ?? TestListRows(fixed: 20)
            self.rows = rows
            model = TestListModel(sections)
            host = MacListHost(rows: rows, style: style, allowsMultipleSelection: multiple,
                               accessibilityIdentifier: "test.list")
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: height), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host.view.frame = window.contentView!.bounds
            host.view.autoresizingMask = [.width, .height]
            // Overlay scrollers whatever the machine's setting: a legacy
            // scroller appears once the rows overflow and narrows the
            // table, which re-measures every row (CI runners use them).
            host.scrollView.scrollerStyle = .overlay
            window.contentView!.addSubview(host.view)
            host.onSelectionChange = { [unowned self] ids in userSelections.append(ids) }
            window.orderFront(nil)
            apply(model.reset())
        }

        func apply(_ publication: ListPublication<TestListRow, String>) {
            host.apply(publication)
            settle()
        }

        func settle() {
            host.flushPendingUpdates()
            window.contentView?.layoutSubtreeIfNeeded()
            table.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        /// The table's rows: ids, and `#title` for headers.
        var tableRows: [String] {
            host.applier.ids.map {
                switch $0 {
                case .header(let key): return "#\(rows.headers[key] ?? key)"
                case .row(let id): return id
                }
            }
        }

        var modelRows: [String] {
            model.sections.flatMap { section -> [String] in
                guard !section.ids.isEmpty, let title = rows.headers[section.key] else { return section.ids }
                return ["#\(title)"] + section.ids
            }
        }

        /// The ids the table shows selected.
        var tableSelection: Set<String> { Set(host.orderedSelection) }

        func row(of id: String) -> Int { host.tableRow(of: id) ?? -1 }

        /// The user clicks `id` (as `NSTableView` does: select, then notify).
        func userSelect(_ ids: [String], extending: Bool = false) {
            table.selectRowIndexes(IndexSet(ids.map(row(of:))), byExtendingSelection: extending)
        }

        func key(_ keyCode: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: characters,
                                         charactersIgnoringModifiers: characters, isARepeat: false,
                                         keyCode: keyCode)!
            table.keyDown(with: event)
        }

        func close() {
            window.orderOut(nil)
            window.close()
        }
    }

    static func ids(_ prefix: String, _ count: Int) -> [String] { (0..<count).map { "\(prefix)\($0)" } }

    static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: Selection

    func test_selection_survivesInsertsRemovesMovesAndResets() {
        let f = Fixture([("a", Self.ids("r", 10))])
        defer { f.close() }
        f.host.selection = ["r5"]
        XCTAssertEqual(f.tableSelection, ["r5"])

        f.apply(f.model.insert("new0", at: 0))
        XCTAssertEqual(f.tableRows, f.modelRows)
        XCTAssertEqual(f.tableSelection, ["r5"], "after an insert above it")

        f.apply(f.model.remove("r1"))
        XCTAssertEqual(f.tableRows, f.modelRows)
        XCTAssertEqual(f.tableSelection, ["r5"], "after a remove above it")

        f.apply(f.model.move("r5", toSection: 0, at: 0))
        XCTAssertEqual(f.tableRows, f.modelRows)
        XCTAssertEqual(f.table.selectedRow, 0)
        XCTAssertEqual(f.tableSelection, ["r5"], "after it moved")

        f.apply(f.model.move("r9", toSection: 0, at: 0))
        XCTAssertEqual(f.tableSelection, ["r5"], "after another row moved over it")

        f.model.sections[0].ids.reverse()
        f.apply(f.model.reset())
        XCTAssertEqual(f.tableRows, f.modelRows)
        XCTAssertEqual(f.tableSelection, ["r5"], "after a reset it is re-applied by id")
        XCTAssertEqual(f.row(of: "r5"), f.model.sections[0].ids.firstIndex(of: "r5"))

        // The selected row leaves and comes back: the selection is the
        // host's by id, so it is shown again.
        f.apply(f.model.remove("r5"))
        XCTAssertEqual(f.tableSelection, [])
        XCTAssertEqual(f.host.selection, ["r5"])
        f.apply(f.model.insert("r5", at: 3))
        XCTAssertEqual(f.tableSelection, ["r5"])

        XCTAssertEqual(f.userSelections, [], "no update is a user selection")
    }

    func test_selection_multiple_survivesMovesAcrossSections() {
        let rows = TestListRows(fixed: 20, headers: ["a": "A", "b": "B"])
        let f = Fixture([("a", Self.ids("a", 4)), ("b", Self.ids("b", 4))], rows: rows, multiple: true)
        defer { f.close() }
        f.host.selection = ["a1", "b2"]
        XCTAssertEqual(f.tableSelection, ["a1", "b2"])
        f.apply(f.model.move("b2", toSection: 0, at: 0))
        XCTAssertEqual(f.tableRows, f.modelRows)
        XCTAssertEqual(f.tableSelection, ["a1", "b2"])
        f.apply(f.model.move("a1", toSection: 1, at: 2))
        XCTAssertEqual(f.tableRows, f.modelRows)
        XCTAssertEqual(f.tableSelection, ["a1", "b2"])
        XCTAssertEqual(f.userSelections, [])
    }

    func test_selection_fromOutsideScrollsIntoView_userSelectionDoesNot() {
        let f = Fixture([("a", Self.ids("r", 200))])
        defer { f.close() }
        XCTAssertEqual(f.table.visibleRect.minY, 0)

        // The user selects a row partly off the bottom: no scroll.
        let visible = f.table.rows(in: f.table.visibleRect)
        let lastVisible = visible.location + visible.length - 1
        f.userSelect(["r\(lastVisible)"])
        f.settle()
        XCTAssertEqual(f.table.visibleRect.minY, 0, "a user selection never scrolls")
        XCTAssertEqual(f.userSelections, [["r\(lastVisible)"]])

        // From outside, off-screen: scrolled into view.
        f.host.selection = ["r150"]
        f.settle()
        XCTAssertTrue(f.table.visibleRect.contains(f.table.rect(ofRow: f.row(of: "r150"))))
        XCTAssertEqual(f.userSelections.count, 1, "a selection from outside is not reported back")
    }

    func test_selection_fromOutside_beforeItsRowArrives_scrollsWhenItDoes() {
        let f = Fixture([("a", Self.ids("r", 200))])
        defer { f.close() }
        f.host.selection = ["late"]
        f.apply(f.model.insert("late", at: 180))
        XCTAssertEqual(f.tableSelection, ["late"])
        XCTAssertTrue(f.table.visibleRect.contains(f.table.rect(ofRow: f.row(of: "late"))))
    }

    func test_selection_userChoiceCancelsAWaitingOutsideScroll() {
        // 410 pt: the last visible row is cut off at the bottom.
        let f = Fixture([("a", Self.ids("r", 200))], height: 410)
        defer { f.close() }
        // From outside, for a row not in the list yet: it waits to scroll.
        f.host.selection = ["late"]
        f.settle()
        // The user then picks a row partly off the bottom (which a stray
        // scroll would move), and the outside row arrives later.
        let visible = f.table.rows(in: f.table.visibleRect)
        let lastVisible = "r\(visible.location + visible.length - 1)"
        f.userSelect([lastVisible])
        f.settle()
        f.apply(f.model.insert("late", at: 180))
        f.apply(f.model.change(lastVisible) { $0.title = "changed" })
        XCTAssertEqual(f.tableSelection, [lastVisible])
        XCTAssertEqual(f.table.visibleRect.minY, 0, "the user's selection replaced the outside one: no scroll")
    }

    func test_selectionMode_canChangeWithoutANewHost() {
        let f = Fixture([("a", Self.ids("r", 20))], multiple: true)
        defer { f.close() }
        f.host.selection = ["r1", "r3"]
        f.settle()
        XCTAssertEqual(f.tableSelection, ["r1", "r3"])

        f.host.allowsMultipleSelection = false
        f.settle()
        XCTAssertFalse(f.table.allowsMultipleSelection)
        XCTAssertEqual(f.tableSelection, ["r1"], "leaving multiple selection keeps the first row")
        XCTAssertEqual(f.host.selection, ["r1"])
        XCTAssertEqual(f.userSelections.last, ["r1"], "the narrowed selection is reported to the binding")

        f.host.allowsMultipleSelection = true
        XCTAssertTrue(f.table.allowsMultipleSelection)
    }

    func test_selectionMode_narrowedFromSwiftUI_keepsTheNarrowedSelection() {
        let f = Fixture([("a", Self.ids("r", 20))], multiple: true)
        defer { f.close() }
        var stored: Set<String> = ["r1", "r3"]
        let coordinator = MacListView<TestListRows>.Coordinator()
        let binding = Binding<Set<String>>(get: { stored }, set: { stored = $0 })
        coordinator.attach(f.host, selection: binding, publications: AsyncStream { $0.finish() })
        f.settle()
        XCTAssertEqual(f.tableSelection, ["r1", "r3"])

        // One SwiftUI update: the mode turns off, and the selection it
        // carries is still the wider one.
        coordinator.setAllowsMultipleSelection(false)
        coordinator.bindingChanged(to: stored)
        f.settle()
        XCTAssertEqual(f.host.selection, ["r1"], "the stale wider selection is not re-applied")
        XCTAssertEqual(f.tableSelection, ["r1"])
        XCTAssertEqual(stored, ["r1", "r3"], "the binding is written after the update, not during it")

        let deadline = Date().addingTimeInterval(2)
        while stored != ["r1"], Date() < deadline { Self.spin(0.01) }
        XCTAssertEqual(stored, ["r1"])
        coordinator.bindingChanged(to: stored)
        XCTAssertEqual(f.host.selection, ["r1"])
    }

    func test_selectionMode_narrowedWhileTheParentAlsoSelects_keepsTheParentsSelection() {
        let f = Fixture([("a", Self.ids("r", 20))], multiple: true)
        defer { f.close() }
        var stored: Set<String> = ["r1", "r3"]
        let coordinator = MacListView<TestListRows>.Coordinator()
        let binding = Binding<Set<String>>(get: { stored }, set: { stored = $0 })
        coordinator.attach(f.host, selection: binding, publications: AsyncStream { $0.finish() })
        f.settle()

        // One SwiftUI update turns the mode off and selects r7.
        stored = ["r7"]
        coordinator.setAllowsMultipleSelection(false)
        coordinator.bindingChanged(to: stored)
        f.settle()
        XCTAssertEqual(f.host.selection, ["r7"], "the parent's own change wins over the narrowing")
        Self.spin(0.1)
        XCTAssertEqual(stored, ["r7"], "the narrowed selection is not written over it later")
        XCTAssertEqual(f.tableSelection, ["r7"])
    }

    func test_singleSelection_givenSeveralIDs_keepsTheOneItShows() {
        let f = Fixture([("a", Self.ids("r", 20))])
        defer { f.close() }
        f.host.selection = ["r5", "r2"]
        f.settle()
        XCTAssertEqual(f.tableSelection, ["r2"])
        XCTAssertEqual(f.host.selection, ["r2"], "the host's selection matches the one row shown")
        let deadline = Date().addingTimeInterval(2)
        while f.userSelections.isEmpty, Date() < deadline { Self.spin(0.01) }
        XCTAssertEqual(f.userSelections, [["r2"]], "the narrowing is reported so the binding follows")
    }

    // MARK: Echo guard

    func test_echoGuard_hostAndBindingDoNotEchoEachOther() {
        let f = Fixture([("a", Self.ids("r", 200))])
        defer { f.close() }
        var stored: Set<String> = []
        let coordinator = MacListView<TestListRows>.Coordinator()
        var reentrantUpdates = 0
        let binding = Binding<Set<String>>(get: { stored }, set: { value in
            let previous = stored
            stored = value
            // SwiftUI may run an update from inside the write, still
            // carrying the old value: that is the echo.
            reentrantUpdates += 1
            coordinator.bindingChanged(to: previous)
        })
        coordinator.attach(f.host, selection: binding, publications: AsyncStream { $0.finish() })
        f.host.onSelectionChange = { [unowned coordinator] in coordinator.hostChanged($0) }

        // The user selects: written to the binding once.
        f.userSelect(["r3"])
        XCTAssertEqual(stored, ["r3"])
        XCTAssertEqual(coordinator.bindingWriteCountForTesting, 1)
        XCTAssertEqual(reentrantUpdates, 1)
        XCTAssertEqual(f.tableSelection, ["r3"], "the stale value inside the write did not win")

        // SwiftUI's update with the same value: nothing happens.
        let offset = f.table.visibleRect.minY
        coordinator.bindingChanged(to: ["r3"])
        f.settle()
        XCTAssertEqual(f.tableSelection, ["r3"])
        XCTAssertEqual(f.table.visibleRect.minY, offset)
        XCTAssertEqual(coordinator.bindingWriteCountForTesting, 1)

        // A real change from SwiftUI: applied, scrolled to, not written back.
        coordinator.bindingChanged(to: ["r190"])
        f.settle()
        XCTAssertEqual(f.tableSelection, ["r190"])
        XCTAssertTrue(f.table.visibleRect.contains(f.table.rect(ofRow: f.row(of: "r190"))))
        XCTAssertEqual(coordinator.bindingWriteCountForTesting, 1, "an outside selection is not echoed")

        // Updates landing never write the binding.
        f.apply(f.model.move("r190", toSection: 0, at: 0))
        f.apply(f.model.remove("r4"))
        XCTAssertEqual(coordinator.bindingWriteCountForTesting, 1)
        coordinator.detach()
    }

    // MARK: Keyboard

    func test_keyboard_arrowsSkipHeaders_returnAndDoubleClickActivate() {
        let rows = TestListRows(fixed: 20, headers: ["a": "A", "b": "B"])
        let f = Fixture([("a", ["a0", "a1"]), ("b", ["b0", "b1"])], rows: rows)
        defer { f.close() }
        f.window.makeKeyAndOrderFront(nil)
        f.window.makeFirstResponder(f.table)
        XCTAssertEqual(f.tableRows, ["#A", "a0", "a1", "#B", "b0", "b1"])

        f.userSelect(["a0"])
        f.key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
        XCTAssertEqual(f.tableSelection, ["a1"])
        f.key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
        XCTAssertEqual(f.tableSelection, ["b0"], "down from a1 skips the B header")
        f.key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!))
        XCTAssertEqual(f.tableSelection, ["a1"])
        XCTAssertEqual(f.host.selection, ["a1"])
        XCTAssertEqual(f.userSelections.last, ["a1"], "keyboard selection is the user's")

        f.key(36, "\r")
        XCTAssertEqual(rows.activated, [["a1"]])
        f.key(76, "\u{3}")
        XCTAssertEqual(rows.activated, [["a1"], ["a1"]], "keypad Enter activates too")

        f.table.clickedRowOverrideForTesting = f.row(of: "b1")
        f.table.sendAction(f.table.doubleAction, to: f.table.target)
        XCTAssertEqual(rows.activated.last, ["b1"], "double-click activates the clicked row")
        f.table.clickedRowOverrideForTesting = 0
        f.table.sendAction(f.table.doubleAction, to: f.table.target)
        XCTAssertEqual(rows.activated.count, 3, "double-clicking a header activates nothing")
        f.table.clickedRowOverrideForTesting = nil
    }

    func test_keyboard_multipleSelection_shiftExtends_andReturnActivatesAllInOrder() {
        let f = Fixture([("a", Self.ids("r", 6))], multiple: true)
        defer { f.close() }
        f.window.makeKeyAndOrderFront(nil)
        f.window.makeFirstResponder(f.table)
        f.userSelect(["r1"])
        f.key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: .shift)
        f.key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: .shift)
        XCTAssertEqual(f.tableSelection, ["r1", "r2", "r3"])
        XCTAssertEqual(f.host.selection, ["r1", "r2", "r3"])
        f.key(36, "\r")
        XCTAssertEqual(f.rows.activated, [["r1", "r2", "r3"]])

        // Single-selection lists keep one row however the selection is set.
        let single = Fixture([("a", Self.ids("r", 6))])
        defer { single.close() }
        single.host.selection = ["r1", "r4"]
        XCTAssertEqual(single.table.selectedRowIndexes.count, 1)
    }

    func test_typeSelect_selectsByTheProvidersString() {
        let f = Fixture([("a", ["x0", "x1", "x2"])])
        defer { f.close() }
        for (id, title) in [("x0", "Alpha"), ("x1", "Bravo"), ("x2", "Charlie")] {
            f.apply(f.model.change(id) { $0.title = title })
        }
        XCTAssertEqual(f.host.tableView(f.table, typeSelectStringFor: nil, row: 2), "Charlie")
        f.window.makeKeyAndOrderFront(nil)
        f.window.makeFirstResponder(f.table)
        f.key(8, "c")
        XCTAssertEqual(f.tableSelection, ["x2"])
        XCTAssertEqual(f.userSelections.last, ["x2"])

        let rows = TestListRows(fixed: 20, headers: ["a": "A"])
        let headed = Fixture([("a", ["y0"])], rows: rows)
        defer { headed.close() }
        XCTAssertNil(headed.host.tableView(headed.table, typeSelectStringFor: nil, row: 0), "headers are skipped")
    }

    // MARK: Context menu

    func test_menuTargets_selectionClickedRowAndEmptySpace() {
        let rows = TestListRows(fixed: 20, headers: ["a": "A"])
        let f = Fixture([("a", Self.ids("r", 6))], rows: rows, multiple: true)
        defer { f.close() }
        f.userSelect(["r1", "r3"])

        // A row inside the selection: the whole selection, in table order.
        f.table.clickedRowOverrideForTesting = f.row(of: "r3")
        f.host.menuNeedsUpdate(f.host.contextMenu)
        XCTAssertEqual(rows.menuRequests.last, ["r1", "r3"])
        XCTAssertEqual(f.host.contextMenu.items.map(\.title), ["Act on r1,r3"])

        // An unselected row: that row alone, and the selection stays.
        f.table.clickedRowOverrideForTesting = f.row(of: "r4")
        f.host.menuNeedsUpdate(f.host.contextMenu)
        XCTAssertEqual(rows.menuRequests.last, ["r4"])
        XCTAssertEqual(f.host.contextMenu.items.map(\.title), ["Act on r4"])
        XCTAssertEqual(f.tableSelection, ["r1", "r3"])

        // Empty space, and a header: nothing, and the provider is not asked.
        let asked = rows.menuRequests.count
        for clicked in [-1, 0] {
            f.table.clickedRowOverrideForTesting = clicked
            f.host.menuNeedsUpdate(f.host.contextMenu)
            XCTAssertEqual(f.host.contextMenu.items.count, 0)
        }
        XCTAssertEqual(rows.menuRequests.count, asked)
        XCTAssertTrue(f.table.menu === f.host.contextMenu, "one menu for the whole list")
        f.table.clickedRowOverrideForTesting = nil
    }

    // MARK: Accessibility

    func test_accessibility_rowLabels_headers_andIdentifier() throws {
        let rows = TestListRows(fixed: 20, headers: ["a": "Needs you"])
        let f = Fixture([("a", ["r0", "r1"])], rows: rows)
        defer { f.close() }
        XCTAssertEqual(f.table.accessibilityIdentifier(), "test.list")
        XCTAssertEqual(f.table.accessibilityRole(), .table)

        let rowView = try XCTUnwrap(f.table.rowView(atRow: f.row(of: "r1"), makeIfNecessary: false))
        // What VoiceOver walks: the table's AXRow elements, each with one
        // AXCell carrying the provider's label.
        XCTAssertEqual(Self.axRows(of: f.table).map(\.role), ["AXRow", "AXRow", "AXRow"])
        XCTAssertEqual(Self.axRows(of: f.table).map(\.label), ["Needs you", "r0, 1 line(s)", "r1, 1 line(s)"])
        XCTAssertEqual(rowView.accessibilityLabel(), "r1, 1 line(s)")
        let cell = try XCTUnwrap(f.table.view(atColumn: 0, row: f.row(of: "r1"), makeIfNecessary: false))
        XCTAssertEqual(cell.accessibilityLabel(), "r1, 1 line(s)")

        // A content change updates the label in place.
        f.apply(f.model.change("r1") { $0.title = "Renamed" })
        XCTAssertEqual(rowView.accessibilityLabel(), "Renamed, 1 line(s)")
        XCTAssertEqual(Self.axRows(of: f.table).last?.label, "Renamed, 1 line(s)")
        XCTAssertEqual(cell.accessibilityLabel(), "Renamed, 1 line(s)")

        // The group row is a header.
        XCTAssertTrue(f.host.tableView(f.table, isGroupRow: 0))
        let header = try XCTUnwrap(f.table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? MacListHeaderCell)
        XCTAssertEqual(header.accessibilityRole(), MacListHeaderCell.headingRole)
        XCTAssertEqual(header.accessibilityLabel(), "Needs you")
        XCTAssertEqual(f.table.rowView(atRow: 0, makeIfNecessary: false)?.accessibilityLabel(), "Needs you")
    }

    /// The table's accessibility rows as VoiceOver reads them: each row's
    /// role, and its cell's description.
    static func axRows(of table: NSTableView) -> [(role: String, label: String?)] {
        (table.accessibilityChildren() ?? []).compactMap { element in
            guard let row = element as? NSObject,
                  let role = row.accessibilityAttributeValue(.role) as? String,
                  role == NSAccessibility.Role.row.rawValue else { return nil }
            let cells = row.accessibilityAttributeValue(.children) as? [Any] ?? []
            let label = (cells.first as? NSObject)?.accessibilityAttributeValue(.description) as? String
            return (role, label)
        }
    }

    func test_sourceListStyle_hasAClearBackground() {
        let f = Fixture([("a", ["r0"])], style: .sourceList)
        defer { f.close() }
        XCTAssertEqual(f.table.style, .sourceList)
        XCTAssertEqual(f.table.backgroundColor, .clear)
        XCTAssertFalse(f.host.scrollView.drawsBackground)
        XCTAssertFalse(f.table.usesAutomaticRowHeights)
    }

    // MARK: Group rows

    func test_groupRows_mapAcrossSections() {
        let rows = TestListRows(fixed: 20, headers: ["a": "A", "b": "B", "d": "D"])
        let f = Fixture([("a", ["a0", "a1"]), ("b", []), ("c", ["c0", "c1"]), ("d", ["d0"])], rows: rows)
        defer { f.close() }
        let reloads = f.host.reloadCountForTesting
        // B is empty (no header), C has no title (no header).
        XCTAssertEqual(f.tableRows, ["#A", "a0", "a1", "c0", "c1", "#D", "d0"])
        let groupRows = (0..<f.table.numberOfRows).filter { f.host.tableView(f.table, isGroupRow: $0) }
        XCTAssertEqual(groupRows, [0, 5])
        let layout = f.host.shownLayout
        XCTAssertEqual(layout.tableRow(for: ListPath(section: 0, row: 1)), 2)
        XCTAssertEqual(layout.tableRow(for: ListPath(section: 2, row: 0)), 3)
        XCTAssertEqual(layout.tableRow(for: ListPath(section: 3, row: 0)), 6)
        XCTAssertNil(layout.tableRow(for: ListPath(section: 1, row: 0)))
        XCTAssertEqual(layout.location(ofTableRow: 0)?.section, 0)
        XCTAssertNil(layout.location(ofTableRow: 0)?.row)
        XCTAssertEqual(layout.location(ofTableRow: 4)?.section, 2)
        XCTAssertEqual(layout.location(ofTableRow: 4)?.row, 1)
        XCTAssertEqual(layout.location(ofTableRow: 6)?.section, 3)
        XCTAssertEqual(layout.insertionPath(aboveTableRow: 5), ListPath(section: 2, row: 2), "above D's header")
        XCTAssertEqual(layout.insertionPath(aboveTableRow: 7), ListPath(section: 3, row: 1), "past the end")
        XCTAssertFalse(f.host.tableView(f.table, shouldSelectRow: 0), "headers are not selectable")

        // c0 moves into B: B's header appears.
        f.apply(f.model.move("c0", toSection: 1, at: 0))
        XCTAssertEqual(f.tableRows, ["#A", "a0", "a1", "#B", "c0", "c1", "#D", "d0"])
        XCTAssertEqual(f.host.shownLayout.tableRow(for: ListPath(section: 1, row: 0)), 4)
        // D empties: its header goes.
        f.apply(f.model.remove("d0"))
        XCTAssertEqual(f.tableRows, ["#A", "a0", "a1", "#B", "c0", "c1"])
        // Moves across sections, both ways.
        f.apply(f.model.move("a0", toSection: 2, at: 1))
        f.apply(f.model.move("c1", toSection: 0, at: 0))
        XCTAssertEqual(f.tableRows, f.modelRows)
        XCTAssertEqual(f.tableRows, ["#A", "c1", "a1", "#B", "c0", "a0"])
        for (index, id) in f.tableRows.enumerated() where !id.hasPrefix("#") {
            XCTAssertEqual((f.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? TestListCell)?.rowID, id)
        }
        XCTAssertEqual(f.host.reloadCountForTesting, reloads, "no edit reloaded")
    }

    func test_insertionPath_skipsEmptySections() {
        let rows = TestListRows(fixed: 20, headers: ["a": "A", "b": "B", "c": "C", "d": "D"])
        let f = Fixture([("a", []), ("b", ["b0", "b1"]), ("c", []), ("d", ["d0"]), ("e", [])], rows: rows)
        defer { f.close() }
        XCTAssertEqual(f.tableRows, ["#B", "b0", "b1", "#D", "d0"])
        let layout = f.host.shownLayout
        XCTAssertEqual(layout.insertionPath(aboveTableRow: 0), ListPath(section: 1, row: 0), "above the first header")
        XCTAssertEqual(layout.insertionPath(aboveTableRow: 3), ListPath(section: 1, row: 2), "above D's header")
        XCTAssertEqual(layout.insertionPath(aboveTableRow: 5), ListPath(section: 3, row: 1), "past the end")
    }

    func test_randomEdits_keepTheTableOnTheModel() {
        let rows = TestListRows(headers: ["a": "A", "b": "B", "c": "C"])
        let f = Fixture([("a", Self.ids("a", 12)), ("b", Self.ids("b", 12)), ("c", Self.ids("c", 12))], rows: rows,
                        height: 1000)
        defer { f.close() }
        var rng = ListHostRandom(seed: 7)
        var next = 0
        for step in 0..<150 {
            let all = f.model.sections.flatMap(\.ids)
            switch Int.random(in: 0..<5, using: &rng) {
            case 0 where all.count < 60:
                next += 1
                let s = Int.random(in: 0..<3, using: &rng)
                f.host.apply(f.model.insert("n\(next)", section: s,
                                            at: Int.random(in: 0...f.model.sections[s].ids.count, using: &rng)))
            case 1 where all.count > 4:
                f.host.apply(f.model.remove(all.randomElement(using: &rng)!))
            case 2:
                let s = Int.random(in: 0..<3, using: &rng)
                f.host.apply(f.model.move(all.randomElement(using: &rng)!, toSection: s,
                                          at: Int.random(in: 0...f.model.sections[s].ids.count, using: &rng)))
            default:
                f.host.apply(f.model.change(all.randomElement(using: &rng)!) {
                    $0.title += "'"
                    $0.lines = Int.random(in: 1...3, using: &rng)
                })
            }
            // Several updates per frame, sometimes.
            if step % 3 == 0 { f.settle() }
            if step % 3 == 0 {
                XCTAssertEqual(f.tableRows, f.modelRows, "step \(step)")
                for (index, id) in f.tableRows.enumerated() where !id.hasPrefix("#") {
                    let row = f.model.content[id]!
                    XCTAssertEqual(f.table.rect(ofRow: index).height, CGFloat(20 * row.lines), "height of \(id)")
                    if let cell = f.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? TestListCell {
                        XCTAssertEqual(cell.label.stringValue, row.title, "content of \(id) at step \(step)")
                    }
                }
            }
        }
        #if DEBUG
        XCTAssertEqual(f.host.applier.reentrancyCountForTesting, 0)
        #endif
    }

    // MARK: Coalescing

    func test_updatesWithinAFrame_coalesceToOnePass() {
        let f = Fixture([("a", Self.ids("r", 20))])
        defer { f.close() }
        let passes = f.host.passCountForTesting
        f.host.apply(f.model.move("r10", toSection: 0, at: 0))
        f.host.apply(f.model.change("r3") { $0.title = "changed" })
        f.host.apply(f.model.insert("n0", at: 5))
        f.host.apply(f.model.remove("r7"))
        XCTAssertEqual(f.host.passCountForTesting, passes, "nothing runs until the frame")
        let deadline = Date().addingTimeInterval(2)
        while f.host.passCountForTesting == passes, Date() < deadline { Self.spin(0.01) }
        Self.spin(MacFrameCoalescer.fallbackDelay * 2)
        XCTAssertEqual(f.host.passCountForTesting, passes + 1, "four updates, one pass")
        f.settle()
        XCTAssertEqual(f.tableRows, f.modelRows)
        XCTAssertEqual((f.table.view(atColumn: 0, row: f.row(of: "r3"), makeIfNecessary: false) as? TestListCell)?
            .label.stringValue, "changed")
    }

    // MARK: Heights

    func test_heights_cachedByIDContentAndWidth() {
        let f = Fixture([("a", Self.ids("r", 30))], rows: TestListRows())
        defer { f.close() }
        XCTAssertEqual(f.table.rect(ofRow: 3).height, 20)
        let measured = f.host.heightMeasureCountForTesting

        // One row grows: it alone is measured again, and the table moves
        // the rows below it.
        f.apply(f.model.change("r3") { $0.lines = 2 })
        XCTAssertEqual(f.host.heightMeasureCountForTesting, measured + 1)
        XCTAssertEqual(f.table.rect(ofRow: 3).height, 40)
        XCTAssertEqual(f.table.rect(ofRow: 4).minY, 3 * 20 + 40)

        // A title change measures that row only (same lines, same height).
        f.apply(f.model.change("r8") { $0.title = "other" })
        XCTAssertEqual(f.host.heightMeasureCountForTesting, measured + 2)

        // A width change re-measures.
        let before = f.host.heightMeasureCountForTesting
        f.window.setContentSize(NSSize(width: 400, height: 400))
        f.settle()
        Self.spin(MacFrameCoalescer.fallbackDelay * 2)
        f.settle()
        XCTAssertGreaterThan(f.host.heightMeasureCountForTesting, before)
        XCTAssertEqual(f.table.rect(ofRow: 3).height, 40)
    }

    func test_hostedRow_mountsTheHostedCell() {
        let f = Fixture([("a", ["r0", "more"])])
        defer { f.close() }
        f.apply(f.model.change("more") { $0.hosted = true; $0.title = "Show more" })
        XCTAssertTrue(f.table.view(atColumn: 0, row: 1, makeIfNecessary: false) is MacHostedRowView<TestListRows>)
        f.apply(f.model.change("more") { $0.hosted = false })
        XCTAssertTrue(f.table.view(atColumn: 0, row: 1, makeIfNecessary: false) is TestListCell,
                      "a kind change reloads the row")
    }

    // MARK: Minute tick

    func test_minuteTick_reconfiguresVisibleRowsOnly() {
        let f = Fixture([("a", Self.ids("r", 300))])
        defer { f.close() }
        XCTAssertTrue(f.host.hasMinuteTimerForTesting, "one timer while in a window")
        f.rows.configured = []
        f.host.minuteTick()
        let visible = f.table.rows(in: f.table.visibleRect)
        let expected = (visible.location..<(visible.location + visible.length)).map { "r\($0)" }
        XCTAssertFalse(expected.isEmpty)
        XCTAssertLessThan(expected.count, 40)
        XCTAssertEqual(f.rows.configured, expected)

        f.window.contentView?.subviews.forEach { $0.removeFromSuperview() }
        XCTAssertFalse(f.host.hasMinuteTimerForTesting, "no timer out of a window")
    }

    // MARK: Move steps

    /// `moveSteps` against random reorders: movers placed one move each,
    /// every other row keeping its order.
    func test_moveSteps_bringEveryMoverToItsTarget() {
        typealias Host = MacListHost<TestListRows>
        var rng = ListHostRandom(seed: 3)
        for _ in 0..<500 {
            let n = Int.random(in: 1...30, using: &rng)
            let current = Array(0..<n)
            let moverCount = Int.random(in: 0...min(n, 6), using: &rng)
            let movers = Set(current.shuffled(using: &rng).prefix(moverCount))
            // The target: the non-movers in order, movers dropped in anywhere.
            var target = current.filter { !movers.contains($0) }
            for mover in movers.shuffled(using: &rng) {
                target.insert(mover, at: Int.random(in: 0...target.count, using: &rng))
            }
            let pairs = movers.map { (source: current.firstIndex(of: $0)!, target: target.firstIndex(of: $0)!) }
                .sorted { $0.target < $1.target }
            var order = current
            let steps = Host.moveSteps(pairs)
            for step in steps {
                guard case .move(let from, let to) = step else { return XCTFail("not a move: \(step)") }
                order.insert(order.remove(at: from), at: to)
            }
            XCTAssertEqual(order, target, "movers \(pairs)")
            XCTAssertLessThanOrEqual(steps.count, movers.count)
        }
    }

    // MARK: Perf harness

    /// 4 Hz updates to a 2,000-row, three-section list (a row jumping to
    /// the top, three rows changing, every third update an insert and a
    /// remove), each timed on the main thread from `apply` through the
    /// pass, layout and display. The updates are computed beforehand: that
    /// is the index's work, off the main thread.
    ///
    /// Two shapes: fixed-height rows (the sidebar) and variable heights
    /// (Decisions: every changed row re-measured, off-screen ones found by
    /// a walk). Two numbers each: the whole update, and the host's own
    /// share (the update minus the time inside the table's edit calls,
    /// layout and display, which is AppKit re-framing the rows a move
    /// shifts and mounting the rows it brings on screen).
    ///
    /// Asserted (fixed heights): the host's own median under 2 ms. The whole update is
    /// recorded and held only to a loose bound that catches a return to
    /// an O(n) pass (a full diff measured about 40 ms here): AppKit's
    /// share moves with the build machine's load.
    func test_perf_4HzUpdatesTo2000Rows_fixedHeights() {
        let result = Self.runPerf(fixedHeights: true)
        XCTAssertLessThan(result.hostMedian, 2, result.report)
        XCTAssertLessThan(result.median, 25, result.report)
    }

    /// Variable heights are recorded, not held to 2 ms: a changed row with
    /// no view is found by a walk of the list (the update names changed
    /// rows by id only), which costs about 2 ms of Debug-build generic
    /// hashing at 2,000 rows. Decisions, the variable-height surface, does
    /// not change at the sidebar's rate.
    func test_perf_4HzUpdatesTo2000Rows_variableHeights() {
        let result = Self.runPerf(fixedHeights: false)
        XCTAssertLessThan(result.hostMedian, 10, result.report)
        XCTAssertLessThan(result.median, 30, result.report)
    }

    static func runPerf(fixedHeights: Bool) -> (median: Double, hostMedian: Double, report: String) {
        let rows = TestListRows(fixed: fixedHeights ? 20 : nil,
                                headers: ["pinned": "Pinned", "recent": "Recent", "older": "Older"])
        let f = Fixture([("pinned", ids("p", 20)), ("recent", ids("r", 980)), ("older", ids("o", 1000))],
                        rows: rows, multiple: true, height: 800)
        defer { f.close() }
        f.host.selection = ["r500"]
        XCTAssertEqual(f.model.sections.reduce(0) { $0 + $1.ids.count }, 2000)

        let count = 32
        var rng = ListHostRandom(seed: 11)
        var publications: [ListPublication<TestListRow, String>] = []
        var next = 0
        for step in 0..<count {
            let all = f.model.sections.flatMap(\.ids)
            let mover = f.model.sections[2].ids.randomElement(using: &rng)!
            let changed = (0..<3).map { _ in all.randomElement(using: &rng)! }
            var touched = Set(changed + [mover])
            var added: String?
            var gone: String?
            if step % 3 == 0 {
                next += 1
                added = "n\(next)"
                gone = f.model.sections[2].ids.filter { $0 != mover }.randomElement(using: &rng)!
                touched.insert(added!)
                touched.insert(gone!)
            }
            publications.append(f.model.edit(touching: touched, resetFraction: 0.5) { sections, content in
                sections[2].ids.removeAll { $0 == mover }
                sections[1].ids.insert(mover, at: 0)
                for id in changed where id != mover {
                    content[id]?.title += "."
                    if step % 2 == 0, let lines = content[id]?.lines { content[id]?.lines = lines % 3 + 1 }
                }
                if let added {
                    sections[1].ids.insert(added, at: 3)
                    content[added] = TestListRow(id: added, title: added)
                }
                if let gone {
                    sections[2].ids.removeAll { $0 == gone }
                    content[gone] = nil
                }
            })
            XCTAssertFalse(publications.last!.update.isReset)
        }

        var times: [Double] = []
        var hostTimes: [Double] = []
        for publication in publications {
            let start = CACurrentMediaTime()
            f.host.apply(publication)
            f.host.flushPendingUpdates()
            let passed = CACurrentMediaTime()
            f.table.layoutSubtreeIfNeeded()
            f.window.displayIfNeeded()
            let end = CACurrentMediaTime()
            times.append((end - start) * 1000)
            #if DEBUG
            hostTimes.append((passed - start - f.host.lastPassTableSecondsForTesting) * 1000)
            #else
            hostTimes.append((passed - start) * 1000)
            #endif
            spin(0.25)
        }
        XCTAssertEqual(f.tableRows, f.modelRows)
        XCTAssertEqual(f.tableSelection, ["r500"])
        XCTAssertEqual(f.host.reloadCountForTesting, 2, "the empty load and the first reset only")
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2]
        let p90 = sorted[Int(Double(sorted.count) * 0.9)]
        #if DEBUG
        let config = "debug"
        #else
        let config = "release"
        #endif
        let host = hostTimes.sorted()
        let hostMedian = host[host.count / 2]
        let report = String(format: "LISTHOST-PERF heights=%@ rows=2000 updates=%d config=%@ "
                            + "update median=%.3fms p90=%.3fms max=%.3fms; host median=%.3fms p90=%.3fms max=%.3fms",
                            fixedHeights ? "fixed" : "variable", count, config, median, p90, sorted.last!,
                            hostMedian, host[Int(Double(host.count) * 0.9)], host.last!)
        print(report)
        return (median, hostMedian, report)
    }
}

/// A deterministic random source (SplitMix64).
struct ListHostRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
