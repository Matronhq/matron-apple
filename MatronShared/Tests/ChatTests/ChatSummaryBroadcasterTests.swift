import XCTest
@testable import MatronChat
@testable import MatronModels

/// Fan-out behaviour tests for `ChatSummaryBroadcaster`. Covers:
/// - Single consumer happy path: register → immediate latest → ordered
///   broadcasts → cancel cleanly.
/// - Two concurrent consumers receive the same broadcast sequence;
///   cancelling one does not affect the other.
/// - `fail(with:)` terminates every consumer with the same error.
/// - Late registration after `fail(with:)` immediately receives the
///   stored failure.
/// - Rapid register/unregister doesn't leak continuations or block
///   delivery to surviving consumers.
///
/// All tests use `AsyncThrowingStream.makeStream()` to obtain the
/// continuation outside the stream's init closure, then `await
/// broadcaster.register(continuation)` directly. This avoids the
/// fire-and-forget `Task { register }` pattern's registration race —
/// no `Task.sleep` synchronisation barriers, deterministic on any
/// scheduler.
final class ChatSummaryBroadcasterTests: XCTestCase {

    private static let bot = BotIdentity(matrixID: "@b:s", displayName: "B", avatarURL: nil)

    private static func summary(_ id: String) -> ChatSummary {
        ChatSummary(id: id, title: id, bot: bot, lastActivity: nil, unreadCount: 0)
    }

    // MARK: - Single consumer

    func test_singleConsumer_receivesLatestImmediately_thenSubsequentBroadcasts() async throws {
        let broadcaster = ChatSummaryBroadcaster()
        await broadcaster.broadcast([Self.summary("a")])

        let (stream, continuation) = AsyncThrowingStream<[ChatSummary], Error>.makeStream()
        _ = await broadcaster.register(continuation)

        await broadcaster.broadcast([Self.summary("a"), Self.summary("b")])
        await broadcaster.broadcast([Self.summary("a"), Self.summary("b"), Self.summary("c")])

        var received: [[String]] = []
        for try await snapshot in stream {
            received.append(snapshot.map { $0.id })
            if received.count == 3 { break }
        }

        XCTAssertEqual(received, [["a"], ["a", "b"], ["a", "b", "c"]])
    }

    // MARK: - Multiple consumers

    func test_twoConsumers_bothReceiveSameSequence() async throws {
        let broadcaster = ChatSummaryBroadcaster()

        let (s1, c1) = AsyncThrowingStream<[ChatSummary], Error>.makeStream()
        let (s2, c2) = AsyncThrowingStream<[ChatSummary], Error>.makeStream()
        _ = await broadcaster.register(c1)
        _ = await broadcaster.register(c2)

        let collected1 = Task<[[String]], Error> {
            var out: [[String]] = []
            for try await snap in s1 {
                out.append(snap.map { $0.id })
                if out.count == 2 { break }
            }
            return out
        }
        let collected2 = Task<[[String]], Error> {
            var out: [[String]] = []
            for try await snap in s2 {
                out.append(snap.map { $0.id })
                if out.count == 2 { break }
            }
            return out
        }

        await broadcaster.broadcast([Self.summary("a")])
        await broadcaster.broadcast([Self.summary("a"), Self.summary("b")])

        let r1 = try await collected1.value
        let r2 = try await collected2.value
        XCTAssertEqual(r1, [["a"], ["a", "b"]])
        XCTAssertEqual(r2, [["a"], ["a", "b"]])
    }

    func test_cancellingOneConsumer_doesNotAffectOthers() async throws {
        let broadcaster = ChatSummaryBroadcaster()

        let (cancelStream, cancelCont) = AsyncThrowingStream<[ChatSummary], Error>.makeStream()
        let (surviveStream, surviveCont) = AsyncThrowingStream<[ChatSummary], Error>.makeStream()
        let cancelToken = await broadcaster.register(cancelCont)
        _ = await broadcaster.register(surviveCont)

        // Drop the cancel-stream's continuation. The survive-stream must
        // still receive both broadcasts.
        let cancelCollector = Task<Void, Error> {
            for try await _ in cancelStream { }
        }
        if let token = cancelToken {
            await broadcaster.unregister(token: token)
        }
        _ = try await cancelCollector.value

        let surviveCollector = Task<[[String]], Error> {
            var out: [[String]] = []
            for try await snap in surviveStream {
                out.append(snap.map { $0.id })
                if out.count == 2 { break }
            }
            return out
        }

        await broadcaster.broadcast([Self.summary("a")])
        await broadcaster.broadcast([Self.summary("a"), Self.summary("b")])

        let surviveResult = try await surviveCollector.value
        XCTAssertEqual(surviveResult, [["a"], ["a", "b"]])
    }

    // MARK: - Failure

    func test_failTerminatesAllConsumers_withSameError() async throws {
        let broadcaster = ChatSummaryBroadcaster()
        let (s1, c1) = AsyncThrowingStream<[ChatSummary], Error>.makeStream()
        let (s2, c2) = AsyncThrowingStream<[ChatSummary], Error>.makeStream()
        _ = await broadcaster.register(c1)
        _ = await broadcaster.register(c2)

        let collect1 = Task<Error?, Never> {
            do {
                for try await _ in s1 { }
                return nil
            } catch { return error }
        }
        let collect2 = Task<Error?, Never> {
            do {
                for try await _ in s2 { }
                return nil
            } catch { return error }
        }

        await broadcaster.fail(with: TestError.boom)

        let e1 = await collect1.value
        let e2 = await collect2.value
        XCTAssertEqual(e1 as? TestError, .boom)
        XCTAssertEqual(e2 as? TestError, .boom)
    }

    func test_lateRegistration_afterFail_terminatesImmediately() async throws {
        let broadcaster = ChatSummaryBroadcaster()
        await broadcaster.fail(with: TestError.boom)

        let (stream, continuation) = AsyncThrowingStream<[ChatSummary], Error>.makeStream()
        _ = await broadcaster.register(continuation)

        do {
            for try await _ in stream { XCTFail("expected stream to terminate, got snapshot") }
            XCTFail("expected stream to throw, got clean finish")
        } catch let err as TestError {
            XCTAssertEqual(err, .boom)
        }
    }

    // MARK: - Lifecycle hygiene

    func test_rapidRegisterUnregister_doesNotBlockOtherConsumers() async throws {
        let broadcaster = ChatSummaryBroadcaster()

        // Survivor we'll measure end-to-end against.
        let (survivor, survivorCont) = AsyncThrowingStream<[ChatSummary], Error>.makeStream()
        _ = await broadcaster.register(survivorCont)

        // Churn 50 register/unregister pairs in parallel.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    let (local, localCont) = AsyncThrowingStream<[ChatSummary], Error>.makeStream()
                    if let t = await broadcaster.register(localCont) {
                        await broadcaster.unregister(token: t)
                    }
                    // Drain whatever we got (likely 0 elements + finish).
                    // Errors here would mean the broadcaster failed
                    // mid-flight — tolerable for the churn test.
                    do {
                        for try await _ in local { }
                    } catch { }
                }
            }
        }

        let received = Task<[[String]], Error> {
            var out: [[String]] = []
            for try await snap in survivor {
                out.append(snap.map { $0.id })
                if out.count == 2 { break }
            }
            return out
        }
        await broadcaster.broadcast([Self.summary("x")])
        await broadcaster.broadcast([Self.summary("x"), Self.summary("y")])

        let result = try await received.value
        XCTAssertEqual(result, [["x"], ["x", "y"]])
    }
}

private enum TestError: Error, Equatable { case boom }
