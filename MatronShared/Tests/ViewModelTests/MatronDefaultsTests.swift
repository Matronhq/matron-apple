import XCTest
import MatronModels

/// The per-item and per-room keys move out of the observed domain into
/// their own, in one write, and the move happens once.
final class MatronDefaultsTests: XCTestCase {
    private let sourceName = "MatronDefaultsTests.source"
    private let destinationName = "MatronDefaultsTests.destination"
    private var source: UserDefaults!
    private var destination: UserDefaults!

    override func setUp() {
        super.setUp()
        source = UserDefaults(suiteName: sourceName)
        destination = UserDefaults(suiteName: destinationName)
        source.removePersistentDomain(forName: sourceName)
        destination.removePersistentDomain(forName: destinationName)
    }

    override func tearDown() {
        source.removePersistentDomain(forName: sourceName)
        destination.removePersistentDomain(forName: destinationName)
        super.tearDown()
    }

    func test_memoryKeysMove_andEverythingElseStays() {
        source.set(true, forKey: "items.readToEnd.it_1")
        source.set(["$1"], forKey: "matron.answeredPrompts.!room:s")
        source.set(["7": "approve"], forKey: "matron.agentChatAnswers.!room:s")
        source.set("convo", forKey: "coordinator.convoID.alice")

        let moved = MatronDefaults.moveMemoryKeys(from: source, domain: sourceName, to: destination)

        XCTAssertEqual(moved, 3)
        XCTAssertTrue(destination.bool(forKey: "items.readToEnd.it_1"))
        XCTAssertEqual(destination.stringArray(forKey: "matron.answeredPrompts.!room:s"), ["$1"])
        XCTAssertEqual(destination.dictionary(forKey: "matron.agentChatAnswers.!room:s") as? [String: String],
                       ["7": "approve"])
        XCTAssertNil(source.object(forKey: "items.readToEnd.it_1"))
        XCTAssertNil(source.object(forKey: "matron.answeredPrompts.!room:s"))
        XCTAssertNil(source.object(forKey: "matron.agentChatAnswers.!room:s"))
        XCTAssertEqual(source.string(forKey: "coordinator.convoID.alice"), "convo")
    }

    /// A value already written to the new home wins over a stale copy.
    func test_aValueAlreadyMoved_isNotOverwritten() {
        source.set(false, forKey: "items.readToEnd.it_1")
        destination.set(true, forKey: "items.readToEnd.it_1")

        MatronDefaults.moveMemoryKeys(from: source, domain: sourceName, to: destination)

        XCTAssertTrue(destination.bool(forKey: "items.readToEnd.it_1"))
        XCTAssertNil(source.object(forKey: "items.readToEnd.it_1"))
    }

    func test_nothingToMove_changesNothingButMarksTheMove() {
        source.set("convo", forKey: "coordinator.convoID.alice")

        XCTAssertEqual(MatronDefaults.moveMemoryKeys(from: source, domain: sourceName, to: destination), 0)
        XCTAssertEqual(source.string(forKey: "coordinator.convoID.alice"), "convo")
        XCTAssertTrue(destination.bool(forKey: "memory.movedFromStandard"))
    }
}
