#if os(macOS)
import XCTest
import AppKit
import SwiftUI
@testable import MatronMac
import MatronDesignSystem
import MatronModels
import MatronJournal
import MatronViewModels

/// A drag carrying one pasteboard, for the table's drop callbacks.
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

@MainActor
final class MacItemsAppKitListTests: XCTestCase {
    typealias Fixtures = MacItemsPaneFixtures

    // MARK: The flag

    func test_flag_isOnInDebugOffInRelease_andReadsTheStoredChoice() throws {
        XCTAssertEqual(MacItemsListFlag.key, "list.appkit.items")
        XCTAssertTrue(MacItemsListFlag.defaultValue(isDebugBuild: true))
        XCTAssertFalse(MacItemsListFlag.defaultValue(isDebugBuild: false))
        let suite = "MacItemsAppKitListTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MacItemsListFlag.isOn(defaults), MacItemsListFlag.defaultValue)
        defaults.set("YES", forKey: MacItemsListFlag.key)
        XCTAssertTrue(MacItemsListFlag.isOn(defaults))
        defaults.set("NO", forKey: MacItemsListFlag.key)
        XCTAssertFalse(MacItemsListFlag.isOn(defaults))
    }

    // MARK: Rows and publications

    private func task(_ id: String, _ rank: Double, awaiting: ItemAwaiting? = .agent, title: String = "T",
                      origin: String = "c1") -> TrackerItem {
        TrackerItem(id: id, num: Int(rank), kind: .task, awaiting: awaiting, rank: rank, title: title,
                    originConvoID: origin, createdAt: Fixtures.now, updatedAt: Fixtures.now)
    }

    func test_rowIDs_nameTheSection_soAnItemInTwoSectionsHasTwoRows() {
        let both = task("t1", 1, awaiting: .user)
        let needsYou = MacItemsPaneRow(item: both, section: .needsYou, origin: nil)
        let tasks = MacItemsPaneRow(item: both, section: .tasks, origin: nil)
        XCTAssertNotEqual(needsYou.id, tasks.id)
        XCTAssertEqual(MacItemsPaneSection.parse(tasks.id)?.section, .tasks)
        XCTAssertEqual(MacItemsPaneSection.parse(tasks.id)?.id, "t1")
        XCTAssertNil(MacItemsPaneSection.parse("nope"))
        let pending = MacItemsPaneRow(pending: .init(id: "p1", kind: .task, title: "P", isFailed: false, error: nil))
        XCTAssertEqual(pending.section, .pending)
        XCTAssertNil(pending.item)
    }

    private func sections(_ rows: [MacItemsPaneRow]) -> [ListSection<String>] {
        MacItemsPaneSection.allCases.map { section in
            ListSection(key: section.rawValue, ids: rows.filter { $0.section == section }.map(\.id))
        }
    }

    func test_publication_isAResetForTheFirstRowsAndAScopeChange_elseNamesTheChangedRows() {
        let tasks = (1...6).map { MacItemsPaneRow(item: task("t\($0)", Double($0)), section: .tasks, origin: nil) }
        let first = MacItemsPaneSource.publication(fromKey: nil, sections: [], rows: [:], toKey: "convo:c1",
                                                   sections: sections(tasks), rows: tasks)
        XCTAssertTrue(first.update.isReset)
        let shown = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        // A task retitled, and one that moved to Done: a reconfigure, and a
        // remove from Tasks with an insert under Done.
        var next = tasks
        next[1] = MacItemsPaneRow(item: task("t2", 2, title: "Renamed"), section: .tasks, origin: nil)
        let closed = next.remove(at: 4)
        let doneItem = TrackerItem(id: "t5", num: 5, kind: .task, state: .closed, resolution: .done, title: "T",
                                   originConvoID: "c1", createdAt: Fixtures.now, updatedAt: Fixtures.now)
        XCTAssertEqual(closed.item?.id, doneItem.id)
        let doneRow = MacItemsPaneRow(item: doneItem, section: .done, origin: nil)
        next.append(doneRow)
        let update = MacItemsPaneSource.publication(fromKey: "convo:c1", sections: sections(tasks), rows: shown,
                                                    toKey: "convo:c1", sections: sections(next), rows: next)
        XCTAssertFalse(update.update.isReset)
        XCTAssertEqual(update.update.reconfigured, [tasks[1].id])
        XCTAssertEqual(update.update.removed, [ListPath(section: MacItemsPaneSection.tasks.index, row: 4)])
        XCTAssertEqual(update.update.inserted, [ListPath(section: MacItemsPaneSection.done.index, row: 0)])

        let all = MacItemsPaneSource.publication(fromKey: "convo:c1", sections: sections(tasks), rows: shown,
                                                 toKey: "all", sections: sections(tasks), rows: tasks)
        XCTAssertTrue(all.update.isReset)
    }

    func test_source_publishesThePanesSections_andFollowsTheScopeAndTitles() async throws {
        let items = (1...6).map { task("t\($0)", Double($0), origin: $0 == 6 ? "c2" : "c1") }
            + [task("u1", 7, awaiting: .user)]
        let store = SettableItemsStore(items)
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: QuietItemsAPI(), sync: QuietItemsSync())
        vm.start()
        defer { vm.stop() }
        try await waitUntil { vm.sections.tasks.count == 7 }
        let titles = MacItemsPaneState()
        let source = MacItemsPaneSource(viewModel: vm, originTitles: { titles.originTitles })
        var iterator = source.publications().makeAsyncIterator()
        let first = try await next(&iterator)
        XCTAssertTrue(first.update.isReset)
        let firstSections = first.update.sections
        XCTAssertEqual(firstSections.map(\.key), MacItemsPaneSection.allCases.map(\.rawValue))
        // The task waiting on the user is under Needs you and under Tasks.
        XCTAssertEqual(firstSections[MacItemsPaneSection.needsYou.index].ids, ["needsYou:u1"])
        XCTAssertEqual(firstSections[MacItemsPaneSection.tasks.index].ids.count, 7)
        XCTAssertEqual(source.taskIDs, vm.sections.tasks.map(\.id))
        for row in first.rows {
            if case .item(_, let origin) = row.content { XCTAssertNil(origin, "This chat shows no origins") }
        }
        XCTAssertEqual(source.isEmpty, false)

        // A new task is an insert.
        store.set(items + [task("t8", 8)])
        var update = try await next(&iterator)
        while update.rows.count < 9 { update = try await next(&iterator) }
        XCTAssertFalse(update.update.isReset)
        XCTAssertEqual(update.update.inserted, [ListPath(section: MacItemsPaneSection.tasks.index, row: 7)])

        // All is another list, with origins; a title arriving re-renders the
        // rows it names.
        vm.scope = .all
        var all = try await next(&iterator)
        while !all.update.isReset { all = try await next(&iterator) }
        XCTAssertEqual(all.rows.first { $0.id == "tasks:t6" }?.content,
                       .item(vm.sections.tasks.first { $0.id == "t6" }!, origin: "Another chat"))
        titles.originTitles = ["c2": "Chat two"]
        var relabelled = try await next(&iterator)
        while relabelled.update.reconfigured.isEmpty { relabelled = try await next(&iterator) }
        XCTAssertEqual(relabelled.update.reconfigured, ["tasks:t6"])
        source.stop()
    }

    // MARK: The rows provider

    func test_rows_menuOffersOpenConversationInAllOnly_andActivateOpensTheItem() throws {
        let rows = MacItemsPaneRows()
        var opened: [String] = []
        var conversations: [String] = []
        rows.actions = .init(open: { opened.append($0.id) }, openConversation: { conversations.append($0) })
        let here = MacItemsPaneRow(item: task("t1", 1), section: .tasks, origin: nil)
        let there = MacItemsPaneRow(item: task("t2", 2, origin: "c9"), section: .tasks, origin: "Elsewhere")
        let shown = Dictionary(uniqueKeysWithValues: [here, there].map { ($0.id, $0) })
        rows.row = { shown[$0] }
        XCTAssertTrue(rows.menuItems(for: [here.id]).isEmpty)
        let menu = rows.menuItems(for: [there.id])
        XCTAssertEqual(menu.map(\.title), ["Open conversation"])
        let item = try XCTUnwrap(menu.first as? MacActionMenuItem)
        item.performForTesting()
        XCTAssertEqual(conversations, ["c9"])
        rows.activate([there.id])
        XCTAssertEqual(opened, ["t2"])

        let pending = MacItemsPaneRow(pending: .init(id: "p1", kind: .task, title: "P", isFailed: true, error: "x"))
        XCTAssertFalse(rows.canSelect(pending))
        XCTAssertTrue(rows.canSelect(here))
        XCTAssertEqual(rows.accessibilityLabel(for: pending), "P, failed, will retry")
        XCTAssertEqual(rows.sectionHeaderTitle("needsYou"), "Needs you")
    }

    func test_rows_onlyTasksDrag_andADropReportsTheIndexWithoutTheTask() {
        let rows = MacItemsPaneRows()
        let both = task("t1", 1, awaiting: .user)
        XCTAssertNotNil(rows.pasteboardWriter(for: MacItemsPaneRow(item: both, section: .tasks, origin: nil)))
        XCTAssertNil(rows.pasteboardWriter(for: MacItemsPaneRow(item: both, section: .needsYou, origin: nil)))

        var moves: [(String, Int)] = []
        func drop(from: Int, at: Int) { MacItemsPaneRows.drop("t", from: from, at: at) { moves.append(($0, $1)) } }
        drop(from: 0, at: 3)    // below the third task: index 2 once it has left
        drop(from: 3, at: 0)    // to the top
        drop(from: 2, at: 2)    // just above itself
        drop(from: 2, at: 3)    // just below itself
        XCTAssertEqual(moves.map(\.1), [2, 0])
    }

    // MARK: The host

    private func hostWindow(_ rows: MacItemsPaneRows) -> (MacListHost<MacItemsPaneRows>, NSWindow) {
        let host = MacListHost(rows: rows, style: .plain, accessibilityIdentifier: MacItemsAppKitList.accessibilityIdentifier)
        let window = MacSidebarRender.window(size: NSSize(width: 380, height: 900), appearance: .aqua, content: host.view)
        return (host, window)
    }

    func test_host_spacesEverySectionButTheFirst_andReMeasuresWhenTheFirstChanges() {
        let rows = MacItemsPaneRows()
        let (host, window) = hostWindow(rows)
        defer { window.close() }
        let needsYou = [MacItemsPaneRow(item: task("u1", 1, awaiting: .user), section: .needsYou, origin: nil)]
        let tasks = [MacItemsPaneRow(item: task("t1", 2), section: .tasks, origin: nil)]
        host.apply(ListPublication(update: .reset(sections(needsYou + tasks)), rows: needsYou + tasks))
        host.flushPendingUpdates()
        let table = host.tableView
        XCTAssertEqual(table.numberOfRows, 4)
        XCTAssertEqual(table.rect(ofRow: 0).height, MacItemsPaneRows.headerHeight)
        XCTAssertEqual(table.rect(ofRow: 2).height, MacItemsPaneRows.headerHeight + MacItemsPaneRows.headerSpacing)

        // A pending create above: Needs you's header is no longer first.
        let pending = [MacItemsPaneRow(pending: .init(id: "p1", kind: .task, title: "P", isFailed: false, error: nil))]
        let next = pending + needsYou + tasks
        let reloads = host.reloadCountForTesting
        host.apply(ListPublication(update: ListUpdate(from: sections(needsYou + tasks), to: sections(next),
                                                      touched: Set(pending.map(\.id))), rows: next))
        host.flushPendingUpdates()
        XCTAssertEqual(table.numberOfRows, 6)
        XCTAssertEqual(table.rect(ofRow: 0).height, MacItemsPaneRows.headerHeight)
        XCTAssertEqual(table.rect(ofRow: 2).height, MacItemsPaneRows.headerHeight + MacItemsPaneRows.headerSpacing)
        XCTAssertEqual(host.reloadCountForTesting, reloads, "the second publication was edits, not a reload")
    }

    func test_host_dropInTasks_movesTheTask_andRefusesOtherSections() throws {
        let rows = MacItemsPaneRows()
        var moves: [(String, Int)] = []
        rows.actions = .init(move: { moves.append(($0, $1)) })
        let tasks = (1...3).map { MacItemsPaneRow(item: task("t\($0)", Double($0)), section: .tasks, origin: nil) }
        let decisions = [MacItemsPaneRow(item: TrackerItem(id: "d1", num: 9, kind: .decision, title: "D",
                                                            originConvoID: "c1"), section: .decisions, origin: nil)]
        rows.taskIDs = { ["t1", "t2", "t3"] }
        let (host, window) = hostWindow(rows)
        defer { window.close() }
        host.apply(ListPublication(update: .reset(sections(tasks + decisions)), rows: tasks + decisions))
        host.flushPendingUpdates()
        let table = host.tableView
        // Tasks header 0, tasks 1-3, Decisions header 4, decision 5.
        XCTAssertEqual(table.numberOfRows, 6)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacItemsAppKitListTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([try XCTUnwrap(rows.pasteboardWriter(for: tasks[0]))])
        let info = FakeDraggingInfo(pasteboard)

        // Above the Decisions header is the end of Tasks.
        XCTAssertEqual(host.tableView(table, validateDrop: info, proposedRow: 4, proposedDropOperation: .above), .move)
        XCTAssertTrue(host.tableView(table, acceptDrop: info, row: 4, dropOperation: .above))
        XCTAssertEqual(moves.map(\.0), ["t1"])
        XCTAssertEqual(moves.map(\.1), [2])
        // Under Decisions: refused.
        XCTAssertEqual(host.tableView(table, validateDrop: info, proposedRow: 6, proposedDropOperation: .above), [])
        XCTAssertFalse(host.tableView(table, acceptDrop: info, row: 6, dropOperation: .above))
        // A drag from elsewhere: refused.
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        XCTAssertEqual(host.tableView(table, validateDrop: info, proposedRow: 2, proposedDropOperation: .above), [])
    }

    func test_host_dropPastTheLastTask_isTheEndOfTasks_whenTheSectionsAfterAreEmpty() throws {
        let rows = MacItemsPaneRows()
        var moves: [(String, Int)] = []
        rows.actions = .init(move: { moves.append(($0, $1)) })
        let tasks = (1...3).map { MacItemsPaneRow(item: task("t\($0)", Double($0)), section: .tasks, origin: nil) }
        rows.taskIDs = { ["t1", "t2", "t3"] }
        let (host, window) = hostWindow(rows)
        defer { window.close() }
        host.apply(ListPublication(update: .reset(sections(tasks)), rows: tasks))
        host.flushPendingUpdates()
        let table = host.tableView
        // Tasks header 0, tasks 1-3; Decisions and Done are empty.
        XCTAssertEqual(table.numberOfRows, 4)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacItemsAppKitListTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([try XCTUnwrap(rows.pasteboardWriter(for: tasks[0]))])
        let info = FakeDraggingInfo(pasteboard)
        XCTAssertEqual(host.tableView(table, validateDrop: info, proposedRow: 4, proposedDropOperation: .above), .move)
        XCTAssertTrue(host.tableView(table, acceptDrop: info, row: 4, dropOperation: .above))
        XCTAssertEqual(moves.map(\.1), [2])
    }

    // MARK: The mounted view

    func test_view_showsThePane_andARowClickOpensItsItem() async throws {
        let items = (1...4).map { task("t\($0)", Double($0)) }
        let vm = ItemsPanelViewModel(convoID: "c1", store: SettableItemsStore(items), api: QuietItemsAPI(),
                                     sync: QuietItemsSync())
        vm.start()
        defer { vm.stop() }
        try await waitUntil { vm.sections.tasks.count == 4 }
        var opened: [String] = []
        let view = MacItemsAppKitList(viewModel: vm, originTitles: { [:] }, onSelect: { opened.append($0.id) },
                                      onMove: { _, _ in }, onCreate: {}, onOpenConversation: { _ in })
        let hosting = NSHostingView(rootView: view)
        let window = MacSidebarRender.window(size: NSSize(width: 380, height: 500), appearance: .aqua, content: hosting)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        var table: NSTableView?
        try await waitUntil {
            table = MacSidebarRender.findTable(in: hosting)
            return table?.numberOfRows == 5
        }
        let list = try XCTUnwrap(table)
        XCTAssertEqual(list.accessibilityIdentifier(), MacItemsAppKitList.accessibilityIdentifier)
        // A selection outside a click (the arrow keys, type-select) only
        // selects; Return opens it.
        list.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(opened, [])
        XCTAssertEqual(list.selectedRow, 3)
        let returnKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                       characters: "\r", charactersIgnoringModifiers: "\r",
                                                       isARepeat: false, keyCode: 36))
        list.keyDown(with: returnKey)
        try await waitUntil { !opened.isEmpty }
        XCTAssertEqual(opened, [vm.sections.tasks[2].id])
    }

    func test_view_aClickOpens_aKeyOnlySelects() {
        XCTAssertTrue(MacItemsAppKitList.opensOnSelection(.leftMouseDown))
        XCTAssertTrue(MacItemsAppKitList.opensOnSelection(.leftMouseUp))
        XCTAssertFalse(MacItemsAppKitList.opensOnSelection(.keyDown))
        XCTAssertFalse(MacItemsAppKitList.opensOnSelection(nil))
    }

    // MARK: Helpers

    private func next(_ iterator: inout AsyncStream<MacItemsPaneSource.Publication>.Iterator) async throws
        -> MacItemsPaneSource.Publication {
        let next = await iterator.next()
        return try XCTUnwrap(next, "the stream ended")
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
