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

    /// The strip VM is shared per-parent between the parent chat's strip and
    /// every child viewer's switcher, and SwiftUI can run the NEW view's
    /// `.task`/`start()` before the OLD view's `onDisappear` on push
    /// navigation — the same remount hazard `ChatViewModel` guards with
    /// `stop(ifGeneration:)`. A stale surface's teardown must not cancel the
    /// observation a successor just started.
    @MainActor
    func test_staleSurfaceStopCannotKillSuccessorsStream() async {
        let fake = FakeChildrenChatService()
        let vm = SubChatStripViewModel(chat: fake, parentConvoID: "p1")

        vm.start()
        let parentGeneration = vm.observationGeneration
        await waitUntil { fake.continuation != nil }

        // Push: the child viewer starts (new generation) BEFORE the parent's
        // onDisappear fires with the old generation.
        fake.continuation = nil
        vm.start()
        defer { vm.stop() }
        await waitUntil { fake.continuation != nil }
        vm.stop(ifGeneration: parentGeneration)

        // The successor's stream must still be alive.
        fake.continuation?.yield([SubChatSummary(id: "p1:sub:a", title: "explore", isRunning: true)])
        await waitUntil { vm.runningChildren.count == 1 }
        XCTAssertEqual(vm.runningChildren.map(\.id), ["p1:sub:a"],
                       "a stale view's stop(ifGeneration:) must not cancel the successor's observation")

        // The CURRENT surface's stop still works.
        vm.stop(ifGeneration: vm.observationGeneration)
        fake.continuation?.yield([])
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(vm.runningChildren.count, 1, "a matching-generation stop cancels the observation")
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
