import XCTest
@testable import MatronDesignSystem

/// The matching rule is ported from the web client and the bridge refuses
/// agents' links with the same rule, so these cases mirror the web's.
final class TrackerLinkTitleRuleTests: XCTestCase {
    func test_titleMatches_acceptsTheTitle_aPrefix_anAbbreviation_orACloseParaphrase() {
        XCTAssertTrue(TrackerLinkTitleRule.titleMatches("Merge: printer XML…", "Merge: printer XML export for the run"))
        XCTAssertTrue(TrackerLinkTitleRule.titleMatches("late-orders item", "Late orders shipped after the cut-off: options"))
        XCTAssertTrue(TrackerLinkTitleRule.titleMatches("CAFÉ menu", "Cafe menu update"))
        XCTAssertTrue(TrackerLinkTitleRule.titleMatches("Ship the release...", "Ship the release notes"))
        XCTAssertTrue(TrackerLinkTitleRule.titleMatches("Ship the rel", "Ship the release notes"))
    }

    func test_titleMatches_refusesATitleAboutSomethingElse_andAnEmptyOne() {
        XCTAssertFalse(TrackerLinkTitleRule.titleMatches("the new merge question", "Late orders shipped after the cut-off"))
        XCTAssertFalse(TrackerLinkTitleRule.titleMatches("here", "Merge: printer XML export"))
        XCTAssertFalse(TrackerLinkTitleRule.titleMatches("", "Merge"))
        XCTAssertFalse(TrackerLinkTitleRule.titleMatches("Merge", ""))
    }

    func test_writtenLink_readsTheNumberAndTitle() {
        XCTAssertEqual(TrackerLinkTitleRule.writtenLink("#12 Ship the release…"), .init(num: 12, title: "Ship the release…"))
        XCTAssertEqual(TrackerLinkTitleRule.writtenLink("item #12: Title"), .init(num: 12, title: "Title"))
        XCTAssertEqual(TrackerLinkTitleRule.writtenLink("Mission #7 — \"Quoted\""), .init(num: 7, title: "Quoted"))
        XCTAssertEqual(TrackerLinkTitleRule.writtenLink("**#5** (Launch)"), .init(num: 5, title: "Launch"))
        XCTAssertEqual(TrackerLinkTitleRule.writtenLink("#12"), .init(num: 12, title: ""))
        XCTAssertEqual(TrackerLinkTitleRule.writtenLink("Title only"), .init(num: nil, title: "Title only"))
        XCTAssertEqual(TrackerLinkTitleRule.writtenLink("#12abc"), .init(num: nil, title: "#12abc"))
        XCTAssertEqual(TrackerLinkTitleRule.writtenLink("#0 zero"), .init(num: nil, title: "#0 zero"))
    }
}

final class TrackerLinkChipTests: XCTestCase {
    private func found(_ kind: String, _ title: String?) -> TrackerLinkLookup { .found(kind: kind, title: title) }

    func test_bareLink_showsKindAndTitle() {
        let chip = TrackerLinkChip(lookup: found("item", "Ship the release notes"), num: 12, linkText: "#12")
        XCTAssertEqual(chip?.text, "item · Ship the release notes")
        XCTAssertEqual(chip?.isMismatch, false)
    }

    func test_linkCarryingTheRightTitle_showsOnlyTheKind() {
        let chip = TrackerLinkChip(lookup: found("mission", "Ship the release notes"), num: 12, linkText: "#12 Ship the release…")
        XCTAssertEqual(chip?.text, "mission")
        XCTAssertEqual(chip?.isMismatch, false)
        XCTAssertEqual(chip?.hint, "Ship the release notes")
    }

    func test_writtenTitleThatIsNotTheTargets_isFlagged() {
        let chip = TrackerLinkChip(lookup: found("item", "Late orders after the cut-off"), num: 12,
                                   linkText: "#12 Merge: printer export")
        XCTAssertEqual(chip?.text, "item · Late orders after the cut-off")
        XCTAssertEqual(chip?.isMismatch, true)
        XCTAssertEqual(chip?.hint, "#12 is not \"Merge: printer export\": it is the item \"Late orders after the cut-off\".")
    }

    func test_textNumberDifferentFromTheLinks_isFlagged() {
        let chip = TrackerLinkChip(lookup: found("item", "Ship the release notes"), num: 12, linkText: "#13 Ship the release notes")
        XCTAssertEqual(chip?.text, "item · Ship the release notes")
        XCTAssertEqual(chip?.isMismatch, true)
        XCTAssertEqual(chip?.hint, "This link says #13 but goes to #12, the item \"Ship the release notes\".")
    }

    func test_numberThatDoesNotExist_isFlaggedNotFound() {
        let chip = TrackerLinkChip(lookup: .notFound, num: 99, linkText: "#99")
        XCTAssertEqual(chip?.text, "not found")
        XCTAssertEqual(chip?.isMismatch, true)
    }

    func test_oneWordLinkText_isNotAClaimAboutTheTarget() {
        let chip = TrackerLinkChip(lookup: found("item", "Ship the release notes"), num: 12, linkText: "here")
        XCTAssertEqual(chip?.text, "item · Ship the release notes")
        XCTAssertEqual(chip?.isMismatch, false)
    }

    func test_untitledTarget_showsOnlyTheKind() {
        let chip = TrackerLinkChip(lookup: found("milestone", nil), num: 3, linkText: "#3")
        XCTAssertEqual(chip?.text, "milestone")
        XCTAssertEqual(chip?.isMismatch, false)
    }

    func test_untitledTarget_withAWrongNumberInTheText_isFlagged() {
        let chip = TrackerLinkChip(lookup: found("item", nil), num: 3, linkText: "#4")
        XCTAssertEqual(chip?.text, "item")
        XCTAssertEqual(chip?.isMismatch, true)
    }

    func test_failedLookup_showsNothing() {
        XCTAssertNil(TrackerLinkChip(lookup: .failed, num: 12, linkText: "#12"))
    }
}

final class TrackerLinkMarkdownAnnotationTests: XCTestCase {
    private let origin = TrackerLinkOrigin(serverURL: URL(string: "https://journal.example.com")!, user: "alice")!

    private func annotate(_ source: String, _ answers: [Int: TrackerLinkLookup]) -> String {
        let lookups = TrackerLinkLookups(origin: origin, answers: Dictionary(uniqueKeysWithValues: answers.map {
            (TrackerLinkTarget(user: "alice", num: $0.key), $0.value)
        }))
        return MarkdownSource.annotatingTrackerLinks(source) { lookups.chip(for: $0, linkText: $1) }
    }

    func test_writesEachChipAfterItsLink_andFlagsAWrongOne() {
        XCTAssertEqual(
            annotate("See [#12](matron://item/12) and [#13 Merge: printer export](matron://item/13).",
                     [12: .found(kind: "item", title: "Ship *it*"), 13: .found(kind: "item", title: "Late orders")]),
            "See [#12](matron://item/12) *item · Ship \\*it\\** and [#13 Merge: printer export](matron://item/13) **⚠︎ item · Late orders**.")
    }

    func test_leavesCodeAndUnansweredLinksAlone() {
        let source = "`[#12](matron://item/12)` and [#14](matron://item/14)\n\n```\n[#12](matron://item/12)\n```"
        XCTAssertEqual(annotate(source, [12: .found(kind: "item", title: "Ship it")]), source)
    }

    func test_bareItemURL_isAnnotatedOncePrepared() {
        let prepared = MarkdownSource.prepared("See matron://item/12 now")
        XCTAssertEqual(annotate(prepared, [12: .found(kind: "item", title: "Ship it")]),
                       "See <matron://item/12> *item · Ship it* now")
        XCTAssertEqual(MarkdownSource.prepared("See <matron://item/12> *item · Ship it* now"),
                       "See <matron://item/12> *item · Ship it* now", "preparing again changes nothing")
    }

    func test_bareLinkShowsTheTitle_unflagged() {
        XCTAssertEqual(annotate("<matron://item/12>", [12: .found(kind: "item", title: "Ship it")]),
                       "<matron://item/12> *item · Ship it*")
    }
}

final class TrackerLinkRefsTests: XCTestCase {
    private let origin = TrackerLinkOrigin(serverURL: URL(string: "https://journal.example.com")!, user: "alice")!

    func test_readsOwnAndOtherPeoplesLinks_andTheOldMatronLinks() {
        let refs = TrackerLinkRefs.targets(in: """
        See [#12](https://journal.example.com/u/alice/12), [#3](https://journal.example.com/u/bob/3),
        [#5](matron://project/5), [#6](matron://item/6), [#7](matron://mission/7) and matron://item/8.
        Not these: `[#9](matron://item/9)`, [#10](https://elsewhere.example.com/u/alice/10), [web](https://example.com/a).
        """, origin: origin)
        XCTAssertEqual(refs, [
            TrackerLinkTarget(user: "alice", num: 12), TrackerLinkTarget(user: "bob", num: 3),
            TrackerLinkTarget(user: "alice", num: 5), TrackerLinkTarget(user: "alice", num: 6),
            TrackerLinkTarget(user: "alice", num: 7), TrackerLinkTarget(user: "alice", num: 8),
        ])
    }

    func test_bodyWithNoTrackerLink_hasNoTargets() {
        XCTAssertEqual(TrackerLinkRefs.targets(in: "Plain [web](https://example.com/a) text", origin: origin), [])
    }
}

@MainActor
final class TrackerLinkTitlesTests: XCTestCase {
    private let origin = TrackerLinkOrigin(serverURL: URL(string: "https://journal.example.com")!, user: "alice")!

    /// Counts lookups, answers from `answers`, and lets a test hold them.
    private actor Journal {
        var calls: [TrackerLinkTarget] = []
        var answers: [Int: TrackerLinkLookup]
        init(_ answers: [Int: TrackerLinkLookup]) { self.answers = answers }
        func lookup(_ user: String, _ num: Int) -> TrackerLinkLookup {
            calls.append(TrackerLinkTarget(user: user, num: num))
            return answers[num] ?? .notFound
        }
        func set(_ num: Int, _ answer: TrackerLinkLookup) { answers[num] = answer }
    }

    private var now = Date(timeIntervalSince1970: 1_000_000)

    private func host(_ journal: Journal) -> TrackerLinkTitles {
        TrackerLinkTitles(origin: origin, lookup: { await journal.lookup($0, $1) }, now: { [unowned self] in now })
    }

    private func settle(_ titles: TrackerLinkTitles) async {
        for _ in 0..<50 where titles.isLoading { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    func test_looksEachLinkUpOnce_andAnswersFromTheCache() async {
        let journal = Journal([12: .found(kind: "item", title: "Ship it")])
        let titles = host(journal)
        let body = "[#12](matron://item/12) and again [#12](https://journal.example.com/u/alice/12)"

        XCTAssertTrue(titles.lookups(for: body).isEmpty, "nothing is known before the lookup lands")
        _ = titles.lookups(for: body)
        await settle(titles)

        let lookups = titles.lookups(for: body)
        XCTAssertEqual(lookups.answers[TrackerLinkTarget(user: "alice", num: 12)], .found(kind: "item", title: "Ship it"))
        let calls = await journal.calls
        XCTAssertEqual(calls, [TrackerLinkTarget(user: "alice", num: 12)])
    }

    func test_asksAgainAfterFiveMinutes() async {
        let journal = Journal([12: .found(kind: "item", title: "Old")])
        let titles = host(journal)
        _ = titles.lookups(for: "[#12](matron://item/12)")
        await settle(titles)

        await journal.set(12, .found(kind: "item", title: "New"))
        now += 4 * 60
        _ = titles.lookups(for: "[#12](matron://item/12)")
        await settle(titles)
        var calls = await journal.calls
        XCTAssertEqual(calls.count, 1)

        now += 2 * 60
        _ = titles.lookups(for: "[#12](matron://item/12)")
        await settle(titles)
        calls = await journal.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(titles.lookups(for: "[#12](matron://item/12)").answers.values.first, .found(kind: "item", title: "New"))
    }

    func test_failureIsNotKept_andIsAskedAgain() async {
        let journal = Journal([12: .failed])
        let titles = host(journal)
        _ = titles.lookups(for: "[#12](matron://item/12)")
        await settle(titles)
        XCTAssertTrue(titles.lookups(for: "[#12](matron://item/12)").isEmpty)

        await journal.set(12, .found(kind: "item", title: "Back"))
        now += TrackerLinkTitles.failureRetry + 1
        _ = titles.lookups(for: "[#12](matron://item/12)")
        await settle(titles)
        XCTAssertEqual(titles.lookups(for: "[#12](matron://item/12)").answers.values.first,
                       .found(kind: "item", title: "Back"))
    }

    func test_notFoundIsKept() async {
        let journal = Journal([:])
        let titles = host(journal)
        _ = titles.lookups(for: "[#99](matron://item/99)")
        await settle(titles)
        XCTAssertEqual(titles.lookups(for: "[#99](matron://item/99)").answers.values.first, .notFound)
    }
}

#if os(macOS)
import AppKit

final class TrackerLinkRenderingTests: XCTestCase {
    private let origin = TrackerLinkOrigin(serverURL: URL(string: "https://journal.example.com")!, user: "alice")!

    private func lookups(_ answers: [Int: TrackerLinkLookup], user: String = "alice") -> TrackerLinkLookups {
        TrackerLinkLookups(origin: origin, answers: Dictionary(uniqueKeysWithValues: answers.map {
            (TrackerLinkTarget(user: user, num: $0.key), $0.value)
        }))
    }

    private func chipRanges(_ string: NSAttributedString) -> [(String, NSRange)] {
        var out: [(String, NSRange)] = []
        string.enumerateAttribute(MarkdownAttributed.trackerChipKey, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard value != nil else { return }
            let text = (string.string as NSString).substring(with: range)
            // The separating space carries the mark too; the chip is the rest.
            guard text != " " else { return }
            out.append((text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{202F}")), range))
        }
        return out
    }

    func test_chipFollowsTheLink() {
        let rendered = MarkdownAttributed.rendered(
            for: "See [#12](https://journal.example.com/u/alice/12).", style: .chat, cache: false,
            trackerLinks: lookups([12: .found(kind: "item", title: "Ship the release notes")]))
        XCTAssertEqual(rendered.attributed.string, "See #12 \u{202F}item · Ship the release notes\u{202F}.")
        let chips = chipRanges(rendered.attributed)
        XCTAssertEqual(chips.map(\.0), ["item · Ship the release notes"])
        let attrs = rendered.attributed.attributes(at: chips[0].1.location, effectiveRange: nil)
        XCTAssertNil(attrs[.link], "the chip is not part of the link")
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, MarkdownPalette.secondaryLabel)
        XCTAssertEqual(attrs[.toolTip] as? String, "Ship the release notes")
    }

    func test_mismatchedChip_isInTheErrorColour() {
        let rendered = MarkdownAttributed.rendered(
            for: "[#12 Merge: printer export](matron://item/12)", style: .chat, cache: false,
            trackerLinks: lookups([12: .found(kind: "item", title: "Late orders after the cut-off")]))
        let chips = chipRanges(rendered.attributed)
        XCTAssertEqual(chips.map(\.0), ["item · Late orders after the cut-off"])
        let attrs = rendered.attributed.attributes(at: chips[0].1.location, effectiveRange: nil)
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, MarkdownPalette.error)
    }

    func test_otherPeoplesLinks_areReadAgainstTheirOwner() {
        let rendered = MarkdownAttributed.rendered(
            for: "[#3](https://journal.example.com/u/bob/3)", style: .chat, cache: false,
            trackerLinks: lookups([3: .found(kind: "milestone", title: "First draft")], user: "bob"))
        XCTAssertEqual(chipRanges(rendered.attributed).map(\.0), ["milestone · First draft"])
    }

    func test_noAnswer_rendersThePlainLink() {
        let plain = MarkdownAttributed.rendered(for: "[#12](matron://item/12)", style: .chat, cache: false)
        let rendered = MarkdownAttributed.rendered(
            for: "[#12](matron://item/12)", style: .chat, cache: false,
            trackerLinks: lookups([12: .failed]))
        XCTAssertEqual(rendered.attributed, plain.attributed)
    }

    func test_copyLeavesTheChipOut() {
        let rendered = MarkdownAttributed.rendered(
            for: "See [#12](matron://item/12) now", style: .chat, cache: false,
            trackerLinks: lookups([12: .found(kind: "item", title: "Ship it")]))
        let copied = MarkdownReconstruction.markdown(
            from: rendered.attributed, in: NSRange(location: 0, length: rendered.attributed.length))
        XCTAssertEqual(copied, "See [#12](matron://item/12) now")
    }

    func test_chipMakesTheMeasuredSizeGrow() {
        let source = "See [#12](matron://item/12)"
        let plain = MarkdownAttributed.rendered(for: source, style: .chat, cache: false).size(width: 600)
        let decorated = MarkdownAttributed.rendered(
            for: source, style: .chat, cache: false,
            trackerLinks: lookups([12: .found(kind: "item", title: "Ship the release notes")])).size(width: 600)
        XCTAssertGreaterThan(decorated.width, plain.width)
    }
}
#endif
