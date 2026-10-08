import XCTest
import MatronChat
import MatronModels
import MatronShare
@testable import Matron

final class ShareTargetsPublisherTests: XCTestCase {
    private func summary(_ id: String, title: String, at seconds: TimeInterval? = nil,
                         parent: String? = nil, box: String? = nil) -> ChatSummary {
        ChatSummary(id: id, title: title, bot: BotIdentity(matrixID: "bot", displayName: "Bot", avatarURL: nil),
                    lastActivity: seconds.map(Date.init(timeIntervalSince1970:)), unreadCount: 0,
                    parentConvoID: parent, boxName: box)
    }

    func test_targets_putTheCoordinatorFirst_andLeaveOutSubagentChats() {
        let summaries = [
            summary("a", title: "Website", at: 10, box: "studio"),
            summary("child", title: "Explore", at: 30, parent: "a"),
            summary("coord", title: "Coordinator", at: 5),
            summary("b", title: "", at: 20),
        ]

        let targets = ShareTargetsPublisher.targets(from: summaries, coordinatorID: "coord")

        XCTAssertEqual(targets.map(\.id), ["coord", "b", "a"])
        XCTAssertTrue(targets[0].isCoordinator)
        XCTAssertEqual(targets[1].title, "Untitled")
        XCTAssertEqual(targets[2].detail, "studio")
    }

    func test_publish_writesTheListTheExtensionReads() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }

        ShareTargetsPublisher.publish([summary("a", title: "Website", at: 10)], coordinatorID: nil,
                                      userID: "me", container: container)

        let deadline = Date().addingTimeInterval(5)
        while ShareTargetsCache.read(userID: "me", in: container) == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(ShareTargetsCache.read(userID: "me", in: container)?.map(\.id), ["a"])

        ShareTargetsPublisher.clear(container: container)
        XCTAssertNil(ShareTargetsCache.read(userID: "me", in: container))
    }

    /// Before the chat list has loaded there is nothing to say, and saying
    /// "no conversations" would wipe a good list.
    func test_publish_ofAnEmptyList_keepsTheLastOne() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        try ShareTargetsCache.write([ShareTarget(id: "a", title: "Website")], userID: "me", in: container)

        ShareTargetsPublisher.publish([], coordinatorID: nil, userID: "me", container: container)

        XCTAssertEqual(ShareTargetsCache.read(userID: "me", in: container)?.map(\.id), ["a"])
    }
}
