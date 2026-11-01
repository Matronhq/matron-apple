#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac
import MatronChat
import MatronJournal
import MatronModels
import MatronViewModels

/// The sidebar's AppKit list: `MacChatSidebarList` mounting it, and the
/// list in a window: selection both ways with the window's
/// conversation, multi-selection, Return, and the context menu's targets.
@MainActor
final class MacSidebarAppKitListTests: XCTestCase {
    // MARK: Mounting

    /// Mounts `MacChatSidebarList` and returns the window and whether the
    /// AppKit list (`sidebar.list`) is in it.
    func mountSidebar(store: JournalStore) -> (NSWindow, Bool) {
        let viewModel = ChatListViewModel(chat: SidebarFakeChatService())
        let view = MacChatSidebarList(viewModel: viewModel, selection: .constant(nil), runChatAction: { _ in },
                                      journalStore: store)
            .frame(width: 280, height: 400)
        let host = NSHostingView(rootView: view)
        let window = MacSidebarRender.window(size: NSSize(width: 280, height: 400), appearance: .aqua, content: host)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let table = MacSidebarRender.findTable(in: host)
        return (window, table?.accessibilityIdentifier() == MacSidebarAppKitList.accessibilityIdentifier)
    }

    func test_sidebar_drawsTheAppKitListWithAStore() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        let (window, isAppKit) = mountSidebar(store: store)
        XCTAssertTrue(isAppKit)
        window.close()
    }

    // MARK: Selection rules

    func test_selectionRules_listToWindow() {
        XCTAssertNil(MacSidebarSelection.window(after: [], current: "a"))
        XCTAssertEqual(MacSidebarSelection.window(after: ["b"], current: "a"), "b")
        XCTAssertEqual(MacSidebarSelection.window(after: ["a", "b"], current: "a"), "a",
                       "several rows: the detail keeps its chat")
        XCTAssertNil(MacSidebarSelection.window(after: ["a", "b"], current: nil))
    }

    func test_selectionRules_windowToList() {
        XCTAssertEqual(MacSidebarSelection.list(after: "b", current: ["b"]), ["b"], "the list's own echo")
        XCTAssertEqual(MacSidebarSelection.list(after: "c", current: ["a", "b"]), ["c"])
        XCTAssertEqual(MacSidebarSelection.list(after: "c", current: []), ["c"])
        XCTAssertEqual(MacSidebarSelection.list(after: nil, current: ["a"]), [])
    }

    func test_selectionRules_roundTripNeverEchoes() {
        // The user picks b: the window follows, and the window's change
        // leaves the list as it is.
        let list: Set<String> = ["b"]
        let window = MacSidebarSelection.window(after: list, current: "a")
        XCTAssertEqual(MacSidebarSelection.list(after: window, current: list), list)
        // The user extends to a and b: the window stays, so nothing comes back.
        XCTAssertEqual(MacSidebarSelection.window(after: ["a", "b"], current: "b"), "b")
    }

    // MARK: The list in a window

    /// The window's selected conversation, observed like the window's
    /// own state is.
    @Observable final class Box {
        var selection: String?
        var archived: [[String]] = []
    }

    @MainActor struct Mounted {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let table: MacListTableView
        let box: Box
        let chat: SidebarFakeChatService

        func row(of id: String) -> Int {
            guard let host = table.dataSource as? MacListHost<MacSidebarChatRows> else { return -1 }
            return host.tableRow(of: id) ?? -1
        }

        var listHost: MacListHost<MacSidebarChatRows> { table.dataSource as! MacListHost<MacSidebarChatRows> }

        func spin(_ seconds: TimeInterval = 0.05) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
            listHost.flushPendingUpdates()
            host.layoutSubtreeIfNeeded()
        }

        func close() { window.close() }
    }

    func mountList() throws -> Mounted {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        let now = Date()
        let ms = { (date: Date) in Int64(date.timeIntervalSince1970 * 1000) }
        let start = Calendar.current.startOfDay(for: now)
        try store.applyColdSnapshot((1...8).map { i in
            ConvoSummaryDTO(id: "c\(i)", title: ["Quarterly planning notes", "Fix the flaky login test",
                                                 "Release checklist", "Onboarding docs review",
                                                 "Shared API contract", "Garden irrigation timer",
                                                 "Recipe scaler script", "Photo library cleanup"][i - 1],
                            sessionState: "idle", lastSeq: Int64(i), snippet: "Snippet \(i)",
                            createdAt: ms(start) - 86_400_000 * 30,
                            lastTS: ms(start) - Int64(i) * 3_600_000)
        }, headSeq: 0)
        let box = Box()
        let chat = SidebarFakeChatService()
        let viewModel = ChatListViewModel(chat: chat)
        let source = MacSidebarChatSource(viewModel: viewModel, notifyStore: nil, store: store)
        let selection = Binding(get: { box.selection }, set: { box.selection = $0 })
        let runChatAction: (@escaping (ChatService) async throws -> Void) -> Void = { action in
            Task { try? await action(chat) }
        }
        let view = AnyView(MacSidebarAppKitList(viewModel: viewModel, selection: selection,
                                                runChatAction: runChatAction, notifyStore: nil, onPin: nil,
                                                onShowArchived: nil, source: source)
            .frame(width: 280, height: 600))
        let host = NSHostingView(rootView: view)
        let window = MacSidebarRender.window(size: NSSize(width: 280, height: 600), appearance: .aqua, content: host)
        window.orderFront(nil)
        var table: MacListTableView?
        for _ in 0..<200 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            table = MacSidebarRender.findTable(in: host) as? MacListTableView
            // Off screen, the frame coalescer has no display to tick with.
            (table?.dataSource as? MacListHost<MacSidebarChatRows>)?.flushPendingUpdates()
            if let table, table.numberOfRows >= 9 { break }
        }
        let mounted = Mounted(window: window, host: host, table: try XCTUnwrap(table), box: box, chat: chat)
        XCTAssertEqual(mounted.table.numberOfRows, 9, "a header and eight rows")
        return mounted
    }

    /// A stall in the AppKit sidebar names it: the host notes each
    /// publication, pass and cell under the sidebar's own labels.
    func test_stallNotes_nameTheSidebar() throws {
        StallCauseRecorder.shared.beginTally()
        let m = try mountList()
        defer { m.close() }
        // Off screen the table makes no row views until asked for one.
        for row in 1..<m.table.numberOfRows { _ = m.table.view(atColumn: 0, row: row, makeIfNecessary: true) }
        let tally = StallCauseRecorder.shared.endTally()
        XCTAssertGreaterThan(tally["SidebarAppKit.body", default: 0], 0)
        XCTAssertGreaterThan(tally["Sidebar.apply", default: 0], 0)
        XCTAssertGreaterThan(tally["Sidebar.pass", default: 0], 0)
        XCTAssertGreaterThanOrEqual(tally["Sidebar.cell", default: 0], 8, "one per row made")
        XCTAssertNil(tally["ListHost.pass"], "the sidebar never falls back to the generic labels")
    }

    func test_windowSelection_selectsTheRow_andTheUsersSelectionReachesTheWindow() throws {
        let m = try mountList()
        defer { m.close() }

        // From the window (search, a link, a notification): the row selects.
        m.box.selection = "c5"
        for _ in 0..<50 where m.listHost.selection != ["c5"] { m.spin() }
        XCTAssertEqual(m.listHost.selection, ["c5"])
        XCTAssertEqual(m.table.selectedRow, m.row(of: "c5"))

        // From the user: the window follows.
        m.table.selectRowIndexes(IndexSet(integer: m.row(of: "c2")), byExtendingSelection: false)
        for _ in 0..<50 where m.box.selection != "c2" { m.spin() }
        XCTAssertEqual(m.box.selection, "c2")
        XCTAssertEqual(m.listHost.selection, ["c2"], "no echo back to the list")

        // ⌘-click a second row: the list holds both, the window keeps c2.
        m.table.selectRowIndexes(IndexSet(integer: m.row(of: "c4")), byExtendingSelection: true)
        m.spin(0.2)
        XCTAssertEqual(m.listHost.selection, ["c2", "c4"])
        XCTAssertEqual(m.box.selection, "c2")
        XCTAssertEqual(Set(m.listHost.orderedSelection), ["c2", "c4"], "the multi-selection survives")
    }

    func test_menu_targetsTheClickedRowOrTheSelection_andArchivesThem() throws {
        let m = try mountList()
        defer { m.close() }
        m.table.selectRowIndexes(IndexSet([m.row(of: "c1"), m.row(of: "c3")]), byExtendingSelection: false)
        m.spin(0.2)

        // A row outside the selection: itself.
        m.table.clickedRowOverrideForTesting = m.row(of: "c6")
        m.listHost.menuNeedsUpdate(m.listHost.contextMenu)
        XCTAssertEqual(m.listHost.contextMenu.items.map(\.title), ["Archive"])

        // A row inside it: the whole selection.
        m.table.clickedRowOverrideForTesting = m.row(of: "c3")
        m.listHost.menuNeedsUpdate(m.listHost.contextMenu)
        XCTAssertEqual(m.listHost.contextMenu.items.map(\.title), ["Archive 2 Conversations"])
        (m.listHost.contextMenu.items.first as? MacActionMenuItem)?.performForTesting()
        for _ in 0..<100 where m.chat.archived.isEmpty { m.spin() }
        XCTAssertEqual(m.chat.archived, [["c1", "c3"]])
        XCTAssertFalse(["c1", "c3"].contains(m.box.selection ?? ""), "an archived chat is not left selected")
        XCTAssertTrue(m.listHost.selection.isDisjoint(with: ["c1", "c3"]), "archived rows leave the selection")

        // Empty space and headers: no menu.
        m.table.clickedRowOverrideForTesting = -1
        m.listHost.menuNeedsUpdate(m.listHost.contextMenu)
        XCTAssertTrue(m.listHost.contextMenu.items.isEmpty)
        m.table.clickedRowOverrideForTesting = 0
        m.listHost.menuNeedsUpdate(m.listHost.contextMenu)
        XCTAssertTrue(m.listHost.contextMenu.items.isEmpty)
    }

    func test_returnAndDoubleClick_openTheChat() throws {
        let m = try mountList()
        defer { m.close() }
        m.table.selectRowIndexes(IndexSet([m.row(of: "c7"), m.row(of: "c8")]), byExtendingSelection: false)
        m.spin(0.2)
        m.listHost.activateSelection()
        for _ in 0..<50 where m.box.selection != "c7" { m.spin() }
        XCTAssertEqual(m.box.selection, "c7")
        for _ in 0..<50 where m.listHost.selection != ["c7"] { m.spin() }
        XCTAssertEqual(m.listHost.selection, ["c7"], "opening narrows the selection to the chat")

        m.table.clickedRowOverrideForTesting = m.row(of: "c3")
        m.table.sendAction(m.table.doubleAction, to: m.table.target)
        for _ in 0..<50 where m.box.selection != "c3" { m.spin() }
        XCTAssertEqual(m.box.selection, "c3")
    }

    func test_accessibility_andTypeSelect() throws {
        let m = try mountList()
        defer { m.close() }
        XCTAssertEqual(m.table.accessibilityIdentifier(), "sidebar.list")
        let row = m.row(of: "c2")
        let label = m.listHost.tableView(m.table, typeSelectStringFor: nil, row: row)
        XCTAssertEqual(label, "Fix the flaky login test")
        let cell = try XCTUnwrap(m.table.view(atColumn: 0, row: row, makeIfNecessary: true))
        XCTAssertTrue(cell.accessibilityLabel()?.hasPrefix("Fix the flaky login test, Snippet 2, ") == true,
                      cell.accessibilityLabel() ?? "nil")
        XCTAssertTrue(m.listHost.hasMinuteTimerForTesting, "the minute tick runs while the list is in a window")
    }
}
#endif
