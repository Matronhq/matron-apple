import XCTest
import MatronModels
@testable import MatronJournal

private final class FakeCoordinatorAPI: CoordinatorProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _journal: String?
    private var _getError: Error?
    private var _putError: Error?
    private var _puts: [String?] = []
    private var _getDelayNanoseconds: UInt64 = 0

    init(journal: String? = nil) { _journal = journal }

    var journal: String? { get { lock.withLock { _journal } } set { lock.withLock { _journal = newValue } } }
    var getError: Error? { get { lock.withLock { _getError } } set { lock.withLock { _getError = newValue } } }
    var putError: Error? { get { lock.withLock { _putError } } set { lock.withLock { _putError = newValue } } }
    var puts: [String?] { lock.withLock { _puts } }
    /// Artificial delay before `coordinator()` answers — lets a test race a
    /// live update against a slow startup `GET`.
    var getDelayNanoseconds: UInt64 {
        get { lock.withLock { _getDelayNanoseconds } }
        set { lock.withLock { _getDelayNanoseconds = newValue } }
    }

    func coordinator() async throws -> String? {
        if getDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: getDelayNanoseconds) }
        if let getError { throw getError }
        return journal
    }

    /// When set, `setCoordinator(_:)` parks after recording its PUT until
    /// `releasePut()` — a test's deterministic "the PUT is in flight" point.
    private var _holdsPut = false
    private var _putGate: CheckedContinuation<Void, Never>?
    private let putStarted = AsyncStream<Void>.makeStream()
    var holdsPut: Bool { get { lock.withLock { _holdsPut } } set { lock.withLock { _holdsPut = newValue } } }

    /// Returns once a held PUT is parked (its gate stored).
    func waitForPutStart() async {
        var starts = putStarted.stream.makeAsyncIterator()
        _ = await starts.next()
    }

    /// Lets a held PUT answer.
    func releasePut() {
        let gate: CheckedContinuation<Void, Never>? = lock.withLock {
            defer { _putGate = nil }
            return _putGate
        }
        gate?.resume()
    }

    func setCoordinator(_ convoID: String?) async throws -> String? {
        lock.withLock { _puts.append(convoID) }
        if holdsPut {
            await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
                lock.withLock { _putGate = gate }
                putStarted.continuation.yield()
            }
        }
        if let putError { throw putError }
        journal = convoID
        return convoID
    }
}

final class CoordinatorSyncTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.coordinatorSync.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func make(_ api: FakeCoordinatorAPI, cached: String? = nil, migrated: Bool = false)
        -> (CoordinatorSync, CoordinatorSetting, AsyncStream<CoordinatorUpdate>.Continuation) {
        let setting = CoordinatorSetting(userID: "@a:s", defaults: defaults)
        setting.convoID = cached
        setting.migrated = migrated
        let (stream, continuation) = AsyncStream<CoordinatorUpdate>.makeStream()
        return (CoordinatorSync(api: api, setting: setting, updates: { stream }), setting, continuation)
    }

    private func eventually(_ condition: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(2)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func test_localOnly_isPushedToTheJournal() async {
        let api = FakeCoordinatorAPI(journal: nil)
        let (sync, setting, _) = make(api, cached: "cL")
        await sync.start()
        XCTAssertEqual(api.puts, ["cL"])
        XCTAssertEqual(setting.convoID, "cL")
        XCTAssertTrue(setting.migrated)
    }

    func test_journalOnly_isAdopted_withoutAPut() async {
        let api = FakeCoordinatorAPI(journal: "cJ")
        let (sync, setting, _) = make(api)
        await sync.start()
        XCTAssertEqual(api.puts, [])
        XCTAssertEqual(setting.convoID, "cJ")
    }

    func test_bothDifferent_theJournalWins() async {
        let api = FakeCoordinatorAPI(journal: "cJ")
        let (sync, setting, _) = make(api, cached: "cL")
        await sync.start()
        XCTAssertEqual(api.puts, [])
        XCTAssertEqual(setting.convoID, "cJ")
    }

    /// Review focus: a clear on another device must stick here too.
    func test_migratedDevice_adoptsAClearFromElsewhere_withoutPushing() async {
        let api = FakeCoordinatorAPI(journal: nil)
        let (sync, setting, _) = make(api, cached: "cOld", migrated: true)
        await sync.start()
        XCTAssertEqual(api.puts, [], "the stale cache must not resurrect the Coordinator")
        XCTAssertNil(setting.convoID)
    }

    func test_pushOfAConvoTheJournalRejects_clearsTheCache() async {
        let api = FakeCoordinatorAPI(journal: nil)
        api.putError = JournalAPIError.notFound
        let (sync, setting, _) = make(api, cached: "cGone")
        await sync.start()
        XCTAssertNil(setting.convoID)
        XCTAssertTrue(setting.migrated)
    }

    func test_offlineStart_keepsTheCache_andTheHelloRetries() async {
        let api = FakeCoordinatorAPI(journal: nil)
        api.getError = JournalAPIError.transport("offline")
        let (sync, setting, hello) = make(api, cached: "cL")
        await sync.start()
        XCTAssertEqual(setting.convoID, "cL")
        XCTAssertFalse(setting.migrated)
        hello.yield(.snapshot(nil))
        await eventually { api.puts == ["cL"] }
        XCTAssertEqual(api.puts, ["cL"])
        XCTAssertTrue(setting.migrated)
    }

    func test_oldJournal_isUnsupported_andUserPicksStayLocal() async throws {
        let api = FakeCoordinatorAPI()
        api.getError = JournalAPIError.notFound
        let (sync, setting, _) = make(api, cached: "cL")
        await sync.start()
        let supported = await sync.isSupported
        XCTAssertEqual(supported, false)
        try await sync.set("cNew")
        XCTAssertEqual(api.puts, [], "no PUT to a journal without the route")
        XCTAssertEqual(setting.convoID, "cNew")
    }

    func test_liveEvents_followTheRole() async {
        let api = FakeCoordinatorAPI(journal: "c1")
        let (sync, setting, events) = make(api)
        await sync.start()
        events.yield(.released(convoID: "c-other"))
        events.yield(.assigned(convoID: "c2"))
        await eventually { setting.convoID == "c2" }
        XCTAssertEqual(setting.convoID, "c2", "a release of some other chat changes nothing")
        events.yield(.released(convoID: "c2"))
        await eventually { setting.convoID == nil }
        XCTAssertNil(setting.convoID)
    }

    func test_set_writesTheJournalThenTheCache() async throws {
        let api = FakeCoordinatorAPI(journal: "c1")
        let (sync, setting, _) = make(api)
        await sync.start()
        try await sync.set("c2")
        XCTAssertEqual(api.puts, ["c2"])
        XCTAssertEqual(setting.convoID, "c2")
        try await sync.set(nil)
        XCTAssertNil(setting.convoID)
    }

    func test_set_failure_leavesTheCacheAlone() async {
        let api = FakeCoordinatorAPI(journal: "c1")
        let (sync, setting, _) = make(api)
        await sync.start()
        api.putError = JournalAPIError.notFound
        do { try await sync.set("c-else"); XCTFail("expected a throw") } catch {}
        XCTAssertEqual(setting.convoID, "c1")
    }

    /// Reconnect-vs-backlog ordering is resolved upstream now (journal `seq`
    /// vs. the hello's head seq, in `JournalSyncEngine`), not by comparing
    /// cached values here — an earlier local attempt at this dropped
    /// exactly this case: a user with no Coordinator (`.snapshot(nil)`) who
    /// picks one on another device gets only a bare `assigned`, with no
    /// preceding `released` to "contradict" a stale cache guard.
    func test_snapshotNil_thenAssigned_isAdopted() async {
        let api = FakeCoordinatorAPI(journal: nil)
        let (sync, setting, events) = make(api)
        await sync.start()
        XCTAssertNil(setting.convoID)

        events.yield(.snapshot(nil))
        events.yield(.assigned(convoID: "cX"))

        await eventually { setting.convoID == "cX" }
        XCTAssertEqual(setting.convoID, "cX")
    }

    /// Minor 1 (actor reentrancy): `start()` creates the update-stream
    /// subscription — which can replay a fresher snapshot immediately — and
    /// then suspends inside `refresh()`'s `GET`. A slow GET answer that
    /// resolves after that live snapshot already landed must not clobber it.
    func test_refresh_dropsAStaleGETAnswer_racingALiveSnapshot() async throws {
        let api = FakeCoordinatorAPI(journal: "c-stale")
        api.getDelayNanoseconds = 150_000_000
        let (sync, setting, events) = make(api)
        let starting = Task { await sync.start() }

        try await Task.sleep(nanoseconds: 20_000_000)
        events.yield(.snapshot("c-live"))
        await eventually { setting.convoID == "c-live" }

        await starting.value
        XCTAssertEqual(setting.convoID, "c-live", "the slow startup GET must not overwrite a newer live snapshot")
        XCTAssertEqual(api.puts, [], "no PUT: the live snapshot already carried a journal value")
    }

    /// Minor 4: a startup `GET` that failed transport-side (so `isSupported`
    /// is still `nil`, not `false`) leaves `set(_:)` uncertain whether the
    /// journal has the route at all. A `PUT` 404 in that state reads as "no
    /// route" (as plausibly as "convo not owned") and must fall back to a
    /// cache-only write instead of throwing to the caller.
    func test_set_whenSupportUnknownAndPutIsNotFound_fallsBackToCacheOnly() async throws {
        let api = FakeCoordinatorAPI(journal: nil)
        api.getError = JournalAPIError.transport("offline")
        let (sync, setting, _) = make(api)
        await sync.start()
        let supportedBefore = await sync.isSupported
        XCTAssertNil(supportedBefore)

        api.putError = JournalAPIError.notFound
        try await sync.set("cNew")
        XCTAssertEqual(setting.convoID, "cNew")
        let supportedAfter = await sync.isSupported
        XCTAssertEqual(supportedAfter, false)
    }

    /// Final review T4: a superseded GET answer still proves the route
    /// exists — `isSupported` must not stay nil because a live update won.
    func test_supersededGET_stillMarksTheJournalSupported() async throws {
        let api = FakeCoordinatorAPI(journal: "c-stale")
        api.getDelayNanoseconds = 150_000_000
        let (sync, setting, events) = make(api)
        let starting = Task { await sync.start() }
        try await Task.sleep(nanoseconds: 20_000_000)
        events.yield(.assigned(convoID: "c-live"))
        await eventually { setting.convoID == "c-live" }
        await starting.value
        let supported = await sync.isSupported
        XCTAssertEqual(supported, true)
    }

    /// Final review T4: a live assigned/released frame comes from a journal
    /// that has the route, even when the startup GET failed transport-side.
    func test_liveAssignedOrReleased_marksTheJournalSupported() async {
        for update in [CoordinatorUpdate.assigned(convoID: "c2"), .released(convoID: "c2")] {
            let api = FakeCoordinatorAPI(journal: nil)
            api.getError = JournalAPIError.transport("offline")
            let (sync, _, events) = make(api)
            await sync.start()
            events.yield(update)
            var supported: Bool?
            let end = Date().addingTimeInterval(2)
            while supported == nil, Date() < end {
                supported = await sync.isSupported
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(supported, true, "\(update)")
        }
    }

    /// CodeRabbit: `reconcile(journal:)`'s migration `PUT` (the `.push`
    /// branch) suspends in `api.setCoordinator(cached)`. An `.assigned` from
    /// another device can land on this same actor while it's in flight and
    /// correctly set the cache to the new id — the PUT's own (now stale)
    /// answer must not then overwrite that with the id it was sent to push.
    func test_migrationPUT_dropsAStaleAnswer_racingALiveAssigned() async throws {
        let api = FakeCoordinatorAPI(journal: nil)
        api.holdsPut = true
        let (sync, setting, events) = make(api, cached: "cOld")
        let starting = Task { await sync.start() }

        // Deterministic: the migration PUT is suspended in flight when the
        // live `.assigned` lands, and only answers once it has (CodeRabbit).
        await api.waitForPutStart()
        events.yield(.assigned(convoID: "cLive"))
        await eventually { setting.convoID == "cLive" }
        api.releasePut()

        await starting.value
        XCTAssertEqual(setting.convoID, "cLive", "the live assigned event must win over the stale migration PUT")
    }

    /// Same race, the `notFound` branch: a migration PUT for a since-deleted
    /// cached chat must not clear a cache a live `.assigned` just set.
    func test_migrationPUT_notFound_doesNotClearALiveAssignedCache() async throws {
        let api = FakeCoordinatorAPI(journal: nil)
        api.holdsPut = true
        api.putError = JournalAPIError.notFound
        let (sync, setting, events) = make(api, cached: "cGone")
        let starting = Task { await sync.start() }

        // Deterministic: the migration PUT is suspended in flight when the
        // live `.assigned` lands, and only answers once it has (CodeRabbit).
        await api.waitForPutStart()
        events.yield(.assigned(convoID: "cLive"))
        await eventually { setting.convoID == "cLive" }
        api.releasePut()

        await starting.value
        XCTAssertEqual(setting.convoID, "cLive", "a live assigned event must not be clobbered by a stale migration 404")
    }
}
