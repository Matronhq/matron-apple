import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

/// The Search page: every section, the number's "Go to" row first, the
/// loose-match tags, and the empty and no-results states.
final class GlobalSearchSnapshotTests: XCTestCase {
    private let ts = Date(timeIntervalSince1970: 1_790_560_000)

    private var page: GlobalSearchPage {
        GlobalSearchPage(
            query: "proxy",
            status: .done,
            number: nil,
            conversations: [
                .init(id: "c1", title: "Proxy rollout", subtitle: "Restarted the proxy on box-a"),
            ],
            results: [
                GlobalSearchResult(kind: .item, id: "it_1", num: 12, title: "Pick the proxy timeout", state: "open",
                                   why: "exact"),
                GlobalSearchResult(kind: .mission, id: "ms_1", num: 20, title: "Proxy hardening", why: "stemmed",
                                   snippet: "**Proxy** hardening Reload the **proxies** without dropping requests"),
                GlobalSearchResult(kind: .project, id: "pj_1", num: 3, title: "Edge network", state: "open",
                                   why: "some_words"),
                GlobalSearchResult(kind: .memory, id: "proxy-timeouts", name: "proxy-timeouts",
                                   title: "Keep the proxy timeout at 120s", why: "similar"),
            ],
            chats: [
                GlobalSearchChat(convoID: "c2", title: "Load balancer", count: 3, isExact: true,
                                 top: .init(seq: 41, ts: ts, sender: "agent:box-b",
                                            excerpt: "…the **proxy** answered in 80 ms…")),
            ])
    }

    private func view(_ page: GlobalSearchPage, text: String, filter: GlobalSearchFilter = .all) -> some View {
        GlobalSearchView(text: .constant(text), filter: .constant(filter), page: page,
                         onSubmit: {}, onOpen: { _ in })
            .frame(width: 420, height: 640)
    }

    func testEveryWhyLabelIsShortWords() {
        XCTAssertEqual(page.results.compactMap(\.whyLabel), ["similar words", "some words", "similar meaning"])
    }

    func testAllSections() {
        assertVariants(of: view(page, text: "proxy"), named: "global-search-all")
    }

    func testNarrowedToMissions() {
        assertVariants(of: view(page, text: "proxy", filter: .missions), named: "global-search-missions")
    }

    func testANumberGoesFirst() {
        let page = GlobalSearchPage(
            query: "412", status: .done,
            number: .init(label: "#412 · Item — Fix the parser", canOpen: true),
            results: [GlobalSearchResult(kind: .mission, id: "ms_9", num: 9, title: "Parser rewrite",
                                         why: "words", snippet: "Parser rewrite Starts with #**412**")])
        assertVariants(of: view(page, text: "412"), named: "global-search-number")
    }

    func testEmpty() {
        assertVariants(of: view(GlobalSearchPage(query: "", status: .empty), text: ""), named: "global-search-empty")
    }

    func testNoResults() {
        assertVariants(of: view(GlobalSearchPage(query: "zebra", status: .done), text: "zebra"),
                       named: "global-search-no-results")
    }
}
