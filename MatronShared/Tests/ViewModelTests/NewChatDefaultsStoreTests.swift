import XCTest
import MatronJournal
import MatronModels
@testable import MatronViewModels

/// Plays the journal: answers `GET` with `stored`, applies each `PUT` to it
/// (lowercased, as the journal normalises), and can hold a `PUT` or `GET`
/// open or fail it.
private final class FakeDefaultsAPI: NewChatDefaultsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _stored: NewChatDefaults
    private var _puts: [(NewChatDefaults.Key, String?)] = []
    private var _putError: Error?
    private var _failNextPut: Error?
    private var _getError: Error?
    private var _holdsPuts = false
    private var _holdsGets = false
    private var _gates: [CheckedContinuation<Void, Never>] = []

    init(stored: NewChatDefaults) { _stored = stored }

    var stored: NewChatDefaults { get { lock.withLock { _stored } } set { lock.withLock { _stored = newValue } } }
    var putCount: Int { lock.withLock { _puts.count } }
    var putValues: [String?] { lock.withLock { _puts.map(\.1) } }
    var lastPut: (NewChatDefaults.Key, String?)? { lock.withLock { _puts.last } }
    var putError: Error? { get { lock.withLock { _putError } } set { lock.withLock { _putError = newValue } } }
    /// Fails only the next `PUT` to answer.
    var failNextPut: Error? { get { lock.withLock { _failNextPut } } set { lock.withLock { _failNextPut = newValue } } }
    var getError: Error? { get { lock.withLock { _getError } } set { lock.withLock { _getError = newValue } } }
    var holdsPuts: Bool { get { lock.withLock { _holdsPuts } } set { lock.withLock { _holdsPuts = newValue } } }
    var holdsGets: Bool { get { lock.withLock { _holdsGets } } set { lock.withLock { _holdsGets = newValue } } }

    private func hold() async {
        await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
            lock.withLock { _gates.append(gate) }
        }
    }

    func newChatDefaults() async throws -> NewChatDefaults {
        let answer = stored
        if holdsGets { await hold() }
        if let getError { throw getError }
        return answer
    }

    func setNewChatDefault(_ key: NewChatDefaults.Key, to value: String?) async throws -> NewChatDefaults {
        lock.withLock { _puts.append((key, value)) }
        if holdsPuts { await hold() }
        if let putError { throw putError }
        if let once = lock.withLock({ () -> Error? in defer { _failNextPut = nil }; return _failNextPut }) { throw once }
        return lock.withLock {
            _stored[key] = value?.lowercased()
            return _stored
        }
    }

    /// Returns once at least `count` held calls are parked. Bounded, so a
    /// regression fails the test instead of hanging it.
    func waitForHeld(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if lock.withLock({ _gates.count }) >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(count) held call(s)", file: file, line: line)
    }

    /// Stops holding and lets every parked call answer.
    func releaseAll() {
        let gates: [CheckedContinuation<Void, Never>] = lock.withLock {
            _holdsPuts = false
            _holdsGets = false
            defer { _gates.removeAll() }
            return _gates
        }
        gates.forEach { $0.resume() }
    }

    /// Lets the oldest held call answer.
    func releaseOldest() {
        let gate: CheckedContinuation<Void, Never>? = lock.withLock { _gates.isEmpty ? nil : _gates.removeFirst() }
        gate?.resume()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _isSet = false
    var isSet: Bool { lock.withLock { _isSet } }
    func set() { lock.withLock { _isSet = true } }
}

@MainActor
final class NewChatDefaultsStoreTests: XCTestCase {
    private var frames: (stream: AsyncStream<NewChatDefaults>, continuation: AsyncStream<NewChatDefaults>.Continuation)!
    private var states: (stream: AsyncStream<SyncConnectionState>, continuation: AsyncStream<SyncConnectionState>.Continuation)!

    override func setUp() async throws {
        frames = AsyncStream.makeStream()
        states = AsyncStream.makeStream()
    }

    private func makeStore(_ api: FakeDefaultsAPI) -> NewChatDefaultsStore {
        let frameStream = frames.stream
        let stateStream = states.stream
        return NewChatDefaultsStore(api: api, updates: { frameStream }, connectionStates: { stateStream })
    }

    /// Awaits `task`, failing (and releasing every held call) if it has not
    /// finished within two seconds — a pick that should return at once, or a
    /// save loop that should have settled, must not hang the suite.
    private func settle(_ task: Task<Void, Never>, _ api: FakeDefaultsAPI,
                        file: StaticString = #filePath, line: UInt = #line) async {
        // Polled, not raced in a task group: a group would wait for the
        // un-cancellable `task.value` child and hang anyway.
        let done = Flag()
        Task { await task.value; done.set() }
        var finished = false
        for _ in 0..<400 {
            if done.isSet { finished = true; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if !finished {
            XCTFail("did not settle", file: file, line: line)
            // Unstick whatever is parked, but never wait on it again.
            api.releaseAll()
        }
    }

    /// Spins the main actor until `condition` holds (live streams deliver on
    /// their own tasks).
    private func eventually(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out: \(message)")
    }

    func testEveryConnectReadsTheDefaults() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults(model: "opus", effort: nil))
        let store = makeStore(api)
        store.start()
        XCTAssertNil(store.defaults)
        states.continuation.yield(.connecting)
        states.continuation.yield(.running)
        await eventually("GET on running") { store.defaults != nil }
        XCTAssertEqual(store.defaults, NewChatDefaults(model: "opus", effort: nil))
        XCTAssertEqual(store.isSupported, true)
        // A reconnect refetches: a frame missed while offline is never replayed.
        api.stored = NewChatDefaults(model: "haiku", effort: "low")
        states.continuation.yield(.connecting)
        states.continuation.yield(.running)
        await eventually("GET on reconnect") { store.defaults?.model == "haiku" }
        XCTAssertEqual(store.defaults?.effort, "low")
        store.stop()
    }

    func testOldJournalIsUnsupported() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults())
        api.getError = JournalAPIError.notFound
        let store = makeStore(api)
        await store.refresh()
        XCTAssertEqual(store.isSupported, false)
        XCTAssertNil(store.defaults)
        XCTAssertNil(store.errorMessage, "an old journal is not an error, the screen says so instead")
    }

    func testFailedReadSaysSoAndKeepsWhatIsShown() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults(model: "opus"))
        let store = makeStore(api)
        await store.refresh()
        api.getError = JournalAPIError.transport("offline")
        await store.refresh()
        XCTAssertEqual(store.defaults?.model, "opus")
        XCTAssertEqual(store.errorMessage, "Couldn't load the defaults: Couldn't reach the server — offline")
        api.getError = nil
        await store.refresh()
        XCTAssertNil(store.errorMessage, "the next good read clears it")
    }

    func testPickShowsAtOnceThenTakesTheJournalsSpelling() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults())
        let store = makeStore(api)
        await store.refresh()
        api.holdsPuts = true
        let write = Task { await store.set(.model, to: "Claude-Opus-5-5") }
        await api.waitForHeld(1)
        XCTAssertEqual(store.defaults?.model, "Claude-Opus-5-5", "optimistic: shown before the PUT answers")
        api.releaseOldest()
        await settle(write, api)
        XCTAssertEqual(api.lastPut?.0, .model)
        XCTAssertEqual(api.lastPut?.1, "Claude-Opus-5-5")
        XCTAssertEqual(store.defaults?.model, "claude-opus-5-5", "the journal's normalised value")
        XCTAssertNil(store.errorMessage)
    }

    func testSamePickSendsNothing() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults(effort: "high"))
        let store = makeStore(api)
        await store.set(.effort, to: "max")
        XCTAssertEqual(api.putCount, 0, "nothing to change before the first read")
        await store.refresh()
        await store.set(.effort, to: "high")
        XCTAssertEqual(api.putCount, 0)
    }

    func testFailedPickRevertsAndSaysSo() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults(model: "opus", effort: "high"))
        let store = makeStore(api)
        await store.refresh()
        api.putError = JournalAPIError.http(status: 400, message: "bad_effort")
        await store.set(.effort, to: nil)
        XCTAssertEqual(store.defaults, NewChatDefaults(model: "opus", effort: "high"))
        XCTAssertEqual(store.errorMessage, "Couldn't save the default effort: bad_effort")
        api.putError = nil
        api.holdsPuts = true
        let other = Task { await store.set(.model, to: "sonnet") }
        await api.waitForHeld(1)
        XCTAssertEqual(store.errorMessage, "Couldn't save the default effort: bad_effort",
                       "a pick of the other key leaves this key's error")
        let same = Task { await store.set(.effort, to: "max") }
        await api.waitForHeld(2)
        XCTAssertNil(store.errorMessage, "the next pick of the same key clears it")
        api.releaseAll()
        await settle(other, api)
        await settle(same, api)
    }

    /// A frame is a newer full state: it ends a load error, but a save
    /// error stays with its key — the picker snapped back and the user has
    /// not tried again.
    func testLiveFrameUpdatesAndClearsOnlyALoadError() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults())
        let store = makeStore(api)
        store.start()
        await store.refresh()
        api.getError = JournalAPIError.transport("offline")
        await store.refresh()
        XCTAssertNotNil(store.errorMessage)
        frames.continuation.yield(NewChatDefaults(model: "fable", effort: "xhigh"))
        await eventually("frame applied") { store.defaults?.model == "fable" }
        XCTAssertEqual(store.defaults?.effort, "xhigh")
        XCTAssertNil(store.errorMessage, "the frame ends the load error")
        api.putError = JournalAPIError.transport("offline")
        await store.set(.model, to: "opus")
        frames.continuation.yield(NewChatDefaults(model: "fable", effort: "low"))
        await eventually("second frame applied") { store.defaults?.effort == "low" }
        XCTAssertEqual(store.errorMessage, "Couldn't save the default model: Couldn't reach the server — offline",
                       "the frame does not hide the failed save")
        store.stop()
    }

    /// Settings opens with a read, so a pick often lands while it is in
    /// flight: the read's answer is older than the pick and is dropped.
    func testReadInFlightAtAPickIsDropped() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults(model: "opus"))
        let store = makeStore(api)
        await store.refresh()
        api.stored = NewChatDefaults(model: "opus", effort: "max")
        api.holdsGets = true
        let read = Task { await store.refresh() }
        await api.waitForHeld(1)
        api.holdsGets = false
        api.holdsPuts = true
        let pick = Task { await store.set(.model, to: "sonnet") }
        await api.waitForHeld(2)
        api.releaseOldest()
        await settle(read, api)
        XCTAssertNil(store.defaults?.effort, "the read's answer predates the pick and is dropped")
        api.releaseAll()
        await settle(pick, api)
        XCTAssertEqual(store.defaults?.model, "sonnet")
    }

    /// A read after a failed save shows the journal's value, which the
    /// picker already snapped back to: it must not hide the failure.
    func testReadDoesNotClearASaveError() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults(model: "opus"))
        let store = makeStore(api)
        await store.refresh()
        api.putError = JournalAPIError.transport("offline")
        await store.set(.model, to: "haiku")
        api.putError = nil
        await store.refresh()
        XCTAssertEqual(store.defaults?.model, "opus")
        XCTAssertEqual(store.errorMessage, "Couldn't save the default model: Couldn't reach the server — offline")
    }

    /// A save reached the journal, so a failed read before it is over.
    func testSuccessfulSaveClearsALoadError() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults(model: "opus"))
        let store = makeStore(api)
        await store.refresh()
        api.getError = JournalAPIError.transport("offline")
        await store.refresh()
        XCTAssertEqual(store.errorMessage, "Couldn't load the defaults: Couldn't reach the server — offline")
        await store.set(.effort, to: "high")
        XCTAssertNil(store.errorMessage)
    }

    /// The echo of a model save must not snap a just-picked effort back
    /// while the effort's own PUT is in flight.
    func testFrameKeepsAKeyWhosePutIsInFlight() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults(model: "opus", effort: "high"))
        let store = makeStore(api)
        store.start()
        await store.refresh()
        api.holdsPuts = true
        let write = Task { await store.set(.effort, to: "low") }
        await api.waitForHeld(1)
        frames.continuation.yield(NewChatDefaults(model: "sonnet", effort: "high"))
        await eventually("frame applied") { store.defaults?.model == "sonnet" }
        XCTAssertEqual(store.defaults?.effort, "low", "the in-flight pick stays showing")
        api.releaseOldest()
        await settle(write, api)
        XCTAssertEqual(store.defaults, NewChatDefaults(model: "sonnet", effort: "low"))
        store.stop()
    }

    /// A save that fails after a frame landed goes back to what the frame
    /// said, not to the older value from before the pick.
    func testFailedPickRevertsToAFrameThatArrivedMeanwhile() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults(model: "opus"))
        let store = makeStore(api)
        store.start()
        await store.refresh()
        api.holdsPuts = true
        api.putError = JournalAPIError.transport("offline")
        let write = Task { await store.set(.model, to: "haiku") }
        await api.waitForHeld(1)
        frames.continuation.yield(NewChatDefaults(model: "fable", effort: "max"))
        // The frame's other key lands at once: proof the frame was taken.
        await eventually("frame applied") { store.defaults?.effort == "max" }
        XCTAssertEqual(store.defaults?.model, "haiku", "the in-flight pick stays showing")
        api.releaseOldest()
        await settle(write, api)
        XCTAssertEqual(store.defaults?.model, "fable")
        XCTAssertNotNil(store.errorMessage)
        store.stop()
    }

    /// A `GET` sent before a `PUT` answered carries the older value: it
    /// must not land over the stored pick.
    func testStaleReadAfterAPutAnswerIsDropped() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults(model: "opus"))
        let store = makeStore(api)
        await store.refresh()
        api.holdsGets = true
        let read = Task { await store.refresh() }
        await api.waitForHeld(1)
        api.holdsGets = false
        await store.set(.model, to: "sonnet")
        XCTAssertEqual(store.defaults?.model, "sonnet")
        api.releaseOldest()
        await read.value
        XCTAssertEqual(store.defaults?.model, "sonnet", "the older answer must not undo the stored pick")
    }

    /// Likewise a `GET` sent before a frame landed.
    func testStaleReadAfterAFrameIsDropped() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults(model: "opus"))
        let store = makeStore(api)
        store.start()
        await store.refresh()
        api.holdsGets = true
        let read = Task { await store.refresh() }
        await api.waitForHeld(1)
        frames.continuation.yield(NewChatDefaults(model: "fable", effort: nil))
        await eventually("frame applied") { store.defaults?.model == "fable" }
        api.releaseOldest()
        await read.value
        XCTAssertEqual(store.defaults?.model, "fable")
        store.stop()
    }

    /// Two quick picks of one key: the second waits for the first `PUT`, so
    /// the first answer can never land after (and over) the second — on
    /// screen or in the journal.
    func testTwoQuickPicksSendInOrderAndTheLatestWins() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults())
        let store = makeStore(api)
        await store.refresh()
        api.holdsPuts = true
        let first = Task { await store.set(.model, to: "opus") }
        await api.waitForHeld(1)
        await settle(Task { await store.set(.model, to: "sonnet") }, api)
        XCTAssertEqual(store.defaults?.model, "sonnet", "the newer pick shows at once")
        XCTAssertEqual(api.putCount, 1, "single flight: the second pick waits for the first PUT")
        api.releaseOldest()
        await api.waitForHeld(1)
        XCTAssertEqual(store.defaults?.model, "sonnet", "the first answer does not land over the newer pick")
        api.releaseOldest()
        await settle(first, api)
        XCTAssertEqual(api.putValues, ["opus", "sonnet"])
        XCTAssertEqual(api.stored.model, "sonnet", "the journal ends on the latest pick")
        XCTAssertEqual(store.defaults?.model, "sonnet")
    }

    func testThreePicksCollapseToTwoPuts() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults())
        let store = makeStore(api)
        await store.refresh()
        api.holdsPuts = true
        let first = Task { await store.set(.effort, to: "low") }
        await api.waitForHeld(1)
        await settle(Task { await store.set(.effort, to: "medium") }, api)
        await settle(Task { await store.set(.effort, to: "max") }, api)
        XCTAssertEqual(store.defaults?.effort, "max")
        api.releaseOldest()
        await api.waitForHeld(1)
        api.releaseOldest()
        await settle(first, api)
        XCTAssertEqual(api.putValues, ["low", "max"], "the middle pick is replaced while it waits")
        XCTAssertEqual(api.stored.effort, "max")
        XCTAssertEqual(store.defaults?.effort, "max")
    }

    /// A failed `PUT` drops its own pick only: the newer pick waiting is
    /// still sent, and its success clears the error.
    func testFailureWhileANewerPickWaits() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults(model: "opus"))
        let store = makeStore(api)
        await store.refresh()
        api.holdsPuts = true
        let first = Task { await store.set(.model, to: "haiku") }
        await api.waitForHeld(1)
        await settle(Task { await store.set(.model, to: "fable") }, api)
        api.failNextPut = JournalAPIError.transport("offline")
        api.releaseOldest()
        await api.waitForHeld(1)
        XCTAssertEqual(store.defaults?.model, "fable", "the waiting pick stays showing")
        XCTAssertEqual(store.errorMessage, "Couldn't save the default model: Couldn't reach the server — offline")
        api.releaseOldest()
        await settle(first, api)
        XCTAssertEqual(api.putValues, ["haiku", "fable"])
        XCTAssertEqual(api.stored.model, "fable")
        XCTAssertEqual(store.defaults?.model, "fable")
        XCTAssertNil(store.errorMessage, "the key's next successful save clears its error")
    }

    /// A `stop()`/`start()` while a `PUT` is in flight: the old loop's
    /// answer is not applied, and the pick made after the restart — which
    /// found the key still busy — is sent once that loop ends.
    func testPickAfterARestartIsSentWhenTheOldPutAnswers() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults(model: "opus"))
        let store = makeStore(api)
        store.start()
        await store.refresh()
        api.holdsPuts = true
        let old = Task { await store.set(.model, to: "haiku") }
        await api.waitForHeld(1)
        store.stop()
        store.start()
        await settle(Task { await store.set(.model, to: "fable") }, api)
        XCTAssertEqual(api.putCount, 1, "the old PUT still holds the key")
        api.releaseOldest()
        await api.waitForHeld(1)
        XCTAssertEqual(api.putValues, ["haiku", "fable"], "the new pick is sent")
        api.releaseOldest()
        await settle(old, api)
        await eventually("the new pick is saved") { api.stored.model == "fable" && store.defaults?.model == "fable" }
        store.stop()
    }

    /// Picks waiting at a `stop()` are kept, still shown, and sent on the
    /// next `start()`.
    func testPickWaitingAtStopIsSentAfterStart() async {
        let api = FakeDefaultsAPI(stored: NewChatDefaults(effort: "low"))
        let store = makeStore(api)
        store.start()
        await store.refresh()
        api.holdsPuts = true
        let old = Task { await store.set(.effort, to: "max") }
        await api.waitForHeld(1)
        store.stop()
        api.releaseOldest()
        await settle(old, api)
        XCTAssertEqual(store.defaults?.effort, "max", "kept and still shown while stopped")
        XCTAssertEqual(api.putCount, 1, "not sent again while stopped")
        api.holdsPuts = false
        store.start()
        await eventually("sent again after start") { api.putCount == 2 && store.defaults?.effort == "max" }
        await eventually("saved") { api.stored.effort == "max" }
        store.stop()
    }

    func testChoicesKeepAnUnknownStoredValue() {
        let known = NewChatDefaults.Key.model.choices(stored: "opus[1m]")
        XCTAssertEqual(known, NewChatDefaults.modelChoices)
        XCTAssertEqual(known.first, .init(value: nil, label: "Box default"))
        let unknown = NewChatDefaults.Key.model.choices(stored: "claude-opus-5-5")
        XCTAssertEqual(unknown.count, NewChatDefaults.modelChoices.count + 1)
        XCTAssertEqual(unknown.last, .init(value: "claude-opus-5-5", label: "claude-opus-5-5"))
        XCTAssertEqual(NewChatDefaults.Key.effort.choices(stored: nil), NewChatDefaults.effortChoices)
        XCTAssertEqual(NewChatDefaults.effortChoices.map(\.label),
                       ["Box default", "Low", "Medium", "High", "X-High", "Max"])
    }
}
