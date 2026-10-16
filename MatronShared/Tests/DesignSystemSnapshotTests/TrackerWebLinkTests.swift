import XCTest
import MatronModels
@testable import MatronDesignSystem

/// Shareable tracker links (`https://<journal>/u/<user>/<n>`): which ones
/// open in-app, and how a link from outside the app is routed.
final class TrackerWebLinkTests: XCTestCase {
    private let origin = TrackerLinkOrigin(serverURL: URL(string: "https://journal.example.com")!, user: "alice")!

    private func url(_ string: String) -> URL { URL(string: string)! }

    func test_ownLinkOnThisJournal_isANumber() {
        let accepted: [(String, Int)] = [
            ("https://journal.example.com/u/alice/412", 412),
            ("https://journal.example.com/u/alice/412/", 412),
            ("HTTPS://Journal.Example.com/u/alice/1", 1),
            ("https://journal.example.com:443/u/alice/7", 7),
        ]
        for (string, num) in accepted {
            XCTAssertEqual(origin.number(in: url(string)), num, string)
        }
    }

    func test_everythingElse_isNotANumber() {
        let rejected = [
            "https://journal.example.com/u/bob/412",       // another person's number
            "https://journal.example.com/u/Alice/412",     // names must match exactly
            "https://other.example.com/u/alice/412",       // another journal
            "http://journal.example.com/u/alice/412",      // another scheme
            "https://journal.example.com:8443/u/alice/412", // another port
            "https://journal.example.com/u/alice/0",
            "https://journal.example.com/u/alice/-4",
            "https://journal.example.com/u/alice/4a",
            "https://journal.example.com/u/alice/%34",
            "https://journal.example.com/u/alice/",
            "https://journal.example.com/u/alice/412/extra",
            "https://journal.example.com/u/alice//412",
            "https://journal.example.com/u/alice/412?x=1",
            "https://journal.example.com/u/alice/412#top",
            "https://eve@journal.example.com/u/alice/412",
            "https://journal.example.com/v/alice/412",
            "https://journal.example.com/u/412",
            "matron://item/7",
        ]
        for string in rejected {
            XCTAssertNil(origin.number(in: url(string)), string)
        }
    }

    func test_anyonesLinkOnThisJournal_namesWhoseNumberItIs() {
        XCTAssertEqual(origin.link(in: url("https://journal.example.com/u/bob/412")),
                       TrackerLinkPath(user: "bob", num: 412))
        XCTAssertEqual(origin.link(in: url("https://journal.example.com/u/alice/3/")),
                       TrackerLinkPath(user: "alice", num: 3))
        for string in ["https://other.example.com/u/bob/412", "https://journal.example.com/u//412",
                       "https://journal.example.com/u/bob/0", "https://journal.example.com/u/bob/412?x=1"] {
            XCTAssertNil(origin.link(in: url(string)), string)
        }
    }

    func test_aNameWithASlashControlOrBidiCharacter_isNotALink() {
        for string in ["https://journal.example.com/u/a%2Fb/4", "https://journal.example.com/u/a%0Ab/4",
                       "https://journal.example.com/u/a%E2%80%AEb/4", "https://journal.example.com/u/a%E2%81%A6b/4"] {
            XCTAssertNil(origin.link(in: url(string)), string)
        }
        XCTAssertEqual(origin.link(in: url("https://journal.example.com/u/a%20b/4")), TrackerLinkPath(user: "a b", num: 4))
    }

    @MainActor
    func test_redirecting_sendsOwnLinksAndOtherPeoplesAwayFromThePassedOpeners() {
        var own: [URL] = []
        var others: [TrackerLinkPath] = []
        let links = TrackerNumberLinks(origin: origin, find: { _ in .item(1) })
            .redirecting(own: { own.append($0) }, others: { link, _ in others.append(link) })
        let mine = url("https://journal.example.com/u/alice/3")
        links.open(3, url: mine, openItem: { _ in XCTFail("the viewer's opener names the other person's number") },
                   openPage: nil, openWeb: { _ in XCTFail("not the browser") })
        links.open(4, url: url("https://journal.example.com/u/carol/4"), openItem: nil, openPage: nil,
                   openWeb: { _ in XCTFail("not the browser") })
        XCTAssertEqual(own, [mine])
        XCTAssertEqual(others, [TrackerLinkPath(user: "carol", num: 4)])
    }

    func test_aJournalUnderAPath_matchesBelowIt() {
        let nested = TrackerLinkOrigin(serverURL: url("https://example.com/journal/"), user: "alice")!
        XCTAssertEqual(nested.number(in: url("https://example.com/journal/u/alice/9")), 9)
        XCTAssertNil(nested.number(in: url("https://example.com/u/alice/9")))
    }

    func test_anEncodedUserName_matchesDecoded() {
        let spaced = TrackerLinkOrigin(serverURL: url("https://journal.example.com"), user: "a b")!
        XCTAssertEqual(spaced.number(in: url("https://journal.example.com/u/a%20b/3")), 3)
    }

    func test_noOriginWithoutAWebServerOrAUser() {
        XCTAssertNil(TrackerLinkOrigin(serverURL: url("matron://journal"), user: "alice"))
        XCTAssertNil(TrackerLinkOrigin(serverURL: url("https://journal.example.com"), user: ""))
    }

    func test_policy_opensOwnLinksInAppOnlyWithAnOrigin() {
        let link = url("https://journal.example.com/u/alice/412")
        XCTAssertEqual(MatronItemLink.action(for: link, numbers: origin), .openTrackerNumber(412))
        XCTAssertEqual(MatronItemLink.action(for: link), .system(link), "no host: an ordinary web link")
        let other = url("https://journal.example.com/u/bob/412")
        XCTAssertEqual(MatronItemLink.action(for: other, numbers: origin), .openTrackerNumber(412),
                       "another person's link on this journal stays in-app too")
        let elsewhere = url("https://other.example.com/u/alice/412")
        XCTAssertEqual(MatronItemLink.action(for: elsewhere, numbers: origin), .system(elsewhere))
        XCTAssertEqual(MatronItemLink.action(for: url("matron://item/5"), numbers: origin), .openTrackerItem(5))
    }

    func test_incomingLink_routesOwnNumbersAndOtherPeoplesInAppAndTheRestToTheBrowser() {
        XCTAssertEqual(origin.route(incoming: url("https://journal.example.com/u/alice/412")), .number(412))
        XCTAssertEqual(origin.route(incoming: url("https://journal.example.com/u/bob/412")),
                       .othersLink(TrackerLinkPath(user: "bob", num: 412)))
        let elsewhere = url("https://other.example.com/u/alice/412")
        XCTAssertEqual(origin.route(incoming: elsewhere), .browser(elsewhere))
    }

    @MainActor
    func test_incomingLinks_keepTheLatestWebLinkUntilTakenOnce() {
        let inbox = IncomingTrackerLinks()
        inbox.receive(url("matron://item/1"))
        XCTAssertNil(inbox.pending, "not a web link")
        inbox.receive(url("https://journal.example.com/u/alice/1"))
        inbox.receive(url("https://journal.example.com/u/alice/2"))
        XCTAssertEqual(inbox.take(), url("https://journal.example.com/u/alice/2"))
        XCTAssertNil(inbox.take(), "a second window gets nothing")
    }

    @MainActor
    func test_open_goesThroughTheOpenerForWhatTheNumberNames() async {
        func run(_ target: TrackerNumberLinkTarget, itemHost: Bool = true) async -> String {
            let done = expectation(description: "opened")
            var opened = ""
            let links = TrackerNumberLinks(origin: origin, find: { _ in target })
            links.open(5, url: url("https://journal.example.com/u/alice/5"),
                       openItem: itemHost ? { opened = "item \($0)"; done.fulfill() } : nil,
                       openPage: { opened = "page \($0.num)"; done.fulfill() },
                       openWeb: { opened = "web \($0.lastPathComponent)"; done.fulfill() })
            await fulfillment(of: [done], timeout: 2)
            return opened
        }
        let item = await run(.item(5))
        let page = await run(.page(.mission(7)))
        let web = await run(.web)
        let noHost = await run(.item(5), itemHost: false)
        XCTAssertEqual(item, "item 5")
        XCTAssertEqual(page, "page 7")
        XCTAssertEqual(web, "web 5")
        XCTAssertEqual(noHost, "web 5", "no item opener here: the browser")
    }

    @MainActor
    func test_open_showsAnotherPersonsLinkInTheViewer_orTheBrowserWithoutOne() {
        let bobs = url("https://journal.example.com/u/bob/5")
        var shown: [TrackerLinkPath] = []
        var web: [URL] = []
        let withViewer = TrackerNumberLinks(origin: origin, find: { _ in .item(5) },
                                            showOthers: { link, _ in shown.append(link) })
        withViewer.open(5, url: bobs, openItem: { _ in XCTFail("not the user's own item") }, openPage: nil,
                        openWeb: { web.append($0) })
        XCTAssertEqual(shown, [TrackerLinkPath(user: "bob", num: 5)])
        XCTAssertEqual(web, [])

        let withoutViewer = TrackerNumberLinks(origin: origin, find: { _ in .item(5) })
        withoutViewer.open(5, url: bobs, openItem: { _ in XCTFail("not the user's own item") }, openPage: nil,
                           openWeb: { web.append($0) })
        XCTAssertEqual(web, [bobs])
    }
}
