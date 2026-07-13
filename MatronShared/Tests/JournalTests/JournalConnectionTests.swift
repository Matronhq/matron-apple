import XCTest
@testable import MatronJournal

final class JournalConnectionTests: XCTestCase {
    private let wsURL = URL(string: "wss://x/ws")!

    func testEstablishSendsHelloAndReturnsHead() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":7}"#)
        let (connection, head) = try await JournalConnection.establish(
            connector: FakeConnector([socket]), wsURL: wsURL, token: "tok", cursor: 3)
        XCTAssertEqual(head, 7)
        let hello = try XCTUnwrap(socket.lastSentObject)
        XCTAssertEqual(hello["op"] as? String, "hello")
        XCTAssertEqual(hello["token"] as? String, "tok")
        XCTAssertEqual(hello["cursor"] as? Int64, 3)
        connection.close()
    }

    func testEstablishThrowsOnAuthError() async {
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"error","code":"auth"}"#)
        do {
            _ = try await JournalConnection.establish(
                connector: FakeConnector([socket]), wsURL: wsURL, token: "bad", cursor: 0)
            XCTFail("expected authRejected")
        } catch let error as JournalConnectionError {
            XCTAssertEqual(error, .authRejected)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFramesStreamYieldsAndThrowsOnClose() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":0}"#)
        let (connection, _) = try await JournalConnection.establish(
            connector: FakeConnector([socket]), wsURL: wsURL, token: "t", cursor: 0)
        socket.serve(#"{"kind":"journal","seq":1,"convo_id":"c1","ts":1000,"sender":"agent:a","type":"text","payload":{"body":"x"}}"#)
        socket.serve("garbage that is skipped")
        socket.serve(#"{"kind":"journal","seq":2,"convo_id":"c1","ts":2000,"sender":"agent:a","type":"text","payload":{"body":"y"}}"#)

        var received: [Int64] = []
        do {
            for try await frame in connection.frames() {
                if case let .journal(event) = frame {
                    received.append(event.seq)
                    if event.seq == 2 { socket.closeFromServer() }
                }
            }
            XCTFail("stream must throw when the socket dies")
        } catch {
            // expected
        }
        XCTAssertEqual(received, [1, 2])
    }

    func testSendEncodesOp() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":0}"#)
        let (connection, _) = try await JournalConnection.establish(
            connector: FakeConnector([socket]), wsURL: wsURL, token: "t", cursor: 0)
        try await connection.send(.ack(cursor: 5))
        XCTAssertEqual(socket.lastSentObject?["op"] as? String, "ack")
    }

    func testEstablishTimesOutWhenServerSilent() async {
        let socket = FakeWebSocketConnection() // never serves hello_ok
        do {
            _ = try await JournalConnection.establish(
                connector: FakeConnector([socket]), wsURL: wsURL, token: "t", cursor: 0,
                handshakeTimeout: .milliseconds(100))
            XCTFail("expected handshakeTimeout")
        } catch let error as JournalConnectionError {
            XCTAssertEqual(error, .handshakeTimeout)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(socket.isClosed)
    }

    func testFramesTerminationClosesSocket() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":0}"#)
        let (connection, _) = try await JournalConnection.establish(
            connector: FakeConnector([socket]), wsURL: wsURL, token: "t", cursor: 0)
        let task = Task {
            for try await _ in connection.frames() { }
        }
        try await Task.sleep(for: .milliseconds(50)) // let the pump suspend in receiveText
        task.cancel() // terminates the stream -> onTermination must close the socket
        for _ in 0..<100 where !socket.isClosed {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(socket.isClosed)
    }
}
