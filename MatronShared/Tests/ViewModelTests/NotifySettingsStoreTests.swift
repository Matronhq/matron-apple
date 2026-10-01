import XCTest
import MatronJournal
import MatronModels
@testable import MatronViewModels

/// Plays the journal: answers `GET` with `stored`, applies each `PUT` to it
/// the way src/notify.js does (`NotifyChange.applied`), and can hold a `PUT`
/// open or fail it.
private final class FakeNotifyAPI: NotifySettingsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _stored: NotifyView
    private var _puts: [NotifyChange] = []
    private var _putError: Error?
    private var _getError: Error?
    private var _gates: [CheckedContinuation<Void, Never>] = []
    private var _holdsPuts = false
    private let putStarted = AsyncStream<Void>.makeStream()

    init(stored: NotifyView) { _stored = stored }

    var stored: NotifyView { get { lock.withLock { _stored } } set { lock.withLock { _stored = newValue } } }
    var puts: [NotifyChange] { lock.withLock { _puts } }
    var putError: Error? { get { lock.withLock { _putError } } set { lock.withLock { _putError = newValue } } }
    var getError: Error? { get { lock.withLock { _getError } } set { lock.withLock { _getError = newValue } } }
    var holdsPuts: Bool { get { lock.withLock { _holdsPuts } } set { lock.withLock { _holdsPuts = newValue } } }

    func notifySettings() async throws -> NotifyView {
        if let getError { throw getError }
        return stored
    }

    func updateNotify(_ change: NotifyChange) async throws -> NotifyView {
        lock.withLock { _puts.append(change) }
        if holdsPuts {
            await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
                lock.withLock { _gates.append(gate) }
                putStarted.continuation.yield()
            }
        }
        if let putError { throw putError }
        return lock.withLock {
            _stored = change.applied(to: _stored)
            return _stored
        }
    }

    /// Returns once `count` held `PUT`s are parked.
    func waitForPuts(_ count: Int) async {
        var starts = putStarted.stream.makeAsyncIterator()
        for _ in 0..<count { _ = await starts.next() }
    }

    /// Lets the oldest held `PUT` answer.
    func releaseOldest() {
        let gate: CheckedContinuation<Void, Never>? = lock.withLock { _gates.isEmpty ? nil : _gates.removeFirst() }
        gate?.resume()
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date { get { lock.withLock { _now } } set { lock.withLock { _now = newValue } } }
}

private func view(mode: NotifySettings.Mode = .coordinator, convos: [NotifySettings.ConvoOverride] = [],
                  deviceLevel: NotifyDeviceLevel = .all) -> NotifyView {
    NotifyView(settings: NotifySettings(mode: mode, events: NotifySettings.preset(mode) ?? [:],
                                        hasCoordinator: true, convos: convos),
               deviceLevel: deviceLevel)
}

@MainActor
final class NotifySettingsStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var frames: (stream: AsyncStream<NotifySettings>, continuation: AsyncStream<NotifySettings>.Continuation)!
    private var states: (stream: AsyncStream<SyncConnectionState>, continuation: AsyncStream<SyncConnectionState>.Continuation)!

    override func setUp() async throws {
        frames = AsyncStream.makeStream()
        states = AsyncStream.makeStream()
    }

    private func makeStore(_ api: FakeNotifyAPI, clock: Clock? = nil) -> NotifySettingsStore {
        let clock = clock ?? Clock(t0)
        let frameStream = frames.stream
        let stateStream = states.stream
        return NotifySettingsStore(api: api, updates: { frameStream }, connectionStates: { stateStream },
                                   now: { clock.now })
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

    func testRunningConnectionReadsTheSettings() async {
        let api = FakeNotifyAPI(stored: view(mode: .all, deviceLevel: .needsMe))
        let store = makeStore(api)
        store.start()
        XCTAssertNil(store.view)
        states.continuation.yield(.connecting)
        states.continuation.yield(.running)
        await eventually("GET on running") { store.view != nil }
        XCTAssertEqual(store.settings?.mode, .all)
        XCTAssertEqual(store.view?.deviceLevel, .needsMe)
        XCTAssertEqual(store.isSupported, true)
        store.stop()
    }

    func testOldJournalIsUnsupported() async {
        let api = FakeNotifyAPI(stored: view())
        api.getError = JournalAPIError.notFound
        let store = makeStore(api)
        await store.refresh()
        XCTAssertEqual(store.isSupported, false)
        XCTAssertNil(store.view)
    }

    func testChangeShowsAtOnceThenTakesTheJournalsAnswer() async {
        let api = FakeNotifyAPI(stored: view())
        let store = makeStore(api)
        await store.refresh()
        api.holdsPuts = true
        let write = Task { await store.setEvent(.otherDone, on: true) }
        await api.waitForPuts(1)
        XCTAssertEqual(store.settings?.mode, .custom, "optimistic: shown before the PUT answers")
        XCTAssertEqual(store.settings?.isOn(.otherDone), true)
        api.releaseOldest()
        await write.value
        XCTAssertEqual(api.puts, [.event(.otherDone, true)])
        XCTAssertEqual(store.view, api.stored)
        XCTAssertNil(store.errorMessage)
    }

    func testFailedChangeRollsBack() async {
        let api = FakeNotifyAPI(stored: view(mode: .coordinator))
        let store = makeStore(api)
        await store.refresh()
        api.putError = JournalAPIError.transport("offline")
        await store.setMode(.all)
        XCTAssertEqual(store.settings?.mode, .coordinator)
        XCTAssertEqual(store.settings?.events, NotifySettings.preset(.coordinator))
        XCTAssertNotNil(store.errorMessage)
    }

    func testFailedChangeDoesNotUndoAnotherInFlight() async {
        let api = FakeNotifyAPI(stored: view())
        let store = makeStore(api)
        await store.refresh()
        api.holdsPuts = true
        let first = Task { await store.setDeviceLevel(.off) }
        await api.waitForPuts(1)
        let second = Task { await store.setLevel(.silent, convoID: "c1") }
        await api.waitForPuts(1)
        XCTAssertEqual(store.view?.deviceLevel, .off)
        XCTAssertEqual(store.state(for: "c1").level, .silent)
        // The first fails; the second's change must stay on screen.
        api.putError = JournalAPIError.transport("offline")
        api.releaseOldest()
        await first.value
        XCTAssertEqual(store.view?.deviceLevel, .all, "the failed change is taken back")
        XCTAssertEqual(store.state(for: "c1").level, .silent, "the other one is not")
        api.putError = nil
        api.releaseOldest()
        await second.value
        XCTAssertTrue(store.state(for: "c1").isSilenced)
    }

    func testLiveFrameUpdatesAndKeepsThisDevicesLevel() async {
        let api = FakeNotifyAPI(stored: view(mode: .coordinator, deviceLevel: .needsMe))
        let store = makeStore(api)
        store.start()
        await store.refresh()
        var other = view(mode: .all).settings
        other.convos = [.init(convoID: "c9", level: .silent)]
        frames.continuation.yield(other)
        await eventually("frame applied") { store.settings?.mode == .all }
        XCTAssertEqual(store.view?.deviceLevel, .needsMe, "the frame carries no device_level")
        XCTAssertTrue(store.state(for: "c9").isSilenced)
        store.stop()
    }

    func testLiveFrameKeepsAPendingChangeShowing() async {
        let api = FakeNotifyAPI(stored: view(mode: .coordinator))
        let store = makeStore(api)
        store.start()
        await store.refresh()
        api.holdsPuts = true
        let write = Task { await store.setLevel(.needsMe, convoID: "c1") }
        await api.waitForPuts(1)
        frames.continuation.yield(view(mode: .all).settings)
        await eventually("frame applied") { store.settings?.mode == .all }
        XCTAssertEqual(store.state(for: "c1").level, .needsMe, "the pending write replays over the frame")
        api.releaseOldest()
        await write.value
        store.stop()
    }

    func testStateFollowsMuteExpiry() async {
        let clock = Clock(t0)
        let ends = t0.addingTimeInterval(0.05)
        let api = FakeNotifyAPI(stored: view(convos: [
            .init(convoID: "muted", muteUntil: ends),
            .init(convoID: "lapsed", muteUntil: t0.addingTimeInterval(-60)),
            .init(convoID: "quiet", level: .needsMe),
        ]))
        let store = makeStore(api, clock: clock)
        await store.refresh()
        XCTAssertEqual(store.state(for: "muted"), ConvoNotifyState(level: nil, mutedUntil: ends))
        XCTAssertTrue(store.state(for: "muted").isSilenced)
        XCTAssertFalse(store.state(for: "lapsed").isSilenced, "a lapsed mute reads as none")
        XCTAssertFalse(store.state(for: "quiet").isSilenced, "needs-me still pushes what needs the user")
        XCTAssertFalse(store.state(for: "other").isSilenced)
        XCTAssertEqual(store.activeOverrides.map(\.convoID), ["muted", "quiet"])
        // The store wakes itself when the mute ends.
        clock.now = ends.addingTimeInterval(1)
        await eventually("mute expired") { !store.state(for: "muted").isSilenced }
        XCTAssertEqual(store.activeOverrides.map(\.convoID), ["quiet"])
    }

    func testMuteSendsTheEndAndUnmuteClearsIt() async {
        let api = FakeNotifyAPI(stored: view())
        let store = makeStore(api)
        await store.refresh()
        await store.mute(convoID: "c1", for: .oneHour)
        XCTAssertEqual(api.puts, [.convoMute(convoID: "c1", until: t0.addingTimeInterval(3600))])
        XCTAssertEqual(store.state(for: "c1").mutedUntil, t0.addingTimeInterval(3600))
        await store.unmute(convoID: "c1")
        XCTAssertEqual(api.puts.last, .convoMute(convoID: "c1", until: nil))
        XCTAssertFalse(store.state(for: "c1").isSilenced)
        await store.setLevel(.all, convoID: "c1")
        await store.clearOverride(convoID: "c1")
        XCTAssertEqual(api.puts.last, .clearConvo(convoID: "c1"))
        XCTAssertTrue(store.activeOverrides.isEmpty)
    }

    func testOverrideSummaryLine() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let soon = Date().addingTimeInterval(60)
        XCTAssertEqual(ConvoNotifyState(level: .needsMe).summary(calendar: calendar), "Needs me")
        XCTAssertEqual(ConvoNotifyState(level: .silent).summary(calendar: calendar), "None")
        let muted = ConvoNotifyState(level: nil, mutedUntil: soon).summary(calendar: calendar)
        XCTAssertTrue(muted.hasPrefix("Muted until "), muted)
        let both = ConvoNotifyState(level: .all, mutedUntil: soon).summary(calendar: calendar)
        XCTAssertTrue(both.hasPrefix("All · muted until "), both)
    }

    func testPromptsCannotBeSwitchedOff() async {
        let api = FakeNotifyAPI(stored: view())
        let store = makeStore(api)
        await store.refresh()
        await store.setEvent(.prompts, on: false)
        XCTAssertTrue(api.puts.isEmpty)
        XCTAssertEqual(store.settings?.mode, .coordinator)
    }
}
