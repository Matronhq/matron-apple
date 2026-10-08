import XCTest
import MatronJournal
import MatronModels
@testable import MatronViewModels

/// Plays the journal's `/settings`: answers `GET` with `stored`, stores each
/// `PATCH`, and can fail either. A gate holds a call open until the test
/// releases it: a held `GET` answers with what was stored when it started,
/// a held `PATCH` stores once released.
private final class FakeUserSettingsAPI: UserSettingsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _stored: UserSettings
    private var _patches: [Bool] = []
    private var _gets = 0
    private var _getError: Error?
    private var _patchError: Error?
    private var _getGate: AsyncStream<Void>?
    private var _patchGate: AsyncStream<Void>?

    init(stored: UserSettings) { _stored = stored }

    var stored: UserSettings { get { lock.withLock { _stored } } set { lock.withLock { _stored = newValue } } }
    var patches: [Bool] { lock.withLock { _patches } }
    var gets: Int { lock.withLock { _gets } }
    var getError: Error? { get { lock.withLock { _getError } } set { lock.withLock { _getError = newValue } } }
    var patchError: Error? { get { lock.withLock { _patchError } } set { lock.withLock { _patchError = newValue } } }
    var getGate: AsyncStream<Void>? { get { lock.withLock { _getGate } } set { lock.withLock { _getGate = newValue } } }
    var patchGate: AsyncStream<Void>? { get { lock.withLock { _patchGate } } set { lock.withLock { _patchGate = newValue } } }

    func userSettings() async throws -> UserSettings {
        let (snapshot, error, gate) = lock.withLock { () -> (UserSettings, Error?, AsyncStream<Void>?) in
            _gets += 1
            let gate = _getGate
            _getGate = nil
            return (_stored, _getError, gate)
        }
        if let gate { for await _ in gate { break } }
        if let error { throw error }
        return snapshot
    }

    func updateUserSettings(notices: Bool) async throws -> UserSettings {
        let gate = lock.withLock { () -> AsyncStream<Void>? in
            _patches.append(notices)
            let gate = _patchGate
            _patchGate = nil
            return gate
        }
        if let gate { for await _ in gate { break } }
        if let patchError { throw patchError }
        return lock.withLock {
            _stored.notices = notices
            return _stored
        }
    }
}

@MainActor
final class UserSettingsStoreTests: XCTestCase {
    private var frames: (stream: AsyncStream<UserSettings>, continuation: AsyncStream<UserSettings>.Continuation)!
    private var states: (stream: AsyncStream<SyncConnectionState>, continuation: AsyncStream<SyncConnectionState>.Continuation)!

    override func setUp() async throws {
        frames = AsyncStream.makeStream()
        states = AsyncStream.makeStream()
    }

    private func makeStore(_ api: FakeUserSettingsAPI) -> UserSettingsStore {
        let frameStream = frames.stream
        let stateStream = states.stream
        return UserSettingsStore(api: api, updates: { frameStream }, connectionStates: { stateStream })
    }

    private func eventually(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out: \(message)")
    }

    func testRunningConnectionReadsTheSettings() async {
        let store = makeStore(FakeUserSettingsAPI(stored: UserSettings(notices: false)))
        store.start()
        XCTAssertFalse(store.showsNoticesSwitch, "hidden until the journal answers")
        states.continuation.yield(.running)
        await eventually("GET on running") { store.settings != nil }
        XCTAssertEqual(store.settings?.notices, false)
        XCTAssertTrue(store.showsNoticesSwitch)
        store.stop()
    }

    func testOldJournalHidesTheSwitch() async {
        let api = FakeUserSettingsAPI(stored: UserSettings())
        api.getError = JournalAPIError.notFound
        let store = makeStore(api)
        await store.refresh()
        XCTAssertEqual(store.isSupported, false)
        XCTAssertFalse(store.showsNoticesSwitch)
    }

    func testSetNoticesPatchesAndKeepsTheAnswer() async {
        let api = FakeUserSettingsAPI(stored: UserSettings(notices: true))
        let store = makeStore(api)
        await store.refresh()
        await store.setNotices(false)
        XCTAssertEqual(api.patches, [false])
        XCTAssertEqual(store.settings?.notices, false)
        XCTAssertNil(store.errorMessage)
        await store.setNotices(false)
        XCTAssertEqual(api.patches, [false], "no write for no change")
    }

    func testFailedWritePutsTheSwitchBack() async {
        let api = FakeUserSettingsAPI(stored: UserSettings(notices: true))
        let store = makeStore(api)
        await store.refresh()
        api.patchError = JournalAPIError.transport("offline")
        await store.setNotices(false)
        XCTAssertEqual(store.settings?.notices, true)
        XCTAssertNotNil(store.errorMessage)
    }

    func testLiveFrameUpdatesTheSwitch() async {
        let store = makeStore(FakeUserSettingsAPI(stored: UserSettings(notices: true)))
        store.start()
        frames.continuation.yield(UserSettings(notices: false))
        await eventually("frame applied") { store.settings?.notices == false }
        XCTAssertEqual(store.isSupported, true)
        store.stop()
    }

    func testGetStartedDuringAWriteDoesNotUndoIt() async {
        let api = FakeUserSettingsAPI(stored: UserSettings(notices: true))
        let store = makeStore(api)
        await store.refresh()
        let (patchGate, releasePatch) = AsyncStream<Void>.makeStream()
        api.patchGate = patchGate
        let write = Task { await store.setNotices(false) }
        await eventually("PATCH sent") { api.patches == [false] }
        // A reconnect reads the journal before the write is stored there.
        let (getGate, releaseGet) = AsyncStream<Void>.makeStream()
        api.getGate = getGate
        let read = Task { await store.refresh() }
        await eventually("GET sent") { api.gets == 2 }
        releasePatch.finish()
        await write.value
        releaseGet.finish()
        await read.value
        XCTAssertEqual(store.settings?.notices, false, "the stale GET must not flip the switch back")
    }

    func testGetAnsweringBeforeTheWriteLandsDoesNotUndoIt() async {
        let api = FakeUserSettingsAPI(stored: UserSettings(notices: true))
        let store = makeStore(api)
        await store.refresh()
        let (patchGate, releasePatch) = AsyncStream<Void>.makeStream()
        api.patchGate = patchGate
        let write = Task { await store.setNotices(false) }
        await eventually("PATCH sent") { api.patches == [false] }
        await store.refresh()
        XCTAssertEqual(store.settings?.notices, false, "a GET while the write is out keeps the flipped switch")
        releasePatch.finish()
        await write.value
        XCTAssertEqual(store.settings?.notices, false)
    }

    func testGetStartedBeforeALiveFrameIsDropped() async {
        let api = FakeUserSettingsAPI(stored: UserSettings(notices: true))
        let store = makeStore(api)
        store.start()
        let (getGate, releaseGet) = AsyncStream<Void>.makeStream()
        api.getGate = getGate
        let read = Task { await store.refresh() }
        await eventually("GET sent") { api.gets == 1 }
        frames.continuation.yield(UserSettings(notices: false))
        await eventually("frame applied") { store.settings?.notices == false }
        releaseGet.finish()
        await read.value
        XCTAssertEqual(store.settings?.notices, false)
        store.stop()
    }

    func testA404StartedBeforeALiveFrameKeepsTheSwitch() async {
        let api = FakeUserSettingsAPI(stored: UserSettings())
        api.getError = JournalAPIError.notFound
        let store = makeStore(api)
        store.start()
        let (getGate, releaseGet) = AsyncStream<Void>.makeStream()
        api.getGate = getGate
        let read = Task { await store.refresh() }
        await eventually("GET sent") { api.gets == 1 }
        frames.continuation.yield(UserSettings(notices: true))
        await eventually("frame applied") { store.settings != nil }
        releaseGet.finish()
        await read.value
        XCTAssertEqual(store.isSupported, true)
        XCTAssertTrue(store.showsNoticesSwitch)
        store.stop()
    }

    func testSuccessfulRefreshClearsAFailedWritesError() async {
        let api = FakeUserSettingsAPI(stored: UserSettings(notices: true))
        let store = makeStore(api)
        await store.refresh()
        api.patchError = JournalAPIError.transport("offline")
        await store.setNotices(false)
        XCTAssertNotNil(store.errorMessage)
        await store.refresh()
        XCTAssertNil(store.errorMessage)
    }

    func testLiveFrameClearsAFailedWritesError() async {
        let api = FakeUserSettingsAPI(stored: UserSettings(notices: true))
        let store = makeStore(api)
        await store.refresh()
        api.patchError = JournalAPIError.transport("offline")
        await store.setNotices(false)
        XCTAssertNotNil(store.errorMessage)
        store.start()
        frames.continuation.yield(UserSettings(notices: false))
        await eventually("error cleared") { store.errorMessage == nil }
        XCTAssertEqual(store.settings?.notices, false)
        store.stop()
    }
}
