import GRDB
import XCTest
@testable import MatronJournal

/// The suspend/resume state machine behind the iOS `0xdead10cc` fix: the
/// databases run in the foreground or while any background activity is in
/// flight, and are suspended the moment the app is backgrounded with none.
final class DatabaseSuspensionControllerTests: XCTestCase {
    /// Records every transition the controller applies, in order.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _transitions: [Bool] = []
        var transitions: [Bool] { lock.withLock { _transitions } }
        func record(_ suspend: Bool) { lock.withLock { _transitions.append(suspend) } }
    }

    private func makeController() -> (DatabaseSuspensionController, Recorder) {
        let recorder = Recorder()
        return (DatabaseSuspensionController(apply: { recorder.record($0) }), recorder)
    }

    func testForegroundNeverSuspends() {
        let (controller, recorder) = makeController()
        controller.setInBackground(false)
        let activity = controller.beginActivity(named: "a")
        activity.end()
        XCTAssertFalse(controller.isSuspended)
        XCTAssertEqual(recorder.transitions, [], "nothing to apply while foregrounded")
    }

    func testBackgroundWithNoActivitySuspendsAndForegroundResumes() {
        let (controller, recorder) = makeController()
        controller.setInBackground(true)
        XCTAssertTrue(controller.isSuspended)
        controller.setInBackground(true)
        XCTAssertEqual(recorder.transitions, [true], "a repeated background report is not a new transition")
        controller.setInBackground(false)
        XCTAssertFalse(controller.isSuspended)
        XCTAssertEqual(recorder.transitions, [true, false])
    }

    func testActivityClaimedBeforeBackgroundKeepsDatabasesRunningUntilItEnds() {
        // The outbox grace claims its activity before the scene reports the
        // background transition — there must be no suspend/resume blip.
        let (controller, recorder) = makeController()
        let grace = controller.beginActivity(named: "outbox-grace")
        controller.setInBackground(true)
        XCTAssertFalse(controller.isSuspended)
        XCTAssertEqual(controller.activeActivityNames, ["outbox-grace"])
        grace.end()
        XCTAssertTrue(controller.isSuspended)
        XCTAssertEqual(recorder.transitions, [true])
    }

    func testActivityStartingWhileSuspendedResumesThenSuspendsAgain() {
        // A BGAppRefresh wake arrives with the databases suspended from the
        // previous background transition.
        let (controller, recorder) = makeController()
        controller.setInBackground(true)
        let refresh = controller.beginActivity(named: "bg-refresh")
        XCTAssertFalse(controller.isSuspended)
        refresh.end()
        XCTAssertTrue(controller.isSuspended)
        XCTAssertEqual(recorder.transitions, [true, false, true])
    }

    func testEndingOneOfTwoActivitiesKeepsDatabasesRunning() {
        let (controller, recorder) = makeController()
        controller.setInBackground(true)
        let refresh = controller.beginActivity(named: "bg-refresh")
        let grace = controller.beginActivity(named: "outbox-grace")
        refresh.end()
        XCTAssertFalse(controller.isSuspended)
        grace.end()
        XCTAssertTrue(controller.isSuspended)
        XCTAssertEqual(recorder.transitions, [true, false, true])
    }

    func testEndIsIdempotentSoExpiryAndCompletionCanBothCallIt() {
        let (controller, recorder) = makeController()
        controller.setInBackground(true)
        let refresh = controller.beginActivity(named: "bg-refresh")
        let other = controller.beginActivity(named: "outbox-grace")
        refresh.end()
        refresh.end() // the late normal completion after an expiry
        XCTAssertFalse(controller.isSuspended, "a second end() must not release someone else's claim")
        other.end()
        XCTAssertEqual(recorder.transitions, [true, false, true])
    }

    func testForegroundWhileActivityRunsThenActivityEndsInForegroundStaysResumed() {
        let (controller, recorder) = makeController()
        controller.setInBackground(true)
        let refresh = controller.beginActivity(named: "bg-refresh")
        controller.setInBackground(false) // user opened the app mid-refresh
        refresh.end()
        XCTAssertFalse(controller.isSuspended)
        XCTAssertEqual(recorder.transitions, [true, false])
    }

    func testExpiryOnAnotherThreadSuspendsBeforeEndReturns() {
        // BGTask expiry handlers are not guaranteed to run on main, and iOS
        // suspends right after they return: the suspension must already be
        // applied when `end()` returns, with no hop in between.
        let (controller, recorder) = makeController()
        controller.setInBackground(true)
        let refresh = controller.beginActivity(named: "bg-refresh")
        let done = expectation(description: "expiry")
        DispatchQueue.global().async {
            refresh.end()
            XCTAssertEqual(recorder.transitions.last, true)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(controller.isSuspended)
    }

    func testDatabaseDidOpenReassertsOnlyWhileSuspended() {
        let (controller, recorder) = makeController()
        controller.databaseDidOpen()
        XCTAssertEqual(recorder.transitions, [], "nothing to re-assert while running")
        controller.setInBackground(true)
        controller.databaseDidOpen()
        XCTAssertEqual(recorder.transitions, [true, true],
                       "a database opened after the last suspension post must be suspended too")
    }

    func testResumeHandlerRunsOnResumeOnly() {
        let (controller, _) = makeController()
        let resumes = Recorder()
        controller.setResumeHandler { resumes.record(false) }
        controller.setInBackground(true)
        XCTAssertEqual(resumes.transitions.count, 0)
        let refresh = controller.beginActivity(named: "bg-refresh")
        XCTAssertEqual(resumes.transitions.count, 1)
        refresh.end()
        controller.setInBackground(false)
        XCTAssertEqual(resumes.transitions.count, 2)
    }
}

/// What the journal mirror does while GRDB suspension is in force — the
/// contract the sync engine relies on: a refused write rolls back whole, so
/// the cursor never moves past a frame that did not land, and reads keep
/// working (WAL) so the UI can still render.
final class JournalStoreSuspensionTests: XCTestCase {
    private var url: URL!
    private var controller: DatabaseSuspensionController!

    override func setUp() {
        super.setUp()
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("suspension-\(UUID().uuidString).sqlite")
        // A private controller posting GRDB's real notifications. Only
        // stores opened with `observesSuspension: true` react, and on the
        // macOS test host that is only the one built below.
        controller = DatabaseSuspensionController()
    }

    override func tearDown() {
        controller.setInBackground(false)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        super.tearDown()
    }

    private func event(_ seq: Int64, body: String = "hi") -> JournalEvent {
        JournalEvent(seq: seq, convoID: "c1", ts: Date(timeIntervalSince1970: Double(seq)),
                     sender: "agent:box-2", type: "text",
                     payloadData: try! JSONSerialization.data(withJSONObject: ["body": body]))
    }

    func testSuspendedStoreRefusesWritesWithoutMovingTheCursorAndResumes() throws {
        let store = try JournalStore(databaseURL: url, ownSender: "user:alice", observesSuspension: true)
        XCTAssertTrue(try store.applyJournal(event(1)))

        controller.setInBackground(true)
        XCTAssertThrowsError(try store.applyJournal(event(2))) { error in
            XCTAssertTrue((error as? DatabaseError)?.isInterruptionError == true,
                          "expected SQLITE_ABORT/INTERRUPT, got \(error)")
        }
        XCTAssertThrowsError(try store.applyJournalBatch([event(2), event(3)]))
        // Reads are still served while suspended (WAL).
        XCTAssertEqual(store.cursor, 1, "a refused frame must leave the cursor where it was")
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), [1])

        controller.setInBackground(false)
        XCTAssertEqual(try store.applyJournalBatch([event(2), event(3)]).map(\.seq), [2, 3],
                       "the replay after resume lands the frames that were refused")
        XCTAssertEqual(store.cursor, 3)
    }

    func testStoreOptedOutIgnoresSuspension() throws {
        // The Mac default: suspension notifications have no effect.
        let store = try JournalStore(databaseURL: url, ownSender: "user:alice", observesSuspension: false)
        controller.setInBackground(true)
        XCTAssertTrue(try store.applyJournal(event(1)))
        XCTAssertEqual(store.cursor, 1)
    }
}
