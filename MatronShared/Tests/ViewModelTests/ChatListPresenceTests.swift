import XCTest
import MatronChat
import MatronJournal
import MatronModels
@testable import MatronViewModels

/// Records each `listDidAppear`, and holds the first one until the test
/// releases it (a list fetch still in flight).
private actor HeldListService: ChatService {
    private(set) var appearances = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var holdFirst = true

    nonisolated func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    nonisolated func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        AsyncStream { $0.finish() }
    }
    func forceSnapshot() async throws {}

    func listDidAppear(_ token: UUID) async {
        appearances += 1
        guard holdFirst else { return }
        holdFirst = false
        await withCheckedContinuation { gate = $0 }
    }

    var isHolding: Bool { gate != nil }

    func release() {
        gate?.resume()
        gate = nil
    }
}

final class ChatListPresenceTests: XCTestCase {
    private func until(_ what: String, _ condition: () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testAReturnToTheFrontDuringTheFirstReportIsReportedAfterIt() async {
        let activity = AppActivity(active: true)
        let service = HeldListService()
        let hold = Task { await ChatListPresence.hold(service, activity: activity) }
        await until("the first report is in flight") { await service.isHolding }

        activity.setActive(false)
        activity.setActive(true)
        await service.release()

        await until("the return to the front is reported") { await service.appearances == 2 }
        hold.cancel()
    }
}
