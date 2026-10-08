import XCTest
import MatronJournal
import MatronModels
@testable import MatronViewModels

/// Plays the journal's `/pins` routes over an in-memory list.
private final class FakePinsAPI: PinsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _pins: [ConvoPin]
    private var _calls: [String] = []
    private var _error: Error?
    private var _getError: Error?

    init(_ pins: [ConvoPin] = []) { _pins = pins }

    var pinsNow: [ConvoPin] { get { lock.withLock { _pins } } set { lock.withLock { _pins = newValue } } }
    var calls: [String] { lock.withLock { _calls } }
    var error: Error? { get { lock.withLock { _error } } set { lock.withLock { _error = newValue } } }
    var getError: Error? { get { lock.withLock { _getError } } set { lock.withLock { _getError = newValue } } }

    private func answer(_ call: String, _ change: (inout [ConvoPin]) -> Void) throws -> ConvoPinList {
        try lock.withLock {
            _calls.append(call)
            if let _error { throw _error }
            change(&_pins)
            for index in _pins.indices { _pins[index].position = index }
            return ConvoPinList(pins: _pins, limit: 5)
        }
    }

    func pins() async throws -> ConvoPinList {
        if let getError { throw getError }
        return ConvoPinList(pins: pinsNow, limit: 5)
    }

    func setPin(_ convoID: String, label: String?, emoji: String?) async throws -> ConvoPinList {
        try answer("set \(convoID) \(label ?? "-") \(emoji ?? "-")") { pins in
            if let index = pins.firstIndex(where: { $0.convoID == convoID }) {
                if let label { pins[index].label = label }
                if let emoji { pins[index].emoji = emoji }
            } else {
                pins.append(ConvoPin(convoID: convoID, label: label ?? "", emoji: emoji ?? ""))
            }
        }
    }

    func reorderPins(_ order: [String]) async throws -> ConvoPinList {
        try answer("order \(order.joined(separator: ","))") { pins in
            pins = order.compactMap { id in pins.first { $0.convoID == id } }
        }
    }

    func unpin(_ convoID: String) async throws -> ConvoPinList {
        try answer("unpin \(convoID)") { $0.removeAll { $0.convoID == convoID } }
    }

    func movePin(_ convoID: String, to: String) async throws -> ConvoPinList {
        try answer("move \(convoID) \(to)") { pins in
            guard let index = pins.firstIndex(where: { $0.convoID == convoID }) else { return }
            pins[index].convoID = to
            pins[index].successor = nil
            pins[index].missing = false
        }
    }

    func dismissPinSuccessor(_ convoID: String, successorID: String) async throws -> ConvoPinList {
        try answer("dismiss \(convoID) \(successorID)") { pins in
            guard let index = pins.firstIndex(where: { $0.convoID == convoID }) else { return }
            pins[index].successor = nil
        }
    }
}

@MainActor
final class PinsStoreTests: XCTestCase {
    private var frames: (stream: AsyncStream<[ConvoPin]>, continuation: AsyncStream<[ConvoPin]>.Continuation)!
    private var states: (stream: AsyncStream<SyncConnectionState>, continuation: AsyncStream<SyncConnectionState>.Continuation)!
    private var names: (stream: AsyncStream<[Int64: String]>, continuation: AsyncStream<[Int64: String]>.Continuation)!

    override func setUp() async throws {
        frames = AsyncStream.makeStream()
        states = AsyncStream.makeStream()
        names = AsyncStream.makeStream()
    }

    private func makeStore(_ api: FakePinsAPI) -> PinsStore {
        let frameStream = frames.stream
        let stateStream = states.stream
        let nameStream = names.stream
        return PinsStore(api: api, updates: { frameStream }, connectionStates: { stateStream },
                         boxNames: { nameStream })
    }

    private func eventually(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out: \(message)")
    }

    private func pin(_ id: String, _ label: String, deviceID: Int64? = nil,
                     successor: String? = nil, missing: Bool = false) -> ConvoPin {
        ConvoPin(convoID: id, label: label, deviceID: deviceID,
                 missing: missing, successor: successor.map { ConvoPinSuccessor(convoID: $0, title: "New") })
    }

    func testRunningConnectionReadsThePins() async {
        let api = FakePinsAPI([pin("a", "Inbox triage")])
        let store = makeStore(api)
        store.start()
        XCTAssertEqual(store.pins, [])
        XCTAssertNil(store.isSupported)
        states.continuation.yield(.running)
        await eventually("GET on running") { !store.pins.isEmpty }
        XCTAssertEqual(store.pins.map(\.label), ["Inbox triage"])
        XCTAssertEqual(store.isSupported, true)
        XCTAssertTrue(store.isPinned("a"))
        XCTAssertEqual(store.pinnedIDs, ["a"])
        store.stop()
    }

    func testOldJournalIsUnsupportedAndShowsNothing() async {
        let api = FakePinsAPI([pin("a", "A")])
        api.getError = JournalAPIError.notFound
        let store = makeStore(api)
        await store.refresh()
        XCTAssertEqual(store.isSupported, false)
        XCTAssertEqual(store.pins, [])
    }

    func testTransportFailureKeepsWhatIsShown() async {
        let api = FakePinsAPI([pin("a", "A")])
        let store = makeStore(api)
        await store.refresh()
        api.getError = JournalAPIError.transport("offline")
        await store.refresh()
        XCTAssertEqual(store.pins.map(\.convoID), ["a"])
    }

    func testLiveFrameReplacesTheList() async {
        let store = makeStore(FakePinsAPI())
        store.start()
        frames.continuation.yield([pin("b", "Mail"), pin("a", "Support")])
        await eventually("frame applied") { store.pins.count == 2 }
        XCTAssertEqual(store.pins.map(\.convoID), ["b", "a"])
        frames.continuation.yield([])
        await eventually("last unpin elsewhere") { store.pins.isEmpty }
        store.stop()
    }

    func testPinClampsTheLabelAndGoesLast() async {
        let api = FakePinsAPI([pin("a", "A")])
        let store = makeStore(api)
        await store.refresh()
        let error = await store.pin("b", label: "  A rather long inbox triage name  ", emoji: " 📮 ")
        XCTAssertNil(error)
        XCTAssertEqual(api.calls, ["set b A rather long inbox tria 📮"])
        XCTAssertEqual(store.pins.map(\.convoID), ["a", "b"])
    }

    func testAnEmptyLabelFallsBackOnPinAndIsRefusedOnRename() async {
        let api = FakePinsAPI([pin("a", "A")])
        let store = makeStore(api)
        await store.refresh()
        await store.pin("b", label: "   ", emoji: "")
        XCTAssertEqual(store.pin(for: "b")?.label, ConvoPin.labelFallback)
        let refused = await store.edit("a", label: "  ", emoji: nil)
        XCTAssertEqual(refused, "A pin needs a name.")
        XCTAssertEqual(api.calls.count, 1, "nothing was sent for the empty rename")
    }

    func testCanPinLeavesOutPinnedTheCoordinatorAndAFullList() async {
        let api = FakePinsAPI([pin("a", "A")])
        let store = makeStore(api)
        XCTAssertFalse(store.canPin("x"), "not before the journal answers")
        await store.refresh()
        XCTAssertTrue(store.canPin("x"))
        XCTAssertFalse(store.canPin("a"), "already pinned")
        store.coordinatorConvoID = "co"
        XCTAssertFalse(store.canPin("co"), "the Coordinator has its own entry")
        store.coordinatorConvoID = ""
        XCTAssertTrue(store.canPin("co"))
        let full = makeStore(FakePinsAPI((1...5).map { pin("p\($0)", "P\($0)") }))
        await full.refresh()
        XCTAssertFalse(full.canPin("x"), "five is the limit")
    }

    func testLimitRefusalIsShownInWords() async {
        let api = FakePinsAPI()
        api.error = ConvoPinError.limit(5)
        let store = makeStore(api)
        let error = await store.pin("f", label: "Six", emoji: "")
        XCTAssertEqual(error, "You can pin up to 5 chats.")
        XCTAssertEqual(store.errorMessage, error)
    }

    func testMoveRepointsThePinKeepingItsPlace() async {
        let api = FakePinsAPI([pin("a", "Support", successor: "s"), pin("b", "Mail")])
        let store = makeStore(api)
        await store.refresh()
        await store.move("a", to: "s")
        XCTAssertEqual(store.pins.map(\.convoID), ["s", "b"])
        XCTAssertEqual(store.pins.first?.label, "Support")
        XCTAssertNil(store.pins.first?.successor)
    }

    func testDismissSendsTheSuccessorShown() async {
        let api = FakePinsAPI([pin("a", "Support", successor: "s")])
        let store = makeStore(api)
        await store.refresh()
        await store.dismissSuccessor(of: "a")
        XCTAssertEqual(api.calls, ["dismiss a s"])
        XCTAssertNil(store.pins.first?.successor)
        await store.dismissSuccessor(of: "a")
        XCTAssertEqual(api.calls.count, 1, "no hint, nothing to dismiss")
    }

    func testReorderShowsAtOnceAndRollsBackOnRefusal() async {
        let api = FakePinsAPI([pin("a", "A"), pin("b", "B"), pin("c", "C")])
        let store = makeStore(api)
        await store.refresh()
        await store.moveStep("c", up: true)
        XCTAssertEqual(store.pins.map(\.convoID), ["a", "c", "b"])
        XCTAssertEqual(api.calls, ["order a,c,b"])

        api.error = JournalAPIError.transport("offline")
        let error = await store.moveStep("a", up: false)
        XCTAssertNotNil(error)
        XCTAssertEqual(store.pins.map(\.convoID), ["a", "c", "b"], "the old order is back")
    }

    func testReorderIgnoresAnOrderThatIsNotEveryPin() async {
        let api = FakePinsAPI([pin("a", "A"), pin("b", "B")])
        let store = makeStore(api)
        await store.refresh()
        await store.reorder(["b"])
        XCTAssertEqual(api.calls, [])
    }

    func testSuccessorHintNamesTheBox() async {
        let store = makeStore(FakePinsAPI([pin("a", "Support", deviceID: 7, successor: "s"),
                                           pin("b", "Mail", deviceID: 8),
                                           pin("c", "Gone", deviceID: 7, successor: "s2", missing: true)]))
        store.start()
        await store.refresh()
        names.continuation.yield([7: "triage-box"])
        await eventually("box names") { !store.boxNames.isEmpty }
        XCTAssertEqual(store.successorHint(for: store.pins[0]), "New session on triage-box — move pin here?")
        XCTAssertNil(store.successorHint(for: store.pins[1]), "no successor, no hint")
        XCTAssertNil(store.successorHint(for: store.pins[2]), "a missing pin offers only Move pin… and Unpin")
        XCTAssertEqual(PinsStore.successorHint(boxName: nil), "New session on this box — move pin here?")
        store.stop()
    }

    func testSuggestedLabelPeelsTheSessionTag() {
        XCTAssertEqual(PinsStore.suggestedLabel(fromTitle: "[aa] Yes, I accept"), "Yes, I accept")
        XCTAssertEqual(PinsStore.suggestedLabel(fromTitle: "Inbox triage"), "Inbox triage")
        XCTAssertEqual(PinsStore.suggestedLabel(fromTitle: ""), ConvoPin.labelFallback)
        XCTAssertEqual(PinsStore.suggestedLabel(fromTitle: String(repeating: "x", count: 40)).count, 24)
    }

    func testAStaleGetDoesNotOverwriteALiveFrame() async {
        let api = FakePinsAPI([pin("old", "Old")])
        let store = makeStore(api)
        store.start()
        frames.continuation.yield([pin("new", "New")])
        await eventually("frame") { store.pins.first?.convoID == "new" }
        // A later GET answers with the journal's state, which now agrees.
        api.pinsNow = [pin("new", "New")]
        await store.refresh()
        XCTAssertEqual(store.pins.map(\.convoID), ["new"])
        store.stop()
    }
}
