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
final class ChatSummaryBroadcasterTests: XCTestCase {

    private static let bot = BotIdentity(matrixID: "@b:s", displayName: "B", avatarURL: nil)

    private static func summary(_ id: String) -> ChatSummary {
        ChatSummary(id: id, title: id, bot: bot, lastActivity: nil, unreadCount: 0)
    }

    // MARK: - Single consumer

    func test_singleConsumer_receivesLatestImmediately_thenSubsequentBroadcasts() async throws {
        let broadcaster = ChatSummaryBroadcaster()
        await broadcaster.broadcast([Self.summary("a")])

        let stream = AsyncThrowingStream<[ChatSummary], Error> { continuation in
            Task {
                _ = await broadcaster.register(continuation)
            }
        }

        var received: [[String]] = []
        let collector = Task {
            for try await snapshot in stream {
                received.append(snapshot.map { $0.id })
                if received.count == 3 { break }
            }
        }

        // Wait briefly for the registration Task to complete and the
        // immediate snapshot to land.
        try await Task.sleep(nanoseconds: 50_000_000)
        await broadcaster.broadcast([Self.summary("a"), Self.summary("b")])
        await broadcaster.broadcast([Self.summary("a"), Self.summary("b"), Self.summary("c")])
        try await collector.value

        XCTAssertEqual(received, [["a"], ["a", "b"], ["a", "b", "c"]])
    }

    // MARK: - Multiple consumers

    func test_twoConsumers_bothReceiveSameSequence() async throws {
        let broadcaster = ChatSummaryBroadcaster()

        let s1 = AsyncThrowingStream<[ChatSummary], Error> { c in
            Task { _ = await broadcaster.register(c) }
        }
        let s2 = AsyncThrowingStream<[ChatSummary], Error> { c in
            Task { _ = await broadcaster.register(c) }
        }
        // Allow both registrations to land before broadcasting.
        try await Task.sleep(nanoseconds: 50_000_000)

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

        // Capture the token so we can unregister directly without
        // depending on stream-iteration cancellation timing.
        let tokenBox = TokenHolder()
        let cancelStream = AsyncThrowingStream<[ChatSummary], Error> { c in
            Task {
                if let t = await broadcaster.register(c) {
                    await tokenBox.set(t)
                }
            }
        }
        let surviveStream = AsyncThrowingStream<[ChatSummary], Error> { c in
            Task { _ = await broadcaster.register(c) }
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        let surviveCollector = Task<[[String]], Error> {
            var out: [[String]] = []
            for try await snap in surviveStream {
                out.append(snap.map { $0.id })
                if out.count == 2 { break }
            }
            return out
        }

        // Drop the cancel-stream's continuation. The survive-stream must
        // still receive both broadcasts.
        let cancelCollector = Task<Void, Error> {
            for try await _ in cancelStream { }
        }
        if let token = await tokenBox.get() {
            await broadcaster.unregister(token: token)
        }
        _ = try await cancelCollector.value

        await broadcaster.broadcast([Self.summary("a")])
        await broadcaster.broadcast([Self.summary("a"), Self.summary("b")])

        let surviveResult = try await surviveCollector.value
        XCTAssertEqual(surviveResult, [["a"], ["a", "b"]])
    }

    // MARK: - Failure

    func test_failTerminatesAllConsumers_withSameError() async throws {
        let broadcaster = ChatSummaryBroadcaster()
        let s1 = AsyncThrowingStream<[ChatSummary], Error> { c in
            Task { _ = await broadcaster.register(c) }
        }
        let s2 = AsyncThrowingStream<[ChatSummary], Error> { c in
            Task { _ = await broadcaster.register(c) }
        }
        try await Task.sleep(nanoseconds: 50_000_000)

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

        let stream = AsyncThrowingStream<[ChatSummary], Error> { c in
            Task { _ = await broadcaster.register(c) }
        }
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
        let survivor = AsyncThrowingStream<[ChatSummary], Error> { c in
            Task { _ = await broadcaster.register(c) }
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        // Churn 50 register/unregister pairs in parallel.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    let tokenBox = TokenHolder()
                    let local = AsyncThrowingStream<[ChatSummary], Error> { c in
                        Task {
                            if let t = await broadcaster.register(c) {
                                await tokenBox.set(t)
                                await broadcaster.unregister(token: t)
                            }
                        }
                    }
                    // Drain whatever we got (likely 0 or 1 element + finish).
                    // Errors here would mean the broadcaster failed
                    // mid-flight — tolerable for the churn test.
                    do {
                        for try await _ in local { }
                    } catch { }
                    _ = await tokenBox.get()
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

/// Tiny actor-backed slot for tests that need to share a token between
/// the registration Task and the test body.
private actor TokenHolder {
    private var token: UUID?
    func set(_ t: UUID) { token = t }
    func get() -> UUID? { token }
}
