import XCTest
@testable import MatronJournal

final class WebSocketTransportTests: XCTestCase {
    func testAwaitPongForwardsSuccess() async throws {
        try await URLSessionWebSocketConnection.awaitPong { $0(nil) }
    }

    func testAwaitPongForwardsError() async {
        do {
            try await URLSessionWebSocketConnection.awaitPong { $0(URLError(.networkConnectionLost)) }
            XCTFail("expected throw")
        } catch {}
    }

    func testAwaitPongSurvivesDoubleErrorCompletion() async {
        // URLSessionWebSocketTask.sendPing can fire its pong handler twice when
        // the socket dies mid-ping; the second resume must be swallowed, not trap.
        do {
            try await URLSessionWebSocketConnection.awaitPong { handler in
                handler(URLError(.networkConnectionLost))
                handler(URLError(.networkConnectionLost))
            }
            XCTFail("expected throw")
        } catch {}
    }

    func testAwaitPongSurvivesLateErrorAfterSuccess() async throws {
        try await URLSessionWebSocketConnection.awaitPong { handler in
            handler(nil)
            handler(URLError(.networkConnectionLost))
        }
    }
}
