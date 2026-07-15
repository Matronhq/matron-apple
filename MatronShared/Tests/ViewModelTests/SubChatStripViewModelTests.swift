import XCTest
import MatronChat
import MatronModels
@testable import MatronViewModels

/// Minimal `ChatService` fake that drives `children(of:)` from a
/// continuation the test controls, so it can push child-list snapshots one
/// at a time and assert the view model reacts. Every other method is an
/// inert stub — the strip VM only touches `children(of:)`.
private final class FakeChildrenChatService: ChatService, @unchecked Sendable {
    var continuation: AsyncStream<[SubChatSummary]>.Continuation?
    private(set) var requestedParent: String?

    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        requestedParent = parentConvoID
        return AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func createChat(with botID: String) async throws -> String { "!x:s" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

final class SubChatStripViewModelTests: XCTestCase {
    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    func test_subscribesToParentAndSplitsRunningFromFinished() async {
        let fake = FakeChildrenChatService()
        let vm = SubChatStripViewModel(chat: fake, parentConvoID: "p1")
        vm.start()
        defer { vm.stop() }

        await waitUntil { fake.continuation != nil }
        XCTAssertEqual(fake.requestedParent, "p1")

        fake.continuation?.yield([
            SubChatSummary(id: "p1:sub:a", title: "explore", isRunning: true),
            SubChatSummary(id: "p1:sub:b", title: "test", isRunning: false),
            SubChatSummary(id: "p1:sub:c", title: "docs", isRunning: true),
        ])

        await waitUntil { vm.children.count == 3 }
        XCTAssertEqual(vm.children.map(\.id), ["p1:sub:a", "p1:sub:b", "p1:sub:c"])
        XCTAssertEqual(vm.runningChildren.map(\.id), ["p1:sub:a", "p1:sub:c"],
                       "the strip shows only running children")
    }

    @MainActor
    func test_stripEmptiesWhenAllChildrenFinish() async {
        let fake = FakeChildrenChatService()
        let vm = SubChatStripViewModel(chat: fake, parentConvoID: "p1")
        vm.start()
        defer { vm.stop() }
        await waitUntil { fake.continuation != nil }

        fake.continuation?.yield([SubChatSummary(id: "p1:sub:a", title: "explore", isRunning: true)])
        await waitUntil { vm.runningChildren.count == 1 }
        XCTAssertEqual(vm.soleRunningChild?.id, "p1:sub:a")

        // The subagent finishes: the strip empties, but the switcher still
        // lists it (finished children remain reachable).
        fake.continuation?.yield([SubChatSummary(id: "p1:sub:a", title: "explore", isRunning: false)])
        await waitUntil { vm.runningChildren.isEmpty }
        XCTAssertTrue(vm.runningChildren.isEmpty, "no running children ⇒ strip hides")
        XCTAssertEqual(vm.children.count, 1, "finished child stays in the switcher")
        XCTAssertNil(vm.soleRunningChild)
    }
}
