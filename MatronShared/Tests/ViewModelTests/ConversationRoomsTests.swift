import XCTest
import MatronModels
@testable import MatronViewModels

final class ConversationRoomsTests: XCTestCase {
    private func room(_ id: String, title: String? = nil, state: String = "waiting", at seconds: TimeInterval? = nil,
                      participants: [String]) -> MissionRoom {
        MissionRoom(id: id, title: title ?? id, sessionState: state,
                    lastActivity: seconds.map { Date(timeIntervalSince1970: $0) }, participantConvoIDs: participants)
    }

    // MARK: - The rule

    func test_aChatListsEveryRoomItTakesPartIn_andNoOthers() {
        let rooms = [
            room("r1", at: 10, participants: ["a", "b"]),
            room("r2", at: 20, participants: ["b", "c"]),
            room("r3", at: 30, participants: ["a", "c"]),
        ]
        XCTAssertEqual(ConversationRoomsRule.rooms(of: "a", among: rooms).map(\.id), ["r3", "r1"])
        XCTAssertEqual(ConversationRoomsRule.rooms(of: "b", among: rooms).map(\.id), ["r2", "r1"])
        XCTAssertEqual(ConversationRoomsRule.rooms(of: "z", among: rooms), [])
    }

    func test_everyParticipantListsTheRoom_notOnlyTheStarter() {
        let rooms = [room("r1", participants: ["starter", "invited", "joined"])]
        for convo in ["starter", "invited", "joined"] {
            XCTAssertEqual(ConversationRoomsRule.rooms(of: convo, among: rooms).map(\.id), ["r1"], convo)
        }
    }

    func test_aRoomIsNotARoomOfItself() {
        let rooms = [room("r1", participants: ["r1", "a"])]
        XCTAssertEqual(ConversationRoomsRule.rooms(of: "r1", among: rooms), [])
    }

    func test_newestActivityFirst_neverActiveLast_thenByID() {
        let rooms = [
            room("quiet-b", participants: ["a"]),
            room("old", at: 5, participants: ["a"]),
            room("quiet-a", participants: ["a"]),
            room("new", at: 50, participants: ["a"]),
        ]
        XCTAssertEqual(ConversationRoomsRule.rooms(of: "a", among: rooms).map(\.id),
                       ["new", "old", "quiet-a", "quiet-b"])
    }

    func test_carriesTitleAndState() {
        let rooms = [room("r1", title: "G:c1 ↔️ D:15 — rollout", state: "running", participants: ["a"])]
        XCTAssertEqual(ConversationRoomsRule.rooms(of: "a", among: rooms),
                       [ConversationRoom(id: "r1", title: "G:c1 ↔️ D:15 — rollout", state: .running)])
    }

    // MARK: - The view model

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    func test_viewModelPublishesThisChatsRooms_andFollowsTheStream() async {
        let (stream, feed) = AsyncStream<[MissionRoom]>.makeStream()
        let vm = ConversationRoomsViewModel(convoID: "a", rooms: { stream })
        vm.start()
        defer { vm.stop() }

        feed.yield([room("r1", at: 10, participants: ["a", "b"]), room("r2", at: 20, participants: ["b", "c"])])
        await waitUntil { !vm.rooms.isEmpty }
        XCTAssertEqual(vm.rooms.map(\.id), ["r1"])

        feed.yield([room("r1", at: 10, participants: ["a", "b"]), room("r2", at: 20, participants: ["b", "c", "a"])])
        await waitUntil { vm.rooms.count == 2 }
        XCTAssertEqual(vm.rooms.map(\.id), ["r2", "r1"])

        feed.yield([])
        await waitUntil { vm.rooms.isEmpty }
        XCTAssertEqual(vm.rooms, [])
    }

    /// Hands each `start()` its own stream, as the store does: cancelling
    /// a stream's consumer ends that stream.
    private final class Feeds: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [AsyncStream<[MissionRoom]>.Continuation] = []
        var count: Int { lock.withLock { continuations.count } }
        func make() -> AsyncStream<[MissionRoom]> {
            let (stream, continuation) = AsyncStream<[MissionRoom]>.makeStream()
            lock.withLock { continuations.append(continuation) }
            return stream
        }
        func yieldToLatest(_ rooms: [MissionRoom]) { lock.withLock { _ = continuations.last?.yield(rooms) } }
    }

    @MainActor
    func test_aStaleStop_doesNotEndANewerObservation() async {
        let feeds = Feeds()
        let vm = ConversationRoomsViewModel(convoID: "a", rooms: { feeds.make() })
        vm.start()
        let stale = vm.observationGeneration
        vm.start()
        vm.stop(ifGeneration: stale)
        await waitUntil { feeds.count == 2 }

        feeds.yieldToLatest([room("r1", participants: ["a"])])
        await waitUntil { !vm.rooms.isEmpty }
        XCTAssertEqual(vm.rooms.map(\.id), ["r1"])

        vm.stop(ifGeneration: vm.observationGeneration)
        feeds.yieldToLatest([])
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.rooms.map(\.id), ["r1"], "a stopped view model no longer follows the stream")
    }
}
