#if os(macOS)
import XCTest
import AppKit
import SwiftUI
@testable import MatronMac
import MatronDesignSystem
import MatronModels
import MatronJournal
import MatronViewModels

/// An items store whose all-items list the test sets (shared with the
/// items pane tests).
final class SettableItemsStore: ItemsStoreReading, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<[TrackerItem]>.Continuation] = []
    private var items: [TrackerItem]

    init(_ items: [TrackerItem]) { self.items = items }

    func set(_ items: [TrackerItem]) {
        let continuations = lock.withLock { () -> [AsyncStream<[TrackerItem]>.Continuation] in
            self.items = items
            return self.continuations
        }
        for continuation in continuations { continuation.yield(items) }
    }

    func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> {
        let (stream, continuation) = AsyncStream<[TrackerItem]>.makeStream()
        let items = lock.withLock { () -> [TrackerItem] in
            continuations.append(continuation)
            return self.items
        }
        continuation.yield(items)
        return stream
    }
    func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { _ in } }
    func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { _ in } }
    func comments(itemID: String) throws -> [TrackerComment] { [] }
    func item(id: String) throws -> TrackerItem? { nil }
    func itemOutboxRows(itemID: String) throws -> [ItemOutboxRecord] { [] }
    func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
    func itemOutboxCreatesStream() -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
}

final class QuietItemsSync: ItemsSyncing, @unchecked Sendable {
    func refresh(scope: ItemsScope) async -> ItemsRefreshOutcome { .succeeded }
    func refreshItem(id: String) async {}
    func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?) async {}
    func queueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async -> Bool { true }
    func enqueueCreate(localID: String, _ new: NewItem) async -> Bool { true }
    func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.finish() } }
}

final class QuietItemsAPI: ItemsProviding, @unchecked Sendable {
    func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { ItemsPage(items: [], nextCursor: nil) }
    func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) { throw JournalAPIError.notFound }
    func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { throw JournalAPIError.notFound }
    func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { throw JournalAPIError.notFound }
    func commentItem(id: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?, idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment?) { throw JournalAPIError.notFound }
    func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { throw JournalAPIError.notFound }
    func reopenItem(id: String, comment: String?) async throws -> TrackerItem { throw JournalAPIError.notFound }
    func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem { throw JournalAPIError.notFound }
    func uploadMedia(_ data: Data, contentType: String) async throws -> String { "b" }
}

@MainActor
final class MacDecisionsAppKitListTests: XCTestCase {
    typealias Fixtures = MacDecisionsFixtures

    // MARK: The flag

    func test_flag_isOnInDebugAndRelease_andReadsTheStoredChoice() throws {
        XCTAssertEqual(MacDecisionsListFlag.key, "list.appkit.decisions")
        XCTAssertTrue(MacDecisionsListFlag.defaultValue(isDebugBuild: true))
        XCTAssertTrue(MacDecisionsListFlag.defaultValue(isDebugBuild: false))
        let suite = "MacDecisionsAppKitListTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MacDecisionsListFlag.isOn(defaults), MacDecisionsListFlag.defaultValue)
        defaults.set(false, forKey: MacDecisionsListFlag.key)
        XCTAssertFalse(MacDecisionsListFlag.isOn(defaults))
        // A launch argument arrives as a string.
        defaults.set("YES", forKey: MacDecisionsListFlag.key)
        XCTAssertTrue(MacDecisionsListFlag.isOn(defaults))
        defaults.set("NO", forKey: MacDecisionsListFlag.key)
        XCTAssertFalse(MacDecisionsListFlag.isOn(defaults))
    }

    // MARK: Publications

    private func row(_ item: TrackerItem, origin: String = "Chat", closed: Bool = false) -> MacDecisionsRow {
        MacDecisionsRow(item: item, origin: origin, isClosedTab: closed)
    }

    private func item(_ id: String, _ num: Int, title: String = "T", origin: String = "c1") -> TrackerItem {
        let at = Fixtures.now.addingTimeInterval(TimeInterval(num))
        return TrackerItem(id: id, num: num, kind: .question, awaiting: .user, title: title, originConvoID: origin,
                           createdAt: at, updatedAt: at)
    }

    func test_publication_isAResetForTheFirstRowsAndATabChange() {
        let rows = [row(item("a", 1)), row(item("b", 2))]
        let first = MacDecisionsSource.publication(fromKey: nil, ids: [], rows: [:], toKey: "open", rows: rows)
        XCTAssertTrue(first.update.isReset)
        XCTAssertEqual(first.update.sections, [ListSection(key: "open", ids: ["a", "b"])])
        let tab = MacDecisionsSource.publication(fromKey: "open", ids: ["a", "b"],
                                                 rows: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }),
                                                 toKey: "closed", rows: [row(item("c", 3), closed: true)])
        XCTAssertTrue(tab.update.isReset)
    }

    func test_publication_namesOnlyTheRowsThatChanged() {
        let old = (1...10).map { row(item("r\($0)", $0)) }
        let byID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        // "new" arrives at the top, "r3" leaves, "r2" is retitled.
        var next = old
        next.remove(at: 2)
        next[1] = row(item("r2", 2, title: "New title"))
        next.insert(row(item("new", 11)), at: 0)
        let update = MacDecisionsSource.publication(fromKey: "open", ids: old.map(\.id), rows: byID, toKey: "open",
                                                    rows: next)
        XCTAssertFalse(update.update.isReset)
        XCTAssertEqual(update.update.inserted, [ListPath(section: 0, row: 0)])
        XCTAssertEqual(update.update.removed, [ListPath(section: 0, row: 2)])
        XCTAssertEqual(update.update.reconfigured, ["r2"])
        XCTAssertEqual(update.update.apply(to: [ListSection(key: "open", ids: old.map(\.id))]),
                       [ListSection(key: "open", ids: next.map(\.id))])

        // A new origin label is a content change too.
        var relabelled = old
        relabelled[4] = row(item("r5", 5), origin: "Other")
        let labelUpdate = MacDecisionsSource.publication(fromKey: "open", ids: old.map(\.id), rows: byID,
                                                         toKey: "open", rows: relabelled)
        XCTAssertEqual(labelUpdate.update.reconfigured, ["r5"])
        XCTAssertTrue(labelUpdate.update.inserted.isEmpty && labelUpdate.update.removed.isEmpty)

        // Unchanged rows publish no change.
        XCTAssertFalse(MacDecisionsSource.publication(fromKey: "open", ids: old.map(\.id), rows: byID, toKey: "open",
                                                      rows: old).update.hasChanges)
    }

    func test_rows_followTheTab_withShowMoreUnderTheDoneWindow() async throws {
        let open = (1...3).map { item("o\($0)", $0) }
        let closed = (1...55).map {
            TrackerItem(id: "d\($0)", num: 100 + $0, kind: .decision, state: .closed, resolution: .decided,
                        title: "D\($0)", originConvoID: "c2", closedAt: Fixtures.now.addingTimeInterval(TimeInterval(-$0)),
                        lastUserInputAt: Fixtures.now.addingTimeInterval(TimeInterval(-$0)))
        }
        let vm = ItemsPanelViewModel(convoID: nil, store: SettableItemsStore(open + closed), api: QuietItemsAPI(),
                                     sync: QuietItemsSync())
        vm.start()
        defer { vm.stop() }
        try await waitUntil { vm.awaitingYou.count == 3 && vm.decided.count == 55 }
        let labels = ItemOriginLabels(labels: ["c1": "Chat one"])

        let openRows = MacDecisionsSource.rows(viewModel: vm, labels: labels)
        XCTAssertEqual(openRows.key, "open")
        XCTAssertEqual(openRows.rows.map(\.id), vm.awaitingYou.map(\.id))
        XCTAssertEqual(openRows.rows.first?.content, .item(vm.awaitingYou[0], origin: "Chat one", isClosedTab: false))

        vm.forYouTab = .closed
        let closedRows = MacDecisionsSource.rows(viewModel: vm, labels: labels)
        XCTAssertEqual(closedRows.key, "closed")
        XCTAssertEqual(closedRows.rows.count, 51, "the latest 50, then Show more")
        XCTAssertEqual(closedRows.rows.last, .showMore)
        // An origin with no label reads "Another chat", as in the SwiftUI list.
        XCTAssertEqual(closedRows.rows.first?.content,
                       .item(vm.decided[0], origin: "Another chat", isClosedTab: true))
        vm.showMoreDecided()
        XCTAssertEqual(MacDecisionsSource.rows(viewModel: vm, labels: labels).rows.count, 55)
    }

    func test_source_publishesTheViewModelsRows_thenEditsThem() async throws {
        let items = (1...6).map { item("r\($0)", $0, origin: $0 == 6 ? "c2" : "c1") }
        let store = SettableItemsStore(items)
        let vm = ItemsPanelViewModel(convoID: nil, store: store, api: QuietItemsAPI(), sync: QuietItemsSync())
        vm.start()
        defer { vm.stop() }
        try await waitUntil { vm.awaitingYou.count == 6 }
        let labels = MacOriginLabels()
        let source = MacDecisionsSource(viewModel: vm, originLabels: labels)
        XCTAssertNil(source.isEmpty)
        var iterator = source.publications().makeAsyncIterator()
        let first = try await next(&iterator)
        XCTAssertTrue(first.update.isReset)
        XCTAssertEqual(first.rows.map(\.id), vm.awaitingYou.map(\.id))
        XCTAssertEqual(source.isEmpty, false)

        // A new item is an insert, not a reload.
        store.set(items + [item("r7", 7)])
        var update = try await next(&iterator)
        while update.rows.count < 7 { update = try await next(&iterator) }
        XCTAssertFalse(update.update.isReset)
        XCTAssertEqual(update.update.inserted.count, 1)

        // A label arriving re-renders the rows it names, in place.
        labels.labels = ItemOriginLabels(labels: ["c2": "Chat two"])
        let relabelled = try await next(&iterator)
        XCTAssertFalse(relabelled.update.isReset)
        XCTAssertEqual(relabelled.update.reconfigured, ["r6"])
        XCTAssertEqual(relabelled.rows.first { $0.id == "r6" }?.content,
                       .item(vm.awaitingYou.first { $0.id == "r6" }!, origin: "Chat two", isClosedTab: false))

        // The other tab is a new list; with nothing in it, the list is empty.
        vm.forYouTab = .closed
        let done = try await next(&iterator)
        XCTAssertTrue(done.update.isReset)
        XCTAssertTrue(done.rows.isEmpty)
        XCTAssertEqual(source.isEmpty, true)
        source.stop()
    }

    // MARK: The cell

    func test_captionParts_inItemRowsOrder() {
        let open = Fixtures.open()
        XCTAssertEqual(MacItemRowCell.captionParts(for: open[0], origin: "P", closedCaption: nil),
                       [.origin("P"), .mission("#61"), .status("Needs you", .needsYou), .comments("3")])
        XCTAssertEqual(MacItemRowCell.captionParts(for: open[1], origin: "O", closedCaption: nil),
                       [.origin("O"), .status("To read", .notice)])
        XCTAssertEqual(MacItemRowCell.captionParts(for: open[3], origin: "P", closedCaption: nil),
                       [.consent, .origin("P"), .status("Needs you", .needsYou)])
        let closed = Fixtures.closed()
        XCTAssertEqual(MacItemRowCell.captionParts(for: closed[0], origin: "P", closedCaption: "Answered · 2h ago"),
                       [.origin("P"), .status("Answered · 2h ago", .quiet)])
        XCTAssertEqual(MacItemRowCell.captionParts(for: closed[2], origin: "E", closedCaption: nil),
                       [.origin("E"), .status("With the agent", .quiet)])
    }

    func test_title_wrapsOnTwoLines_withoutLeavingOneWordAlone() {
        let item = TrackerItem(id: "n", num: 1, kind: .notice, title: "Nightly backup finished with warnings",
                               originConvoID: "c1")
        let title = MacItemRowCell.titleString(item, color: .labelColor)
        let width = title.size().width - 10
        let lines = MacItemRowCell.titleLines(title, width: width)
        XCTAssertEqual(lines.count, 2)
        let second = CTLineGetStringRange(lines[1])
        let rest = (item.title as NSString).substring(from: second.location)
        XCTAssertEqual(rest, "with warnings", "the line before gives up its last word")

        // Past two lines, the second is truncated.
        let long = TrackerItem(id: "l", num: 2, kind: .question, title: String(repeating: "word ", count: 40),
                               originConvoID: "c1")
        XCTAssertEqual(MacItemRowCell.titleLines(MacItemRowCell.titleString(long, color: .labelColor), width: 200).count, 2)
    }

    func test_cell_configureIsIdempotent_andShowsSeenOnlyOnTheNeedsYouTab() {
        let cell = MacItemRowCell(frame: NSRect(x: 0, y: 0, width: 380, height: 75))
        let notice = Fixtures.open()[1]
        XCTAssertTrue(cell.configure(notice, origin: "Ops desk", isClosedTab: false, now: Fixtures.now))
        XCTAssertFalse(cell.configure(notice, origin: "Ops desk", isClosedTab: false, now: Fixtures.now))
        XCTAssertFalse(cell.seenButton.isHidden)
        XCTAssertEqual(cell.seenButton.accessibilityLabel(), "Seen: \(notice.title)")
        var seen = 0
        cell.onSeen = { seen += 1 }
        cell.seenButton.performClick(nil)
        XCTAssertEqual(seen, 1)

        XCTAssertTrue(cell.configure(notice, origin: "Ops desk", isClosedTab: true, now: Fixtures.now))
        XCTAssertTrue(cell.seenButton.isHidden, "the Done tab draws no Seen button")
        XCTAssertTrue(cell.configure(Fixtures.open()[0], origin: "P", isClosedTab: false, now: Fixtures.now))
        XCTAssertTrue(cell.seenButton.isHidden)
    }

    func test_heights_followTheContent() {
        let open = Fixtures.open()
        func height(_ item: TrackerItem, closed: Bool = false) -> CGFloat {
            MacItemRowCell.height(for: item, origin: Fixtures.origin(item), isClosedTab: closed, width: 380)
        }
        // The SwiftUI list's measured row heights (the last, a consent
        // ask, adds its answers' line).
        XCTAssertEqual(open.map { height($0) }, [60, 75, 59, 45, 52, 60, 71])
        XCTAssertEqual(Fixtures.closed().map { height($0, closed: true) }, [43, 60, 43, 43])
    }

    // MARK: The rows

    func test_menu_offersSeenOnANoticeOnTheNeedsYouTab_thenOpenConversation() throws {
        let rows = MacDecisionsRows()
        var seen: [String] = [], opened: [String] = []
        rows.actions = .init(open: { _ in }, openConversation: { opened.append($0) }, seen: { seen.append($0) })
        let notice = Fixtures.open()[1]
        rows.configure(MacItemRowCell(frame: .zero), with: MacDecisionsRow(item: notice, origin: "O", isClosedTab: false))
        let items = rows.menuItems(for: [notice.id])
        XCTAssertEqual(items.map(\.title), ["Seen", "Open conversation"])
        try XCTUnwrap(items[0] as? MacActionMenuItem).performForTesting()
        try XCTUnwrap(items[1] as? MacActionMenuItem).performForTesting()
        XCTAssertEqual(seen, [notice.id])
        XCTAssertEqual(opened, [notice.originConvoID])

        let closed = Fixtures.closed()[0]
        rows.configure(MacItemRowCell(frame: .zero), with: MacDecisionsRow(item: closed, origin: "P", isClosedTab: true))
        XCTAssertEqual(rows.menuItems(for: [closed.id]).map(\.title), ["Open conversation"])
        XCTAssertTrue(rows.menuItems(for: ["unknown"]).isEmpty)
    }

    func test_activate_opensTheItem_orGrowsTheDoneWindow() {
        let rows = MacDecisionsRows()
        var opened: [String] = [], more = 0
        rows.actions = .init(open: { opened.append($0) }, showMore: { more += 1 })
        rows.activate(["i1", "i2"])
        rows.activate([MacDecisionsRow.showMoreID])
        rows.activate([])
        XCTAssertEqual(opened, ["i1"])
        XCTAssertEqual(more, 1)
        XCTAssertEqual(rows.cellKind(for: .showMore), MacDecisionsRows.showMoreKind)
        XCTAssertEqual(rows.cellKind(for: Fixtures.rows(Fixtures.open(), closed: false)[0]), MacDecisionsRows.itemKind)
    }

    func test_host_drawsEveryRowAtItsHeight_andShowMoreIsAButton() throws {
        let rows = MacDecisionsRows()
        rows.now = { Fixtures.now }
        var more = 0
        rows.actions = .init(showMore: { more += 1 })
        let host = MacListHost(rows: rows, style: .plain, accessibilityIdentifier: MacDecisionsAppKitList.accessibilityIdentifier)
        let window = MacSidebarRender.window(size: NSSize(width: 380, height: 600), appearance: .aqua, content: host.view)
        defer { window.close() }
        host.scrollView.scrollerStyle = .overlay
        host.apply(Fixtures.publication(Fixtures.rows(Fixtures.closed(), closed: true, hasMore: true)))
        host.flushPendingUpdates()
        host.tableView.layoutSubtreeIfNeeded()
        XCTAssertEqual((0..<host.tableView.numberOfRows).map { host.tableView.rect(ofRow: $0).height },
                       [43, 60, 43, 43, 24])
        let cell = try XCTUnwrap(host.tableView.view(atColumn: 0, row: 4, makeIfNecessary: true) as? MacDecisionsShowMoreCell)
        cell.button.performClick(nil)
        XCTAssertEqual(more, 1)
        XCTAssertTrue(host.selection.isEmpty, "a click on Show more selects nothing")
    }

    /// A real click (mouse down and up through the window) on a row's
    /// button runs the button and selects nothing.
    func test_clicksOnSeenAndShowMore_runTheButton_andSelectNoRow() throws {
        let rows = MacDecisionsRows()
        rows.now = { Fixtures.now }
        var seen: [String] = [], more = 0, opened: [String] = []
        rows.actions = .init(open: { opened.append($0) }, seen: { seen.append($0) }, showMore: { more += 1 })
        let host = MacListHost(rows: rows, style: .plain, accessibilityIdentifier: MacDecisionsAppKitList.accessibilityIdentifier)
        var reported: [Set<String>] = []
        host.onSelectionChange = { reported.append($0) }
        let window = MacSidebarRender.window(size: NSSize(width: 380, height: 600), appearance: .aqua, content: host.view)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        host.scrollView.scrollerStyle = .overlay
        let notice = Fixtures.open()[1]
        let list = [MacDecisionsRow(item: Fixtures.open()[0], origin: "P", isClosedTab: false),
                    MacDecisionsRow(item: notice, origin: "O", isClosedTab: false), .showMore]
        host.apply(Fixtures.publication(list))
        host.flushPendingUpdates()
        window.contentView?.layoutSubtreeIfNeeded()
        host.tableView.layoutSubtreeIfNeeded()

        func click(_ view: NSView) {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                   pressure: 1)!
            }
            // The up waits in the queue for the tracking loop the down
            // starts (a button's, or the table's).
            NSApp.postEvent(event(.leftMouseUp), atStart: false)
            window.sendEvent(event(.leftMouseDown))
            // Drain an up no tracking loop took.
            while let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                window.sendEvent(pending)
            }
        }
        let cell = try XCTUnwrap(host.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true) as? MacItemRowCell)
        click(cell.seenButton)
        let moreCell = try XCTUnwrap(host.tableView.view(atColumn: 0, row: 2, makeIfNecessary: true) as? MacDecisionsShowMoreCell)
        click(moreCell.button)
        XCTAssertEqual(seen, [notice.id])
        XCTAssertEqual(more, 1)
        XCTAssertTrue(host.selection.isEmpty, "\(host.selection)")
        XCTAssertTrue(reported.isEmpty)
        XCTAssertTrue(opened.isEmpty)

        // Nor can the keyboard land on Show more.
        XCTAssertFalse(host.tableView(host.tableView, shouldSelectRow: 2))
        XCTAssertTrue(host.tableView(host.tableView, shouldSelectRow: 1))

        // A click elsewhere on a row still selects it.
        click(cell)
        XCTAssertEqual(host.selection, [notice.id])
    }

    // MARK: The view

    func test_view_showsTheViewModelsRows_andARowClickOpensItsItem() async throws {
        let items = (1...4).map { item("r\($0)", $0) }
        let vm = ItemsPanelViewModel(convoID: nil, store: SettableItemsStore(items), api: QuietItemsAPI(),
                                     sync: QuietItemsSync())
        vm.start()
        defer { vm.stop() }
        try await waitUntil { vm.awaitingYou.count == 4 }
        var opened: [String] = []
        let view = MacDecisionsAppKitList(vm: vm, originLabels: MacOriginLabels(), selectedID: nil,
                                          onSelect: { opened.append($0) }, onOpenConversation: { _ in })
        let hosting = NSHostingView(rootView: view)
        let window = MacSidebarRender.window(size: NSSize(width: 380, height: 500), appearance: .aqua, content: hosting)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        var table: NSTableView?
        try await waitUntil {
            table = MacSidebarRender.findTable(in: hosting)
            return table?.numberOfRows == 4
        }
        let list = try XCTUnwrap(table)
        XCTAssertEqual(list.accessibilityIdentifier(), MacDecisionsAppKitList.accessibilityIdentifier)
        let row = 2
        list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        try await waitUntil { !opened.isEmpty }
        XCTAssertEqual(opened, [vm.awaitingYou[row].id])
    }

    // MARK: Helpers

    /// The stream's next publication (the test's own timeout catches a
    /// stream that goes quiet).
    private func next(_ iterator: inout AsyncStream<MacDecisionsSource.Publication>.Iterator) async throws
        -> MacDecisionsSource.Publication {
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
