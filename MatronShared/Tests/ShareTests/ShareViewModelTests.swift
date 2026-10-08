import XCTest
import UniformTypeIdentifiers
@testable import MatronJournal
import MatronModels
@testable import MatronShare

@MainActor
final class ShareViewModelTests: XCTestCase {
    private var directory: URL!
    private let transport = RecordingTransport()
    private let session = UserSession(userID: "me", deviceID: "1",
                                      homeserverURL: URL(string: "https://journal.example")!, accessToken: "tok")

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func environment(
        signedIn: Bool = true,
        cached: [ShareTarget]? = nil,
        fetched: Result<[ShareTarget], Error> = .success([])
    ) -> ShareEnvironment {
        let session = self.session
        let transport = self.transport
        return ShareEnvironment(
            session: { signedIn ? session : nil },
            cachedTargets: { _ in cached },
            fetchTargets: { _ in try fetched.get() },
            makeTransport: { _ in transport },
            workDirectory: directory)
    }

    private func zipProvider(named name: String = "archive.zip") throws -> NSItemProvider {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try Data([0x50, 0x4B, 0x05, 0x06]).write(to: url)
        return try XCTUnwrap(NSItemProvider(contentsOf: url))
    }

    private let coordinator = ShareTarget(id: "coord", title: "Coordinator", isCoordinator: true)
    private let other = ShareTarget(id: "c2", title: "Website", lastActivity: Date())

    func test_signedOut_saysSo() async throws {
        let model = ShareViewModel(environment: environment(signedIn: false))
        await model.load([try zipProvider()])
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertFalse(model.canSend)
    }

    func test_load_listsTheFile_andPicksTheCoordinator() async throws {
        let model = ShareViewModel(environment: environment(fetched: .success([other, coordinator])))

        await model.load([try zipProvider()])

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.files.map(\.filename), ["archive.zip"])
        XCTAssertEqual(model.targets.map(\.id), ["coord", "c2"])
        XCTAssertEqual(model.selectedTargetID, "coord")
        XCTAssertTrue(model.canSend)
    }

    func test_load_withNoCoordinator_waitsForAPick() async throws {
        let model = ShareViewModel(environment: environment(fetched: .success([other])))
        await model.load([try zipProvider()])
        XCTAssertNil(model.selectedTargetID)
        XCTAssertFalse(model.canSend)
        model.selectedTargetID = "c2"
        XCTAssertTrue(model.canSend)
    }

    func test_load_offline_usesTheCachedList_withoutComplaint() async throws {
        let model = ShareViewModel(environment: environment(
            cached: [coordinator, other], fetched: .failure(ShareSendError.failed("offline"))))
        await model.load([try zipProvider()])
        XCTAssertEqual(model.targets.map(\.id), ["coord", "c2"])
        XCTAssertNil(model.errorMessage)
    }

    func test_load_withNoListAtAll_explains() async throws {
        let model = ShareViewModel(environment: environment(fetched: .failure(ShareSendError.failed("offline"))))
        await model.load([try zipProvider()])
        XCTAssertTrue(model.targets.isEmpty)
        XCTAssertEqual(model.errorMessage, "Couldn't load your conversations. offline")
        XCTAssertFalse(model.isLoadingTargets)
    }

    func test_aFreshList_keepsThePickTheUserMade() async throws {
        let model = ShareViewModel(environment: environment(
            cached: [coordinator, other], fetched: .success([other, coordinator])))
        model.selectedTargetID = "c2"
        await model.load([])
        XCTAssertEqual(model.selectedTargetID, "c2")
    }

    func test_sharedTextAndLinks_fillTheMessage() async throws {
        let model = ShareViewModel(environment: environment(fetched: .success([coordinator])))
        await model.load([
            NSItemProvider(object: "Page title" as NSString),
            NSItemProvider(object: URL(string: "https://example.com/page")! as NSURL),
        ])
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertEqual(model.message, "Page title\nhttps://example.com/page")
        XCTAssertTrue(model.canSend)
    }

    func test_send_deliversToThePickedConversation_andCleansUp() async throws {
        let model = ShareViewModel(environment: environment(fetched: .success([coordinator, other])))
        await model.load([try zipProvider()])
        model.selectedTargetID = "c2"
        model.message = "the build"
        let copy = try XCTUnwrap(model.files.first?.url)

        await model.send()

        XCTAssertEqual(model.phase, .sent)
        guard case let .sendMedia(convoID, _, _, name, _, _, caption, _, _)? = transport.delivered.first?.first
        else { return XCTFail("nothing delivered") }
        XCTAssertEqual(convoID, "c2")
        XCTAssertEqual(name, "archive.zip")
        XCTAssertEqual(caption, "the build")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "the copy is deleted once sent")
    }

    func test_send_failure_keepsEverythingForAnotherTry() async throws {
        let model = ShareViewModel(environment: environment(fetched: .success([coordinator])))
        await model.load([try zipProvider()])
        transport.failNextDelivery(with: ShareSendError.failed("Couldn't reach the server."))

        await model.send()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.errorMessage, "Couldn't reach the server.")
        XCTAssertEqual(model.files.count, 1)
        XCTAssertTrue(model.canSend)

        await model.send()
        XCTAssertEqual(model.phase, .sent)
        XCTAssertEqual(transport.uploads, ["archive.zip"], "the retry does not upload again")
    }

    func test_removeFile_dropsItAndItsCopy() async throws {
        let model = ShareViewModel(environment: environment(fetched: .success([coordinator])))
        await model.load([try zipProvider()])
        let file = try XCTUnwrap(model.files.first)

        model.removeFile(id: file.id)

        XCTAssertTrue(model.files.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertFalse(model.canSend, "nothing left to send")
    }

    func test_snapshotRows_skipSubagentChats_andNameTheCoordinator() {
        let snapshot = SnapshotResponse(
            conversations: [
                ConvoSummaryDTO(id: "a", title: "[ab] Website", sessionState: "running", lastSeq: 1,
                                snippet: "", createdAt: 0, lastTS: 2_000, agentDeviceID: 7),
                ConvoSummaryDTO(id: "child", title: "Explore", sessionState: "done", lastSeq: 1,
                                snippet: "", createdAt: 0, lastTS: 3_000, parentConvoID: "a"),
                ConvoSummaryDTO(id: "coord", title: "", sessionState: "running", lastSeq: 1,
                                snippet: "", createdAt: 0),
            ],
            agents: [AgentDTO(id: 7, name: "studio"), AgentDTO(id: 8, name: "laptop")],
            seq: 5, coordinatorConvoID: "coord")

        let targets = ShareEnvironment.targets(from: snapshot)

        XCTAssertEqual(targets.map(\.id), ["a", "coord"])
        XCTAssertEqual(targets[0].title, "Website")
        XCTAssertEqual(targets[0].detail, "studio")
        XCTAssertEqual(targets[0].lastActivity, Date(timeIntervalSince1970: 2))
        XCTAssertEqual(targets[1].title, "Untitled")
        XCTAssertTrue(targets[1].isCoordinator)
    }
}
