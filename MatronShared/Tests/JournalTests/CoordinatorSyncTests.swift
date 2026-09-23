import XCTest
import MatronModels
@testable import MatronJournal

private final class FakeCoordinatorAPI: CoordinatorProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _journal: String?
    private var _getError: Error?
    private var _putError: Error?
    private var _puts: [String?] = []

    init(journal: String? = nil) { _journal = journal }

    var journal: String? { get { lock.withLock { _journal } } set { lock.withLock { _journal = newValue } } }
    var getError: Error? { get { lock.withLock { _getError } } set { lock.withLock { _getError = newValue } } }
    var putError: Error? { get { lock.withLock { _putError } } set { lock.withLock { _putError = newValue } } }
    var puts: [String?] { lock.withLock { _puts } }

    func coordinator() async throws -> String? {
        if let getError { throw getError }
        return journal
    }

    func setCoordinator(_ convoID: String?) async throws -> String? {
        lock.withLock { _puts.append(convoID) }
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

    /// Controller ruling (Task 2 review, minor 1): on reconnect the fresh
    /// hello `.snapshot(current)` publishes before the backlog's replayed
    /// `assigned`/`released` events. A stale replayed `assigned` for an id
    /// other than the snapshot must not flicker the cache away from it.
    /// Proven here by racing it against a *real* release of the snapshot's
    /// own id: if the stale `assigned` had wrongly applied, the release
    /// (which only clears a match) would be a no-op and the cache would be
    /// stuck at the stale id forever instead of converging to nil.
    func test_snapshotThenStaleBacklogAssigned_convergesOnTheSnapshot() async {
        let api = FakeCoordinatorAPI(journal: "c-current")
        let (sync, setting, events) = make(api)
        await sync.start()
        XCTAssertEqual(setting.convoID, "c-current")

        events.yield(.snapshot("c-current"))
        events.yield(.assigned(convoID: "c-old"))
        events.yield(.released(convoID: "c-current"))

        await eventually { setting.convoID == nil }
        XCTAssertNil(setting.convoID, "the stale 'assigned' must have been ignored, letting this release match and clear the cache")
    }
}
