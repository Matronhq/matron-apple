import XCTest
@testable import Matron

/// Spec §2 link taps: items, conversations and http route exactly as the
/// shared `MatronItemLink` policy says; `matron://` never reaches the OS.
@MainActor
final class TimelineLinkRouterTests: XCTestCase {
    private var items: [Int] = []
    private var convos: [String] = []
    private var external: [URL] = []

    private func router() -> TimelineLinkRouter {
        TimelineLinkRouter(openTrackerItem: { self.items.append($0) },
                           openConversation: { self.convos.append($0) },
                           openExternally: { self.external.append($0) })
    }

    func test_itemLink_opensTheItemInApp() {
        XCTAssertEqual(router().route(URL(string: "matron://item/65")!), .trackerItem(65))
        XCTAssertEqual(items, [65])
        XCTAssertTrue(external.isEmpty)
    }

    func test_conversationLink_opensTheConversationInApp() {
        XCTAssertEqual(router().route(URL(string: "matron://convo/abc-1")!), .conversation("abc-1"))
        XCTAssertEqual(convos, ["abc-1"])
    }

    func test_httpLink_goesToTheSystem() {
        let url = URL(string: "https://example.com/x")!
        XCTAssertEqual(router().route(url), .external(url))
        XCTAssertEqual(external, [url])
        XCTAssertTrue(TimelineLinkRouter.isSystemLink(url))
    }

    func test_unknownMatronAndMatrixLinks_areSwallowed() {
        for string in ["matron://link?code=AAAA", "matrix:r/room:s", "matron://item/0"] {
            XCTAssertEqual(router().route(URL(string: string)!), .swallowed, string)
            XCTAssertFalse(TimelineLinkRouter.isSystemLink(URL(string: string)!))
        }
        XCTAssertTrue(items.isEmpty && convos.isEmpty && external.isEmpty)
    }

    func test_noHandlerInstalled_stillNeverOpensExternally() {
        var opened: [URL] = []
        let bare = TimelineLinkRouter(openTrackerItem: nil, openConversation: nil, openExternally: { opened.append($0) })
        XCTAssertEqual(bare.route(URL(string: "matron://item/7")!), .trackerItem(7))
        XCTAssertTrue(opened.isEmpty)
    }
}
