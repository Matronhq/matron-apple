import XCTest
import MatronEvents
import MatronJournal
import MatronModels
@testable import MatronViewModels

private final class FakeRoutinesAPI: RoutinesProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _stored: [Routine] = []
    private var _listCalls = 0
    private var _listError: Error?
    private var _writeError: Error?
    private var _runResult: RoutineRunResult = .accepted
    private var _creates: [(name: String, draft: RoutineDraft)] = []
    private var _updates: [(id: String, draft: RoutineDraft)] = []
    private var _runs: [String] = []

    var stored: [Routine] { get { lock.withLock { _stored } } set { lock.withLock { _stored = newValue } } }
    var listCalls: Int { lock.withLock { _listCalls } }
    var listError: Error? { get { lock.withLock { _listError } } set { lock.withLock { _listError = newValue } } }
    var writeError: Error? { get { lock.withLock { _writeError } } set { lock.withLock { _writeError = newValue } } }
    var runResult: RoutineRunResult { get { lock.withLock { _runResult } } set { lock.withLock { _runResult = newValue } } }
    var creates: [(name: String, draft: RoutineDraft)] { lock.withLock { _creates } }
    var updates: [(id: String, draft: RoutineDraft)] { lock.withLock { _updates } }
    var runs: [String] { lock.withLock { _runs } }

    func listRoutines() async throws -> [Routine] {
        try lock.withLock {
            _listCalls += 1
            if let _listError { throw _listError }
            return _stored
        }
    }

    func createRoutine(name: String, draft: RoutineDraft) async throws -> Routine {
        try lock.withLock {
            _creates.append((name, draft))
            if let _writeError { throw _writeError }
            let made = routine(name, schedule: draft.schedule, trigger: draft.trigger, enabled: draft.enabled ?? true)
            _stored.append(made)
            return made
        }
    }

    func updateRoutine(id: String, draft: RoutineDraft) async throws -> Routine {
        try lock.withLock {
            _updates.append((id, draft))
            if let _writeError { throw _writeError }
            guard let old = _stored.first(where: { $0.id == id }) else { throw RoutinesError.notFound }
            let new = Routine(id: id, name: old.name, title: draft.title, schedule: draft.schedule ?? old.schedule,
                              trigger: draft.trigger ?? old.trigger, tz: draft.tz, prompt: draft.prompt,
                              enabled: old.enabled, createdAt: old.createdAt, updatedAt: Date())
            _stored = _stored.filter { $0.id != id } + [new]
            return new
        }
    }

    func setRoutineEnabled(id: String, enabled: Bool) async throws -> Routine {
        try lock.withLock {
            if let _writeError { throw _writeError }
            guard let old = _stored.first(where: { $0.id == id }) else { throw RoutinesError.notFound }
            let new = Routine(id: id, name: old.name, title: old.title, schedule: old.schedule, trigger: old.trigger,
                              prompt: old.prompt, enabled: enabled, createdAt: old.createdAt, updatedAt: Date())
            _stored = _stored.filter { $0.id != id } + [new]
            return new
        }
    }

    func deleteRoutine(id: String) async throws {
        try lock.withLock {
            if let _writeError { throw _writeError }
            guard _stored.contains(where: { $0.id == id }) else { throw RoutinesError.notFound }
            _stored.removeAll { $0.id == id }
        }
    }

    func runRoutine(id: String) async throws -> RoutineRunResult {
        try lock.withLock {
            _runs.append(id)
            if let _writeError { throw _writeError }
            return _runResult
        }
    }
}

private func routine(_ name: String, schedule: String? = "0 9 * * *", trigger: RoutineTrigger? = nil,
                     enabled: Bool = true) -> Routine {
    Routine(id: "rt_\(name)", name: name, title: name.capitalized,
            schedule: trigger == nil ? schedule : nil, trigger: trigger,
            prompt: "Do \(name).", enabled: enabled,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
}

@MainActor
final class RoutinesViewModelTests: XCTestCase {
    private var api: FakeRoutinesAPI!
    private var markers: AsyncStream<RoutineMarkerEvent>.Continuation!
    private var vm: RoutinesViewModel!

    override func setUp() async throws {
        api = FakeRoutinesAPI()
        let (stream, continuation) = AsyncStream<RoutineMarkerEvent>.makeStream()
        markers = continuation
        vm = RoutinesViewModel(api: api, markers: { stream }, refetchDelay: .milliseconds(50))
    }

    override func tearDown() async throws {
        vm.stop()
        markers.finish()
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private let draft = RoutineDraft(title: "Weekly", prompt: "Review the week.", tz: "Europe/London",
                                     schedule: "0 9 * * 1", enabled: true)

    func testNothingLoadsUntilStartThenTheListIsSortedByName() async {
        api.stored = [routine("zeta"), routine("alpha", trigger: .diskUnder(pct: 20))]
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(api.listCalls, 0)
        vm.start()
        await waitUntil { vm.routines != nil }
        XCTAssertEqual(vm.routines?.map(\.name), ["alpha", "zeta"])
        XCTAssertEqual(vm.isSupported, true)
    }

    func testAnOlderJournalReadsAsUnsupported() async {
        api.listError = RoutinesError.unsupported
        await vm.load()
        XCTAssertEqual(vm.isSupported, false)
        XCTAssertNil(vm.loadError)
        XCTAssertNotNil(vm.formError(isNew: true, name: "weekly", draft: draft))
    }

    /// The journal's `fired` marker (and any edit elsewhere) refetches the
    /// list; a burst costs one request.
    func testMarkersRefetchOnceForABurst() async {
        vm.start()
        await waitUntil { api.listCalls == 1 && !vm.isLoading }
        api.stored = [routine("daily-sweep")]
        let fired = RoutineMarkerEvent(routineID: "rt_daily-sweep", name: "daily-sweep", action: .fired, outcome: "applied now")
        markers.yield(fired); markers.yield(fired); markers.yield(fired)
        await waitUntil { vm.routines?.count == 1 }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(api.listCalls, 2)
    }

    func testPauseShowsAtOnceAndAFailureIsSaid() async {
        api.stored = [routine("daily-sweep")]
        await vm.load()
        await vm.setEnabled(false, id: "rt_daily-sweep")
        XCTAssertEqual(vm.routine(id: "rt_daily-sweep")?.enabled, false)
        XCTAssertTrue(vm.busyIDs.isEmpty)
        api.writeError = RoutinesError.other("offline")
        await vm.setEnabled(true, id: "rt_daily-sweep")
        XCTAssertEqual(vm.routine(id: "rt_daily-sweep")?.enabled, false)
        XCTAssertEqual(vm.actionMessage, "offline")
    }

    func testRunSaysWhenItWasNotSent() async {
        api.stored = [routine("daily-sweep")]
        await vm.load()
        let accepted = await vm.run(id: "rt_daily-sweep")
        XCTAssertNil(accepted)
        api.runResult = .notDelivered(reason: "no_coordinator")
        let refused = await vm.run(id: "rt_daily-sweep")
        XCTAssertEqual(refused, "Not sent: there is no Coordinator to run it.")
        XCTAssertEqual(api.runs, ["rt_daily-sweep", "rt_daily-sweep"])
    }

    func testCreateRefusesATakenNameBeforeAnyRequest() async {
        api.stored = [routine("weekly")]
        await vm.load()
        let error = await vm.save(existingID: nil, name: "weekly", draft: draft)
        XCTAssertNotNil(error)
        XCTAssertTrue(api.creates.isEmpty)
    }

    func testCreateLoadsFirstThenAddsTheRoutine() async {
        let error = await vm.save(existingID: nil, name: "weekly", draft: draft)
        XCTAssertNil(error)
        XCTAssertEqual(api.listCalls, 1, "a create with no list loaded loads it to check the name")
        XCTAssertEqual(api.creates.first?.name, "weekly")
        XCTAssertEqual(vm.routines?.map(\.name), ["weekly"])
    }

    func testTheJournalsRefusalIsShownAndNothingChanges() async {
        await vm.load()
        api.writeError = RoutinesError.nameTaken
        let error = await vm.save(existingID: nil, name: "weekly", draft: draft)
        XCTAssertEqual(error, RoutinesError.nameTaken.localizedDescription)
        XCTAssertEqual(vm.routines?.count, 0)
    }

    func testEditReplacesTheRow() async {
        api.stored = [routine("weekly")]
        await vm.load()
        var edit = draft
        edit.title = "Weekly review"
        edit.enabled = nil
        let error = await vm.save(existingID: "rt_weekly", name: "weekly", draft: edit)
        XCTAssertNil(error)
        XCTAssertEqual(vm.routine(id: "rt_weekly")?.title, "Weekly review")
        XCTAssertNil(api.updates.first?.draft.enabled)
    }

    func testDeleteOfARoutineAlreadyGoneCountsAsDeleted() async {
        api.stored = [routine("weekly")]
        await vm.load()
        api.stored = []
        let error = await vm.delete(id: "rt_weekly")
        XCTAssertNil(error)
        XCTAssertEqual(vm.routines?.count, 0)
    }
}
