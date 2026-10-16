import XCTest
import MatronChat
import MatronModels
@testable import MatronViewModels

@MainActor
final class ArchivedChatsViewModelTests: XCTestCase {
    private func summary(_ id: String, title: String, snippet: String = "", box: String? = nil) -> ChatSummary {
        ChatSummary(id: id, title: title,
                    bot: BotIdentity(matrixID: "agent:claude", displayName: "Claude", avatarURL: nil),
                    lastActivity: nil, unreadCount: 0, snippet: snippet, boxName: box)
    }

    func testFilterMatchesEveryWordAcrossTitleSnippetAndBox() {
        let rows = [
            summary("a", title: "Release notes", snippet: "drafted the changelog", box: "box-a"),
            summary("b", title: "Café menu", snippet: "prices"),
            summary("c", title: "Release checklist", box: "box-b"),
        ]
        XCTAssertEqual(ArchivedChatsViewModel.filter(rows, query: "").map(\.id), ["a", "b", "c"])
        XCTAssertEqual(ArchivedChatsViewModel.filter(rows, query: "release").map(\.id), ["a", "c"])
        XCTAssertEqual(ArchivedChatsViewModel.filter(rows, query: "release box-b").map(\.id), ["c"])
        XCTAssertEqual(ArchivedChatsViewModel.filter(rows, query: "CHANGELOG").map(\.id), ["a"])
        XCTAssertEqual(ArchivedChatsViewModel.filter(rows, query: "cafe").map(\.id), ["b"], "accents ignored")
        XCTAssertEqual(ArchivedChatsViewModel.filter(rows, query: "nothing").map(\.id), [])
    }

    func testItShowsTheServicesArchivedListAndUnarchives() async {
        let service = FakeArchiveService(archived: [summary("a", title: "Old")])
        let model = ArchivedChatsViewModel(chat: service)
        model.start()
        for _ in 0..<200 where model.isLoading { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.summaries.map(\.id), ["a"])
        await model.unarchive(["a"])
        let calls = await service.unarchived
        XCTAssertEqual(calls, [["a"]])
        model.cancel()
    }
}

private actor FakeArchiveService: ChatService {
    let archived: [ChatSummary]
    var unarchived: [[String]] = []

    init(archived: [ChatSummary]) { self.archived = archived }

    nonisolated func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> { AsyncThrowingStream { $0.finish() } }
    nonisolated func archivedChatSummaries() -> AsyncStream<[ChatSummary]> {
        let rows = archived
        return AsyncStream { $0.yield(rows) }
    }
    nonisolated func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> { AsyncStream { $0.finish() } }
    func createChat(with botID: String) async throws -> String { "" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func setArchived(_ roomIDs: [String], archived: Bool) async {
        if !archived { unarchived.append(roomIDs) }
    }
}
