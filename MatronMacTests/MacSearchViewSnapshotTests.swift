#if os(macOS)
import XCTest
import SnapshotTesting
import SwiftUI
import MatronSearch
import MatronChat       // ChatSummary
import MatronModels
import MatronViewModels
@testable import MatronMac

/// Local `SearchService` fake — the SPM `ViewModelTests` fake isn't reachable
/// from this Xcode test bundle. Hits are set via init (an actor's isolated
/// property can't be assigned from outside).
private actor FakeSearchService: SearchService {
    private let hits: [SearchHit]
    init(hits: [SearchHit] = []) { self.hits = hits }
    func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {}
    func remove(eventID: String) async throws {}
    func query(_ text: String, limit: Int) async throws -> [SearchHit] { hits }
    func wipe() async throws {}
    func resetBackfill() async throws {}
}

final class MacSearchViewSnapshotTests: XCTestCase {
    @MainActor
    func test_macSearchResultsView_populated() async {
        let claude = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        let chats = [ChatSummary(id: "!1:s", title: "Auth bug", bot: claude, lastActivity: nil, unreadCount: 0,
                                 snippet: "Pushed the fix for the token refresh")]
        let hit = SearchHit(
            id: "$1", roomID: "!1:s", sender: "@claude:s",
            timestamp: Date(timeIntervalSince1970: 1_745_000_000),
            snippet: "the <mark>auth</mark> bug is in src/auth.rs"
        )
        let vm = SearchViewModel(search: FakeSearchService(hits: [hit]), allChats: chats)
        vm.query = "auth"
        await vm.search()  // populate messageHits so the Messages section renders
        let view = MacSearchResultsView(viewModel: vm, onSelectChat: { _ in }, onSelectMessage: { _ in })
            .frame(width: 420, height: 320)
        assertVariants(of: view, named: "MacSearchResultsView_populated")
    }
}
#endif
