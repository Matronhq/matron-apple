#if os(macOS)
import XCTest
import AppKit
import SwiftUI
@testable import MatronMac
import MatronModels
import MatronJournal
import MatronViewModels

/// The Decisions origin labels load with the window, not with the column:
/// opening Decisions must find them already there.
private final class OneItemStore: ItemsStoreReading, @unchecked Sendable {
    let items: [TrackerItem]
    init(_ items: [TrackerItem]) { self.items = items }
    func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> {
        let items = items
        return AsyncStream { $0.yield(items) }
    }
    func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { _ in } }
    func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { _ in } }
    func comments(itemID: String) throws -> [TrackerComment] { [] }
    func item(id: String) throws -> TrackerItem? { nil }
    func itemOutboxRows(itemID: String) throws -> [ItemOutboxRecord] { [] }
    func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
    func itemOutboxCreatesStream() -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
}

private final class NoopItemsSync: ItemsSyncing, @unchecked Sendable {
    func refresh(scope: ItemsScope) async -> ItemsRefreshOutcome { .succeeded }
    func refreshItem(id: String) async {}
    func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?) async {}
    func queueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async -> Bool { true }
    func enqueueCreate(localID: String, _ new: NewItem) async -> Bool { true }
    func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.finish() } }
}

private final class NoopItemsAPI: ItemsProviding, @unchecked Sendable {
    func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { ItemsPage(items: [], nextCursor: nil) }
    func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) { throw JournalAPIError.notFound }
    func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { throw JournalAPIError.notFound }
    func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { throw JournalAPIError.notFound }
    func commentItem(id: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?, idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) { throw JournalAPIError.notFound }
    func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { throw JournalAPIError.notFound }
    func reopenItem(id: String, comment: String?) async throws -> TrackerItem { throw JournalAPIError.notFound }
    func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem { throw JournalAPIError.notFound }
    func uploadMedia(_ data: Data, contentType: String) async throws -> String { "b" }
}

@MainActor
final class MacOriginLabelsFeedTests: XCTestCase {
    func test_theFeedLoadsTheLabelsWithNoColumnOnScreen() async throws {
        let item = TrackerItem(id: "q", num: 1, kind: .question, awaiting: .user, title: "Q", originConvoID: "c1")
        let vm = ItemsPanelViewModel(convoID: nil, store: OneItemStore([item]), api: NoopItemsAPI(), sync: NoopItemsSync())
        vm.start()
        defer { vm.stop() }
        let labels = MacOriginLabels()
        let host = NSHostingView(rootView: MacOriginLabelsFeed(vm: vm, labels: labels) {
            ItemOriginLabels(labels: ["c1": "Chat one"])
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let deadline = Date().addingTimeInterval(2)
        while labels.labels.label(for: item) == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(labels.labels.label(for: item), "Chat one")
    }
}
#endif
