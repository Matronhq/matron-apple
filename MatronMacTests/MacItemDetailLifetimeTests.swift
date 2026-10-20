#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronJournal
import MatronModels
import MatronStorage
import MatronViewModels

@MainActor @Observable
private final class SelectionBox {
    var itemID: String?
    init(_ itemID: String?) { self.itemID = itemID }
}

/// An item's detail view model lives while its item is shown, and no
/// longer. Moving through items on the stackless surface (Decisions, For
/// you) must release each one: a view model left behind keeps its item,
/// comments and closures for the life of the app.
@MainActor
final class MacItemDetailLifetimeTests: XCTestCase {
    private var window: NSWindow?
    private var deps: AppDependencies?
    private var storeFile: URL?

    override func tearDown() async throws {
        window?.close()
        window = nil
        await deps?.stopMaintenanceForTests()
        deps = nil
        UserDefaults.standard.removeObject(forKey: MacItemThreadFlag.key)
        if let storeFile {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: storeFile.path + suffix) }
        }
        try await super.tearDown()
    }

    func test_movingThroughItems_releasesEachViewModel_nativeThread() async throws {
        try await assertMovingThroughItemsReleasesThem(nativeThread: true)
    }

    func test_movingThroughItems_releasesEachViewModel_swiftUIThread() async throws {
        try await assertMovingThroughItemsReleasesThem(nativeThread: false)
    }

    private func assertMovingThroughItemsReleasesThem(nativeThread: Bool, file: StaticString = #filePath,
                                                      line: UInt = #line) async throws {
        UserDefaults.standard.set(nativeThread, forKey: MacItemThreadFlag.key)
        let ids = (0..<5).map { "it-\($0)" }
        let (box, state) = try await mount(ids: ids)
        var released: [String: WeakBox] = [:]
        for id in ids {
            box.itemID = id
            try await waitUntil { state.slots[id]?.viewModel?.item != nil }
            await Self.spin(seconds: 0.5)
            released[id] = WeakBox(state.slots[id]?.viewModel)
        }
        box.itemID = nil
        await Self.spin(seconds: 0.5)
        state.releaseAllSlots()
        await Self.spin(seconds: 1)
        let alive = ids.filter { released[$0]?.value != nil }
        XCTAssertEqual(alive, [], "view models still alive after their item left (native thread: \(nativeThread))",
                       file: file, line: line)
    }

    private func mount(ids: [String]) async throws -> (SelectionBox, MacItemsPaneState) {
        let userID = "lifetime-\(UUID().uuidString.prefix(8))"
        let session = UserSession(userID: userID, deviceID: "lifetime-device",
                                  homeserverURL: URL(string: "https://journal.invalid")!, accessToken: "lifetime")
        let deps = AppDependencies()
        self.deps = deps
        storeFile = StoragePaths.appSupport.appendingPathComponent("journal-store/\(userID).sqlite")
        try Self.seed(deps.journalStore(for: session), ids: ids)

        let box = SelectionBox(nil)
        let state = MacItemsPaneState(surfaceName: "decisions")
        let root = LifetimeHost(box: box, session: session, state: state)
            .environment(\.appDependencies, deps)
            .environment(\.currentSession, session)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 900, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(NSSize(width: 900, height: 700))
        window.orderFront(nil)
        self.window = window
        await Self.spin(seconds: 1)
        return (box, state)
    }

    /// Made-up items, each with a body, actions and a couple of comments.
    private static func seed(_ store: JournalStore, ids: [String]) throws {
        let now = Date()
        let ts = Int64(now.timeIntervalSince1970 * 1000)
        try store.applyColdSnapshot([ConvoSummaryDTO(id: "c-1", title: "Desktop app polish", sessionState: "idle",
                                                     lastSeq: 0, snippet: "", createdAt: ts - 86_400_000, lastTS: ts)],
                                    headSeq: 0)
        try store.upsertItems(ids.enumerated().map { i, id in
            TrackerItem(id: id, num: 4_300 + i, kind: i.isMultiple(of: 2) ? .question : .task, awaiting: .user,
                        rank: Double(i) * 1024, title: "Pick a colour for icon \(i)",
                        body: "Two options: blue or green. I recommend blue.",
                        originConvoID: "c-1", createdAt: now.addingTimeInterval(-Double(i) * 3_600),
                        updatedAt: now.addingTimeInterval(-Double(i) * 60),
                        actions: i.isMultiple(of: 2) ? ["Blue", "Green"] : [])
        })
        for id in ids {
            try store.replaceComments(itemID: id, (0..<2).map { c in
                TrackerComment(id: "\(id)-cm-\(c)", itemID: id, author: c == 0 ? .agent : .user,
                               body: "Comment \(c) on \(id).", createdAt: now.addingTimeInterval(-Double(600 - c)))
            })
        }
    }

    private static func spin(seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }
}

/// The Decisions detail column: one stackless host for the selected item.
private struct LifetimeHost: View {
    let box: SelectionBox
    let session: UserSession
    let state: MacItemsPaneState

    var body: some View {
        if let id = box.itemID {
            MacItemDetailHost(itemID: id, session: session, currentConvoID: nil, state: state,
                              onOpenConversation: { _ in }, onOpenItem: { box.itemID = $0 }, surface: .stackless)
        } else {
            Text("Select an item")
        }
    }
}

private final class WeakBox {
    weak var value: ItemDetailViewModel?
    init(_ value: ItemDetailViewModel?) { self.value = value }
}
#endif
