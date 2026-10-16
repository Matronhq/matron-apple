import XCTest
import MatronModels
import MatronDesignSystem
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
        XCTAssertEqual(router().route(URL(string: "matron://convo/xyz-1")!), .conversation("xyz-1"))
        XCTAssertEqual(convos, ["xyz-1"])
    }

    func test_missionAndProjectLinks_openThePageInApp() {
        var pages: [MatronPageLink] = []
        let router = TimelineLinkRouter(openPageLink: { pages.append($0) }, openExternally: { self.external.append($0) })
        XCTAssertEqual(router.route(URL(string: "matron://mission/61")!), .page(.mission(61)))
        XCTAssertEqual(router.route(URL(string: "matron://project/12")!), .page(.project(12)))
        XCTAssertEqual(pages, [.mission(61), .project(12)])
        XCTAssertTrue(external.isEmpty)
        XCTAssertFalse(TimelineLinkRouter.isSystemLink(URL(string: "matron://mission/61")!))
    }

    func test_ownShareableLink_opensInAppThroughTheItemOpener() async {
        let origin = TrackerLinkOrigin(serverURL: URL(string: "https://journal.example.com")!, user: "alice")!
        let opened = expectation(description: "item opened")
        let router = TimelineLinkRouter(openTrackerItem: { self.items.append($0); opened.fulfill() },
                                        trackerNumberLinks: TrackerNumberLinks(origin: origin, find: { .item($0) }),
                                        openExternally: { self.external.append($0) })
        let own = URL(string: "https://journal.example.com/u/alice/65")!
        XCTAssertFalse(router.isSystemLink(own))
        XCTAssertEqual(router.route(own), .trackerNumber(65))
        await fulfillment(of: [opened], timeout: 2)
        XCTAssertEqual(items, [65])
        XCTAssertTrue(external.isEmpty)

        // Another person's number goes through the host too; with no
        // shared viewer installed (iPhone) it ends in the browser.
        let other = URL(string: "https://journal.example.com/u/bob/65")!
        XCTAssertFalse(router.isSystemLink(other))
        XCTAssertEqual(router.route(other), .trackerNumber(65))
        XCTAssertEqual(external, [other])
        XCTAssertEqual(items, [65])
        XCTAssertTrue(TimelineLinkRouter.isSystemLink(own), "without the host it is a web link")
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
