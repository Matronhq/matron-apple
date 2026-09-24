import XCTest
import SwiftUI
@testable import MatronDesignSystem

/// Conversation deep links (`[title](matron://convo/<id>)`, decision #2954).
/// Agents write them into ordinary message bodies — like tracker-item links —
/// so the parser is the boundary between "open that conversation in-app" and
/// "hand an unregistered scheme to the OS". The pill row under a bubble is
/// derived from the same parser, so extraction, de-duplication, the cap and
/// the label fallback are pinned here too.
final class ConversationLinkTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return URL(string: "about:blank")!
        }
        return url
    }

    // MARK: - Parsing

    func test_conversationID_acceptsCanonicalForms() {
        let accepted: [(String, String)] = [
            ("matron://convo/2f1c9a4e-7b1d-4c55-9a51-0d3c2b1e8f00", "2f1c9a4e-7b1d-4c55-9a51-0d3c2b1e8f00"),
            ("matron://convo/child-1", "child-1"),
            ("matron://convo/abc_DEF.9", "abc_DEF.9"),
            // Sub-chat ids carry a colon-separated suffix.
            ("matron://convo/parent:sub:agent-7", "parent:sub:agent-7"),
            // Percent-encoded characters are decoded before validation.
            ("matron://convo/parent%3Asub%3Aagent-7", "parent:sub:agent-7"),
            ("matron://convo/%61bc", "abc"),
            // Scheme + host are case-insensitive per RFC 3986; the id is not.
            ("MATRON://CONVO/AbC", "AbC"),
        ]
        for (string, expected) in accepted {
            XCTAssertEqual(MatronItemLink.conversationID(from: url(string)), expected,
                           "\(string) should parse as conversation \(expected)")
        }
    }

    func test_conversationID_rejectsEverythingElse() {
        let rejected = [
            "matron://convo/",                  // no id
            "matron://convo",                   // no path at all
            "matron://convo/abc/def",           // second segment
            "matron://convo/abc/",              // trailing empty segment
            "matron://convo//abc",              // leading empty segment
            "matron://convo/abc%2Fdef",         // an encoded slash is still a separator
            "matron://convo/%2E%2E",            // ".." once decoded
            "matron://convo/.",                 // "."
            "matron://convo/a%20b",             // whitespace once decoded
            "matron://convo/a%0Ab",             // control character once decoded
            "matron://convo/%E2%80%AEabc",      // bidi override once decoded
            "matron://convo/caf%C3%A9",         // non-ASCII once decoded
            "matron://convo/%ZZ",               // malformed escape
            "matron://convo/abc?x=1",           // query
            "matron://convo/abc#frag",          // fragment
            "matron://convo:80/abc",            // port
            "matron://dan@convo/abc",           // userinfo
            "matron://convos/abc",              // wrong host
            "matron://conversation/abc",        // wrong host
            "matron://item/65",                 // an item link is not a conversation
            "https://matron.chat/convo/abc",
            "convo://abc",
            "matron://convo/" + String(repeating: "a", count: 129), // over the journal's 128-char cap
        ]
        for string in rejected {
            guard let parsed = URL(string: string) else { continue }
            XCTAssertNil(MatronItemLink.conversationID(from: parsed),
                         "\(string) must not parse as a conversation link")
        }
        XCTAssertEqual(MatronItemLink.conversationID(from: url("matron://convo/" + String(repeating: "a", count: 128))),
                       String(repeating: "a", count: 128), "128 chars is the journal's ceiling, inclusive")
    }

    // MARK: - Link policy

    func test_action_routesConversationLinksInApp() {
        XCTAssertEqual(MatronItemLink.action(for: url("matron://convo/child-1")), .openConversation("child-1"))
        XCTAssertEqual(MatronItemLink.action(for: url("matron://convo/a%3Ab")), .openConversation("a:b"))
    }

    /// The other `matron://` links keep their behaviour.
    func test_action_leavesOtherMatronLinksAlone() {
        XCTAssertEqual(MatronItemLink.action(for: url("matron://item/65")), .openTrackerItem(65))
        for string in ["matron://convo/", "matron://convo/a/b", "matron://link/abc", "matron://convos/abc"] {
            XCTAssertEqual(MatronItemLink.action(for: url(string)), .swallow,
                           "\(string) must be swallowed, never handed to the OS")
        }
    }

    func test_handle_conversationLink_callsTheConversationHandlerOnly() {
        var conversations: [String] = []
        var items: [Int] = []
        _ = MarkdownText.handle(url: url("matron://convo/child-1"),
                                openItem: { items.append($0) },
                                openConversation: { conversations.append($0) })
        XCTAssertEqual(conversations, ["child-1"])
        XCTAssertTrue(items.isEmpty)
    }

    func test_handle_itemLink_neverReachesTheConversationHandler() {
        var conversations: [String] = []
        for string in ["matron://item/65", "https://matron.chat", "matron://convo/a/b"] {
            _ = MarkdownText.handle(url: url(string), openItem: { _ in },
                                    openConversation: { conversations.append($0) })
        }
        XCTAssertTrue(conversations.isEmpty)
    }

    // MARK: - Extraction (the pill row's source)

    func test_extract_findsConversationLinksInOrder() {
        let body = "Started [Auth refactor](matron://convo/c-1) and [Docs](matron://convo/c-2)."
        XCTAssertEqual(ConversationLinkRefs.extract(from: body),
                       [.init(id: "c-1", text: "Auth refactor"), .init(id: "c-2", text: "Docs")])
    }

    func test_extract_deduplicatesByIDKeepingTheFirstText() {
        let body = "[One](matron://convo/c-1), [again](matron://convo/c-1) and [Two](matron://convo/c-2)"
        XCTAssertEqual(ConversationLinkRefs.extract(from: body),
                       [.init(id: "c-1", text: "One"), .init(id: "c-2", text: "Two")])
    }

    func test_extract_ignoresEverythingThatIsNotAConversationLink() {
        let body = """
        See [#65](matron://item/65), [site](https://matron.chat), [bad](matron://convo/a/b),
        a bare matron://convo/c-9 and `[code](matron://convo/c-8)`.
        """
        XCTAssertEqual(ConversationLinkRefs.extract(from: body), [])
    }

    func test_extract_decodesEncodedIDs() {
        XCTAssertEqual(ConversationLinkRefs.extract(from: "[Sub](matron://convo/p%3Asub%3A1)"),
                       [.init(id: "p:sub:1", text: "Sub")])
    }

    func test_extract_keepsFormattedLinkTextAsPlainText() {
        XCTAssertEqual(ConversationLinkRefs.extract(from: "[**Bold** title](matron://convo/c-1)"),
                       [.init(id: "c-1", text: "Bold title")])
    }

    func test_extract_plainBodyIsEmpty() {
        XCTAssertEqual(ConversationLinkRefs.extract(from: "Nothing to see here."), [])
        XCTAssertEqual(ConversationLinkRefs.extract(from: ""), [])
    }

    // MARK: - Cap

    func test_layout_showsUpToFourThenOverflow() {
        let refs = (1...6).map { ConversationLinkRef(id: "c-\($0)", text: "T\($0)") }
        let four = ConversationPillLayout(refs: Array(refs.prefix(4)))
        XCTAssertEqual(four.visible.map(\.id), ["c-1", "c-2", "c-3", "c-4"])
        XCTAssertEqual(four.overflow, [])

        let six = ConversationPillLayout(refs: refs)
        XCTAssertEqual(six.visible.map(\.id), ["c-1", "c-2", "c-3", "c-4"])
        XCTAssertEqual(six.overflow.map(\.id), ["c-5", "c-6"], "rendered as \"+2\"")
    }

    // MARK: - Label + availability

    func test_label_prefersTheCurrentTitleThenTheLinkTextThenAPlaceholder() {
        let ref = ConversationLinkRef(id: "c-1", text: "Old title")
        XCTAssertEqual(ConversationLinkLabel.text(for: ref, title: .known("Renamed")), "Renamed")
        XCTAssertEqual(ConversationLinkLabel.text(for: ref, title: .known("  ")), "Old title",
                       "an untitled conversation falls back to the link text")
        XCTAssertEqual(ConversationLinkLabel.text(for: ref, title: .unknown), "Old title")
        XCTAssertEqual(ConversationLinkLabel.text(for: ref, title: nil), "Old title")
        let bare = ConversationLinkRef(id: "c-1", text: " ")
        XCTAssertEqual(ConversationLinkLabel.text(for: bare, title: .unknown), "Conversation")
        XCTAssertEqual(ConversationLinkLabel.text(for: bare, title: .known("")), "Conversation")
    }

    func test_onlyKnownConversationsAreOpenable() {
        XCTAssertTrue(ConversationLinkLabel.isOpenable(.known("x")))
        XCTAssertTrue(ConversationLinkLabel.isOpenable(.known("")), "known but untitled still opens")
        XCTAssertFalse(ConversationLinkLabel.isOpenable(.unknown))
        XCTAssertFalse(ConversationLinkLabel.isOpenable(nil), "not looked up yet")
    }
}

/// The per-window host: title lookups for the pills, and the inline-link /
/// pill tap → navigation hop.
@MainActor
final class ConversationLinkHostTests: XCTestCase {

    private func host(_ titles: [String: String]) -> ConversationLinkHost {
        ConversationLinkHost(lookup: { id in titles[id].map { .known($0) } ?? .unknown })
    }

    func test_load_resolvesTitlesFromTheLookup() async {
        let host = host(["c-1": "Auth refactor"])
        XCTAssertNil(host.title(for: "c-1"))
        await host.load("c-1")
        await host.load("gone")
        XCTAssertEqual(host.title(for: "c-1"), .known("Auth refactor"))
        XCTAssertEqual(host.title(for: "gone"), .unknown)
    }

    /// Live titles: a chat-list snapshot updates conversations a pill is
    /// already showing — and only those, so an unrelated list change does not
    /// touch (and invalidate) the pills.
    func test_absorb_updatesOnlyTrackedConversations() async {
        let host = host(["c-1": "Old"])
        await host.load("c-1")
        await host.load("c-2")
        host.absorb([.init(id: "c-1", title: "New"), .init(id: "c-2", title: "Arrived"),
                     .init(id: "c-3", title: "Untracked")])
        XCTAssertEqual(host.title(for: "c-1"), .known("New"))
        XCTAssertEqual(host.title(for: "c-2"), .known("Arrived"), "an unknown conversation that syncs in becomes openable")
        XCTAssertNil(host.title(for: "c-3"))
    }

    func test_reset_forgetsTheOldStoresTitles() async {
        let host = host(["c-1": "Old account"])
        await host.load("c-1")
        let before = host.generation
        host.reset(lookup: { _ in .unknown })
        XCTAssertNil(host.title(for: "c-1"))
        XCTAssertEqual(host.generation, before + 1, "pills key their load on this, so they reload")
        await host.load("c-1")
        XCTAssertEqual(host.title(for: "c-1"), .unknown)
    }

    func test_titleLookup_mapsStoreAnswers() async {
        struct Failure: Error {}
        let host = ConversationLinkHost()
        host.reset(titleLookup: { id in
            switch id {
            case "titled": return "Auth"
            case "untitled": return ""
            case "broken": throw Failure()
            default: return nil
            }
        })
        for id in ["titled", "untitled", "broken", "missing"] { await host.load(id) }
        XCTAssertEqual(host.title(for: "titled"), .known("Auth"))
        XCTAssertEqual(host.title(for: "untitled"), .known(""))
        XCTAssertEqual(host.title(for: "broken"), .unknown)
        XCTAssertEqual(host.title(for: "missing"), .unknown)
    }

    /// A lookup that started against the previous store must not land its
    /// answer after a reset (CodeRabbit, PR #241).
    func test_load_fromAnEarlierGenerationIsDiscarded() async {
        let gate = Gate()
        let host = ConversationLinkHost(lookup: { _ in await gate.wait(); return .unknown })
        let stale = Task { await host.load("c-1") }
        await gate.waitUntilEntered()
        host.reset(lookup: { _ in .known("New store") })
        await host.load("c-1")
        await gate.open()
        await stale.value
        XCTAssertEqual(host.title(for: "c-1"), .known("New store"))
    }

    /// A tap resolving across a reset opens nothing — it belonged to the
    /// old session (CodeRabbit, PR #241).
    func test_tap_resolvingAcrossAResetOpensNothing() async {
        let gate = Gate()
        let host = ConversationLinkHost(lookup: { _ in await gate.wait(); return .known("Old") })
        host.action("c-1")
        let tap = host.pending!
        let resolving = Task { await host.resolve(tap) }
        await gate.waitUntilEntered()
        host.reset(lookup: { _ in .known("New") })
        XCTAssertNil(host.pending, "a reset drops the pending tap")
        await gate.open()
        let opened = await resolving.value
        XCTAssertNil(opened)
    }

    /// Streaming rows grow their body every commit; they must not fill the
    /// memo (Bugbot, PR #241).
    func test_extract_withoutCachingStillParses() {
        let body = "[Live](matron://convo/c-streaming-\(UUID().uuidString.prefix(8)))"
        XCTAssertEqual(ConversationLinkRefs.extract(from: body, cache: false).map(\.text), ["Live"])
        XCTAssertFalse(ConversationLinkRefs.isCached(body))
        _ = ConversationLinkRefs.extract(from: body)
        XCTAssertTrue(ConversationLinkRefs.isCached(body))
    }

    func test_tap_opensAKnownConversation() async {
        let host = host(["c-1": "Auth"])
        host.action("c-1")
        let tap = try? XCTUnwrap(host.pending)
        let opened = await host.resolve(tap!)
        XCTAssertEqual(opened, "c-1")
    }

    func test_tap_onAnUnknownConversationOpensNothing() async {
        let host = host([:])
        host.action("nope")
        let opened = await host.resolve(host.pending!)
        XCTAssertNil(opened)
        XCTAssertEqual(host.title(for: "nope"), .unknown, "the miss is remembered so the pill disables")
    }

    /// Last tap wins: a tap superseded while its lookup ran opens nothing.
    func test_tap_supersededByANewerTapOpensNothing() async {
        let host = host(["c-1": "A", "c-2": "B"])
        host.action("c-1")
        let first = host.pending!
        host.action("c-2")
        let second = host.pending!
        let openedFirst = await host.resolve(first)
        let openedSecond = await host.resolve(second)
        XCTAssertNil(openedFirst)
        XCTAssertEqual(openedSecond, "c-2")
    }

    func test_twoTapsOnTheSameConversationAreDistinct() {
        let host = host([:])
        host.action("c-1")
        let first = host.pending
        host.action("c-1")
        XCTAssertNotEqual(host.pending, first)
    }
}

/// A one-shot latch for ordering an async lookup against a reset.
private actor Gate {
    private var entered = false
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters = []
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
