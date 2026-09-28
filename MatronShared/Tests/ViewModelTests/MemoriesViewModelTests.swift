import XCTest
import MatronEvents
import MatronJournal
import MatronModels
@testable import MatronViewModels

private final class FakeMemoriesAPI: MemoriesProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _stored: [Memory] = []
    private var _listCalls = 0
    private var _saves: [(name: String, description: String, body: String, type: MemoryType)] = []
    private var _deletes: [String] = []
    private var _listError: Error?
    private var _saveError: Error?
    private var _deleteError: Error?

    var stored: [Memory] { get { lock.withLock { _stored } } set { lock.withLock { _stored = newValue } } }
    var listCalls: Int { lock.withLock { _listCalls } }
    var saves: [(name: String, description: String, body: String, type: MemoryType)] { lock.withLock { _saves } }
    var deletes: [String] { lock.withLock { _deletes } }
    var listError: Error? { get { lock.withLock { _listError } } set { lock.withLock { _listError = newValue } } }
    var saveError: Error? { get { lock.withLock { _saveError } } set { lock.withLock { _saveError = newValue } } }
    var deleteError: Error? { get { lock.withLock { _deleteError } } set { lock.withLock { _deleteError = newValue } } }

    func listMemories() async throws -> [Memory] {
        try lock.withLock {
            _listCalls += 1
            if let _listError { throw _listError }
            return _stored
        }
    }

    func saveMemory(name: String, description: String, body: String, type: MemoryType) async throws -> Memory {
        try lock.withLock {
            _saves.append((name, description, body, type))
            if let _saveError { throw _saveError }
            let memory = Memory(id: "me_\(name)", name: name, type: type, description: description, body: body,
                                createdBy: .user, updatedBy: .user, createdAt: Date(), updatedAt: Date())
            _stored = _stored.filter { $0.name != name } + [memory]
            return memory
        }
    }

    func deleteMemory(name: String) async throws -> Memory {
        try lock.withLock {
            _deletes.append(name)
            if let _deleteError { throw _deleteError }
            guard let memory = _stored.first(where: { $0.name == name }) else { throw MemoriesError.notFound }
            _stored.removeAll { $0.name == name }
            return memory
        }
    }
}

private func memory(_ name: String, description: String = "A rule.") -> Memory {
    Memory(id: "me_\(name)", name: name, type: .feedback, description: description,
           createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
}

@MainActor
final class MemoriesViewModelTests: XCTestCase {
    private var api: FakeMemoriesAPI!
    private var markers: AsyncStream<MemoryMarkerEvent>.Continuation!
    private var vm: MemoriesViewModel!

    override func setUp() async throws {
        api = FakeMemoriesAPI()
        let (stream, continuation) = AsyncStream<MemoryMarkerEvent>.makeStream()
        markers = continuation
        vm = MemoriesViewModel(api: api, markers: { stream }, refetchDelay: .milliseconds(50))
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

    private let marker = MemoryMarkerEvent(memoryID: "me_x", action: .saved, created: true)

    func testNothingLoadsUntilStart() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(api.listCalls, 0)
        XCTAssertNil(vm.memories)
    }

    func testStartLoadsTheListSortedByName() async {
        api.stored = [memory("zeta"), memory("alpha"), memory("mid")]
        vm.start()
        await waitUntil { vm.memories != nil }
        XCTAssertEqual(vm.memories?.map(\.name), ["alpha", "mid", "zeta"])
        XCTAssertEqual(vm.isSupported, true)
        XCTAssertNil(vm.loadError)
    }

    /// An older journal 404s the route: that is `isSupported == false`, not
    /// an error, and nothing else about the list changes.
    func testAnOlderJournalReadsAsUnsupported() async {
        api.listError = MemoriesError.unsupported
        vm.start()
        await waitUntil { vm.isSupported == false }
        XCTAssertNil(vm.memories)
        XCTAssertNil(vm.loadError)
    }

    func testAFailedRefreshKeepsTheListAndSaysSo() async {
        api.stored = [memory("alpha")]
        await vm.load()
        api.listError = MemoriesError.other("offline")
        await vm.load()
        XCTAssertEqual(vm.memories?.map(\.name), ["alpha"])
        XCTAssertEqual(vm.loadError, "offline")
        api.listError = nil
        await vm.load()
        XCTAssertNil(vm.loadError, "a later success clears the error")
    }

    /// One change lands on two conversations (writer's + Coordinator's):
    /// the burst costs one refetch.
    func testABurstOfMarkersCostsOneRefetch() async {
        vm.start()
        await waitUntil { api.listCalls == 1 && !vm.isLoading }
        api.stored = [memory("new-rule")]
        markers.yield(marker)
        markers.yield(marker)
        markers.yield(marker)
        await waitUntil { vm.memories?.map(\.name) == ["new-rule"] }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(api.listCalls, 2)
    }

    func testStoppedScreenIgnoresMarkers() async {
        vm.start()
        await waitUntil { api.listCalls == 1 && !vm.isLoading }
        vm.stop()
        markers.yield(marker)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(api.listCalls, 1)
    }

    func testSaveValidatesBeforeAnyRequest() async {
        let error = await vm.save(isNew: true, name: "Bad Name", type: .feedback, description: "d", body: "")
        XCTAssertEqual(error, "Name must be lowercase letters, digits and dashes (up to 64), starting with a letter or digit.")
        XCTAssertTrue(api.saves.isEmpty)
    }

    /// PUT is an upsert: a NEW memory must not silently replace one that
    /// already has its name.
    func testANewMemoryCannotTakeAnExistingName() async {
        api.stored = [memory("avoid-eric")]
        await vm.load()
        let error = await vm.save(isNew: true, name: "avoid-eric", type: .feedback, description: "d", body: "")
        XCTAssertEqual(error, "A memory named \"avoid-eric\" already exists. Open it from the list to change it.")
        XCTAssertTrue(api.saves.isEmpty)
        // Editing the existing one is fine.
        let editError = await vm.save(isNew: false, name: "avoid-eric", type: .user, description: "d", body: "")
        XCTAssertNil(editError)
    }

    /// Bugbot, PR #249: with no list loaded the duplicate check has nothing
    /// to look at, so a save first loads it — and an existing name is caught.
    func testANewMemoryBeforeTheFirstLoadLoadsFirstAndCatchesADuplicate() async {
        api.stored = [memory("avoid-eric")]
        XCTAssertNil(vm.memories)
        let error = await vm.save(isNew: true, name: "avoid-eric", type: .feedback, description: "d", body: "")
        XCTAssertEqual(error, "A memory named \"avoid-eric\" already exists. Open it from the list to change it.")
        XCTAssertTrue(api.saves.isEmpty)
    }

    /// And when that load fails too, a new memory is refused, never PUT blind.
    func testANewMemoryIsRefusedWhileTheListCannotLoad() async {
        api.listError = MemoriesError.other("offline")
        let error = await vm.save(isNew: true, name: "avoid-eric", type: .feedback, description: "d", body: "")
        XCTAssertEqual(error, MemoriesViewModel.notLoadedError)
        XCTAssertTrue(api.saves.isEmpty)
        XCTAssertEqual(vm.formError(isNew: true, name: "avoid-eric", description: "d", body: ""),
                       MemoriesViewModel.notLoadedError)
        // Editing an existing memory needs no list.
        XCTAssertNil(vm.formError(isNew: false, name: "avoid-eric", description: "d", body: ""))
    }

    /// Bugbot, PR #249: the editor can be open when an older journal's 404
    /// lands; a save then says memories aren't available, not "try again".
    func testANewMemoryOnAnOlderJournalSaysUnsupported() async {
        api.listError = MemoriesError.unsupported
        let error = await vm.save(isNew: true, name: "avoid-eric", type: .feedback, description: "d", body: "")
        XCTAssertEqual(error, MemoriesError.unsupported.localizedDescription)
        XCTAssertTrue(api.saves.isEmpty)
    }

    func testSaveSendsTheTrimmedDescriptionAndReloads() async {
        await vm.load()
        let error = await vm.save(isNew: true, name: "avoid-eric", type: .project,
                                  description: "  Never start sessions on eric.  ", body: "**Why:** reserved.")
        XCTAssertNil(error)
        XCTAssertEqual(api.saves.first?.description, "Never start sessions on eric.")
        XCTAssertEqual(api.saves.first?.body, "**Why:** reserved.")
        XCTAssertEqual(api.saves.first?.type, .project)
        XCTAssertEqual(vm.memory(named: "avoid-eric")?.type, .project)
        XCTAssertEqual(api.listCalls, 2, "the list is reloaded after a save")
    }

    func testTheSavedMemoryIsListedEvenWhenTheReloadFails() async {
        await vm.load()
        api.listError = MemoriesError.other("offline")
        let error = await vm.save(isNew: true, name: "avoid-eric", type: .feedback, description: "d", body: "")
        XCTAssertNil(error)
        XCTAssertNotNil(vm.memory(named: "avoid-eric"))
    }

    func testASaveTheJournalRefusesReturnsItsReason() async {
        api.saveError = MemoriesError.tooMany
        let error = await vm.save(isNew: true, name: "one-too-many", type: .feedback, description: "d", body: "")
        XCTAssertEqual(error, MemoriesError.tooMany.localizedDescription)
    }

    func testDeleteDropsTheMemory() async {
        api.stored = [memory("alpha"), memory("beta")]
        await vm.load()
        let error = await vm.delete(name: "alpha")
        XCTAssertNil(error)
        XCTAssertEqual(api.deletes, ["alpha"])
        XCTAssertEqual(vm.memories?.map(\.name), ["beta"])
    }

    /// Deleted on another device already: the goal is met.
    func testDeletingAMemoryThatIsAlreadyGoneSucceeds() async {
        api.stored = [memory("alpha")]
        await vm.load()
        api.stored = []
        let error = await vm.delete(name: "alpha")
        XCTAssertNil(error)
        XCTAssertEqual(vm.memories, [])
    }

    func testAFailedDeleteKeepsTheMemory() async {
        api.stored = [memory("alpha")]
        await vm.load()
        api.deleteError = MemoriesError.other("offline")
        let error = await vm.delete(name: "alpha")
        XCTAssertEqual(error, "offline")
        XCTAssertEqual(vm.memories?.map(\.name), ["alpha"])
    }
}
