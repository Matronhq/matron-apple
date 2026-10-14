import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

/// "Go to #N": what counts as a number, what each kind opens, and what is
/// said when a number leads nowhere.
final class GoToNumberTests: XCTestCase {

    // MARK: - Parsing

    func test_parse_acceptsABareOrHashedNumberWithWhitespaceAround() {
        XCTAssertEqual(GoToNumber.parse("412"), 412)
        XCTAssertEqual(GoToNumber.parse("#412"), 412)
        XCTAssertEqual(GoToNumber.parse("  #412\n"), 412)
        XCTAssertEqual(GoToNumber.parse("\t7 "), 7)
        XCTAssertEqual(GoToNumber.parse("007"), 7)
    }

    func test_parse_rejectsEverythingElse() {
        for text in ["", "  ", "#", "##412", "# 412", "41 2", "412a", "number 412", "-412", "+412", "4.12",
                     "0", "#0", "４１２", "99999999999999999999999"] {
            XCTAssertNil(GoToNumber.parse(text), "\"\(text)\" is not a number to go to")
        }
    }

    // MARK: - Resolver

    private struct Offline: Error, LocalizedError {
        var errorDescription: String? { "offline" }
    }

    /// The numbers on this "device", what the journal knows, and what a
    /// refresh lands.
    private final class Fake: @unchecked Sendable {
        var items: [Int: String] = [:]
        var pages: [MatronPageLink: MatronPageTarget] = [:]
        var titles: [Int: String] = [:]
        var journal: [Int: NumberLookup] = [:]
        var journalError: Error?
        var storeThrows = false
        var onRefresh: () -> Void = {}
        private(set) var asked: [Int] = []
        private(set) var itemRefreshes = 0
        private(set) var pageRefreshes: [MatronPageLink] = []

        var resolver: GoToNumberResolver {
            GoToNumberResolver(
                local: { num in
                    if self.storeThrows { throw Offline() }
                    if self.items[num] != nil { return GoToNumberHit(kind: .item, num: num, title: self.titles[num]) }
                    if self.pages[.mission(num)] != nil {
                        return GoToNumberHit(kind: .mission, num: num, title: self.titles[num])
                    }
                    if self.pages[.project(num)] != nil {
                        return GoToNumberHit(kind: .project, num: num, title: self.titles[num])
                    }
                    return nil
                },
                remote: { num in
                    self.asked.append(num)
                    if let error = self.journalError { throw error }
                    guard let found = self.journal[num] else { throw JournalAPIError.notFound }
                    return found
                },
                items: TrackerItemLinkResolver(
                    lookup: { num in
                        self.items[num].map {
                            TrackerItem(id: $0, num: num, kind: .task, title: "T\(num)", originConvoID: "c1")
                        }
                    },
                    refreshAll: { self.itemRefreshes += 1; self.onRefresh(); return .succeeded }),
                pages: PageLinkResolver(
                    lookup: { self.pages[$0] },
                    refresh: { self.pageRefreshes.append($0); self.onRefresh(); return nil }))
        }
    }

    /// A shareable link's number, mapped to the opener it goes through.
    func test_linkTarget_mapsEachKindToItsOpener() async {
        let fake = Fake()
        fake.items[412] = "it_1"
        fake.pages = [.mission(7): .mission(id: "ms_1"), .project(12): .project(id: "pj_1")]
        fake.journal[30] = NumberLookup(kind: .milestone, id: "ml_1", mission: .init(id: "ms_1", num: 7))
        fake.journal[31] = NumberLookup(kind: .milestone, id: "ml_2")

        let item = await fake.resolver.linkTarget(num: 412)
        let mission = await fake.resolver.linkTarget(num: 7)
        let project = await fake.resolver.linkTarget(num: 12)
        let milestone = await fake.resolver.linkTarget(num: 30)
        let orphan = await fake.resolver.linkTarget(num: 31)
        let nothing = await fake.resolver.linkTarget(num: 99)
        XCTAssertEqual(item, .item(412))
        XCTAssertEqual(mission, .page(.mission(7)))
        XCTAssertEqual(project, .page(.project(12)))
        XCTAssertEqual(milestone, .page(.mission(7)), "a milestone opens its mission's page")
        XCTAssertEqual(orphan, .web, "a milestone whose mission is unknown opens the web page")
        XCTAssertEqual(nothing, .web)
        XCTAssertEqual(fake.itemRefreshes, 0, "finding the kind syncs nothing; the opener does that")

        fake.journalError = Offline()
        let failed = await fake.resolver.linkTarget(num: 50)
        XCTAssertEqual(failed, .web)
    }

    func test_localItem_opensWithoutAskingTheJournal() async {
        let fake = Fake()
        fake.items[412] = "it_1"
        fake.titles[412] = "Fix the parser"

        guard case .open(let target, let hit) = await fake.resolver.resolve(num: 412)
        else { return XCTFail("expected .open") }
        XCTAssertEqual(target, .item(id: "it_1"))
        XCTAssertEqual(hit, GoToNumberHit(kind: .item, num: 412, title: "Fix the parser"))
        XCTAssertEqual(fake.asked, [], "a local hit works offline")
        XCTAssertEqual(fake.itemRefreshes, 0)
    }

    func test_localMissionAndProject_openTheirPages() async {
        let fake = Fake()
        fake.pages = [.mission(7): .mission(id: "ms_1"), .project(12): .project(id: "pj_1")]

        guard case .open(let mission, _) = await fake.resolver.resolve(num: 7),
              case .open(let project, _) = await fake.resolver.resolve(num: 12)
        else { return XCTFail("expected both to open") }
        XCTAssertEqual(mission, .page(.mission(id: "ms_1")))
        XCTAssertEqual(project, .page(.project(id: "pj_1")))
        XCTAssertEqual(fake.asked, [])
        XCTAssertEqual(fake.pageRefreshes, [])
    }

    /// The journal knows the number; the row arrives with the one refresh
    /// the link resolver runs.
    func test_localMiss_asksTheJournal_thenSyncsTheRowAndOpensIt() async {
        let fake = Fake()
        fake.journal[412] = NumberLookup(kind: .item, id: "it_1", num: 412, title: "Fix the parser")
        fake.onRefresh = { fake.items[412] = "it_1" }

        guard case .open(let target, let hit) = await fake.resolver.resolve(num: 412)
        else { return XCTFail("expected .open") }
        XCTAssertEqual(target, .item(id: "it_1"))
        XCTAssertEqual(hit.title, "Fix the parser")
        XCTAssertEqual(fake.asked, [412])
        XCTAssertEqual(fake.itemRefreshes, 1)
    }

    func test_remoteProject_refreshesProjectsAndOpens() async {
        let fake = Fake()
        fake.journal[12] = NumberLookup(kind: .project, id: "pj_1", num: 12, title: "Promo")
        fake.onRefresh = { fake.pages[.project(12)] = .project(id: "pj_1") }

        guard case .open(let target, _) = await fake.resolver.resolve(num: 12) else { return XCTFail("expected .open") }
        XCTAssertEqual(target, .page(.project(id: "pj_1")))
        XCTAssertEqual(fake.pageRefreshes, [.project(12)])
    }

    /// A milestone has no page of its own: it opens its mission's.
    func test_milestone_opensItsMission() async {
        let fake = Fake()
        fake.pages[.mission(7)] = .mission(id: "ms_1")
        fake.journal[30] = NumberLookup(kind: .milestone, id: "ml_1", num: 30, title: "Parser landed",
                                        mission: .init(id: "ms_1", num: 7))

        guard case .open(let target, let hit) = await fake.resolver.resolve(num: 30)
        else { return XCTFail("expected .open") }
        XCTAssertEqual(target, .page(.mission(id: "ms_1")))
        XCTAssertEqual(hit, GoToNumberHit(kind: .milestone, num: 30, title: "Parser landed", missionNum: 7))
    }

    func test_milestoneWithoutItsMission_cannotOpen() async {
        let fake = Fake()
        fake.journal[30] = NumberLookup(kind: .milestone, id: "ml_1")
        let resolution = await fake.resolver.resolve(num: 30)

        guard case .cannotOpen = resolution else { return XCTFail("expected .cannotOpen, got \(resolution)") }
        XCTAssertEqual(resolution.message(num: 30), "Couldn't open milestone #30.")
        XCTAssertEqual(fake.pageRefreshes, [], "nothing to refresh without the mission's number")
    }

    /// An older journal omits `num`: the number asked for stands in.
    func test_remoteHitWithoutANumber_usesTheOneAskedFor() async {
        let fake = Fake()
        fake.journal[7] = NumberLookup(kind: .mission, id: "ms_1")
        fake.onRefresh = { fake.pages[.mission(7)] = .mission(id: "ms_1") }

        guard case .open(let target, let hit) = await fake.resolver.resolve(num: 7) else { return XCTFail("expected .open") }
        XCTAssertEqual(target, .page(.mission(id: "ms_1")))
        XCTAssertEqual(hit.num, 7)
    }

    func test_notFound_isNoSuchNumber() async {
        let fake = Fake()
        let resolution = await fake.resolver.resolve(num: 412)

        guard case .none = resolution else { return XCTFail("expected .none, got \(resolution)") }
        XCTAssertEqual(resolution.message(num: 412), "Nothing is numbered 412.")
        XCTAssertEqual(fake.itemRefreshes, 0, "no kind, so nothing to sync")
    }

    func test_anyOtherJournalFailure_isALookupFailure() async {
        let fake = Fake()
        fake.journalError = JournalAPIError.transport("offline")
        let resolution = await fake.resolver.resolve(num: 412)

        guard case .lookupFailed = resolution else { return XCTFail("expected .lookupFailed, got \(resolution)") }
        XCTAssertEqual(resolution.message(num: 412), "Couldn't look up #412. Try again in a moment.")
    }

    func test_throwingStore_isALookupFailureWithoutAskingTheJournal() async {
        let fake = Fake()
        fake.storeThrows = true
        let resolution = await fake.resolver.resolve(num: 412)

        guard case .lookupFailed = resolution else { return XCTFail("expected .lookupFailed, got \(resolution)") }
        XCTAssertEqual(fake.asked, [])
    }

    /// The journal named an item the refresh did not bring: the link
    /// resolver's own words.
    func test_knownNumberThatDoesNotSync_saysSo() async {
        let fake = Fake()
        fake.journal[412] = NumberLookup(kind: .item, id: "it_1", num: 412)
        let resolution = await fake.resolver.resolve(num: 412)

        XCTAssertEqual(resolution.message(num: 412), "Item #\(412) isn't on this device yet.")
        XCTAssertEqual(fake.itemRefreshes, 1, "exactly one refresh")
    }

    /// `find` says what a number is without syncing anything.
    func test_find_reportsTheKindWithoutRefreshing() async {
        let fake = Fake()
        fake.journal[412] = NumberLookup(kind: .item, id: "it_1", num: 412, title: "Fix the parser")

        guard case .found(let hit) = await fake.resolver.find(num: 412) else { return XCTFail("expected .found") }
        XCTAssertEqual(hit.label, "#412 · Item — Fix the parser")
        XCTAssertEqual(fake.itemRefreshes, 0)
        XCTAssertEqual(GoToNumberHit(kind: .mission, num: 7).label, "#7 · Mission")
    }

    /// The number field's row: the kind, then the number.
    func test_heading_namesTheKindThenTheNumber() {
        XCTAssertEqual(GoToNumberHit(kind: .item, num: 412).heading, "Item #\(412)")
        XCTAssertEqual(GoToNumberHit(kind: .mission, num: 412).heading, "Mission #\(412)")
        XCTAssertEqual(GoToNumberHit(kind: .project, num: 412).heading, "Project #\(412)")
        XCTAssertEqual(GoToNumberHit(kind: .milestone, num: 412, missionNum: 7).heading, "Milestone #\(412)")
    }

    func test_onlyAMilestoneWithoutItsMission_cannotBeOpened() {
        XCTAssertNil(GoToNumberHit(kind: .item, num: 412).cannotOpenReason)
        XCTAssertNil(GoToNumberHit(kind: .milestone, num: 30, missionNum: 7).cannotOpenReason)
        XCTAssertEqual(GoToNumberHit(kind: .milestone, num: 30).cannotOpenReason,
                       "Its mission isn't known here, so it can't be opened.")
    }

    /// An already found number opens without being looked up again.
    func test_openingAFoundHit_doesNotAskTheJournalAgain() async {
        let fake = Fake()
        fake.pages[.mission(7)] = .mission(id: "ms_1")
        fake.journal[30] = NumberLookup(kind: .milestone, id: "ml_1", num: 30, mission: .init(id: "ms_1", num: 7))

        guard case .found(let hit) = await fake.resolver.find(num: 30),
              case .open(let target, _) = await fake.resolver.open(hit)
        else { return XCTFail("expected it to be found and to open") }
        XCTAssertEqual(target, .page(.mission(id: "ms_1")))
        XCTAssertEqual(fake.asked, [30])
    }
}

@MainActor
final class GoToNumberViewModelTests: XCTestCase {

    /// What each number is and where it opens, and what was asked and
    /// opened. A gated number's lookup waits until `release` is called.
    private final class Script: @unchecked Sendable {
        var findings: [Int: GoToNumberResolver.Finding] = [:]
        /// Where a found number opens; without one, its item.
        var resolutions: [Int: GoToNumberResolver.Resolution] = [:]
        var gated: Set<Int> = []
        private var waiting: [Int: [CheckedContinuation<Void, Never>]] = [:]
        private(set) var asked: [Int] = []
        private(set) var located: [Int] = []
        var opened: [GoToNumberTarget] = []

        func find(_ num: Int) async -> GoToNumberResolver.Finding {
            asked.append(num)
            if gated.contains(num) {
                await withCheckedContinuation { waiting[num, default: []].append($0) }
            }
            return findings[num] ?? .none
        }

        func locate(_ hit: GoToNumberHit) async -> GoToNumberResolver.Resolution {
            located.append(hit.num)
            return resolutions[hit.num] ?? .open(.item(id: "it_\(hit.num)"), hit)
        }

        /// Lets the lookups of `num` that are waiting answer.
        func release(_ num: Int) {
            gated.remove(num)
            waiting.removeValue(forKey: num)?.forEach { $0.resume() }
        }

        func found(_ hit: GoToNumberHit) { findings[hit.num] = .found(hit) }
    }

    private struct Offline: Error {}

    private func makeVM(_ script: Script, text: String = "") -> GoToNumberViewModel {
        GoToNumberViewModel(text: text, debounce: .zero, find: { await script.find($0) },
                            locate: { await script.locate($0) }, open: { script.opened.append($0) })
    }

    /// Runs until `condition` holds: lets a task started by the test reach
    /// the point it waits at.
    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "never settled", file: file, line: line)
    }

    func test_typingANumber_showsWhatItIs_withoutSubmitting() async {
        let script = Script()
        let hit = GoToNumberHit(kind: .item, num: 412, title: "Fix the parser")
        script.found(hit)
        let vm = makeVM(script)

        vm.text = " #412 "
        XCTAssertEqual(vm.status, .looking, "said at once, before the lookup answers")
        await vm.lookUp()
        XCTAssertEqual(vm.status, .found(hit))
        XCTAssertTrue(vm.canGo)
        XCTAssertEqual(script.opened, [], "nothing opens until Go")
        XCTAssertEqual(script.located, [], "and nothing is synced")
    }

    func test_go_opensWhatWasFound_withoutLookingItUpAgain() async {
        let script = Script()
        script.found(GoToNumberHit(kind: .mission, num: 412))
        script.resolutions[412] = .open(.page(.mission(id: "ms_1")), GoToNumberHit(kind: .mission, num: 412))
        let vm = makeVM(script, text: "412")
        await vm.lookUp()

        let opened = await vm.submit()
        XCTAssertTrue(opened)
        XCTAssertEqual(script.opened, [.page(.mission(id: "ms_1"))])
        XCTAssertEqual(script.asked, [412])
        XCTAssertFalse(vm.isOpening)
    }

    func test_numberThatNamesNothing_saysSo_andANewNumberClearsIt() async {
        let script = Script()
        let vm = makeVM(script, text: "412")

        await vm.lookUp()
        XCTAssertEqual(vm.status, .nothing("Nothing is numbered 412."))
        XCTAssertTrue(vm.canGo, "Go asks again")

        vm.text = "41"
        XCTAssertEqual(vm.status, .looking, "the line was about the number that was there")
    }

    func test_lookupFailure_isAnError_andGoTriesAgain() async {
        let script = Script()
        script.findings[412] = .failed(Offline())
        let vm = makeVM(script, text: "412")

        await vm.lookUp()
        XCTAssertEqual(vm.status, .failed("Couldn't look up #412. Try again in a moment."))

        script.found(GoToNumberHit(kind: .item, num: 412))
        let opened = await vm.submit()
        XCTAssertTrue(opened)
        XCTAssertEqual(script.asked, [412, 412])
        XCTAssertEqual(script.opened, [.item(id: "it_412")])
    }

    /// The answer for a number no longer in the field must not show.
    func test_supersededLookup_isDropped() async {
        let script = Script()
        script.gated = [41]
        script.found(GoToNumberHit(kind: .item, num: 41, title: "Stale"))
        let fresh = GoToNumberHit(kind: .project, num: 412, title: "Fresh")
        script.found(fresh)
        let vm = makeVM(script, text: "41")

        let stale = Task { await vm.lookUp() }
        await settle { script.asked == [41] }
        vm.text = "412"
        await vm.lookUp()
        XCTAssertEqual(vm.status, .found(fresh))

        script.release(41)
        await stale.value
        XCTAssertEqual(vm.status, .found(fresh), "the late answer for the older number is not shown")
    }

    /// Return pressed before the lookup answered: one press finds the
    /// number and opens it.
    func test_goBeforeTheAnswer_looksUpAtOnce_andOpens() async {
        let script = Script()
        script.found(GoToNumberHit(kind: .item, num: 412))
        let vm = GoToNumberViewModel(text: "412", debounce: .seconds(60), find: { await script.find($0) },
                                     locate: { await script.locate($0) }, open: { script.opened.append($0) })

        let waiting = Task { await vm.lookUp() }
        await Task.yield()
        XCTAssertEqual(script.asked, [], "still waiting for the typing to settle")

        let opened = await vm.submit()
        XCTAssertTrue(opened)
        XCTAssertEqual(script.asked, [412])
        XCTAssertEqual(script.opened, [.item(id: "it_412")])

        waiting.cancel()
        await waiting.value
        XCTAssertEqual(script.asked, [412], "the debounced lookup it overtook asks nothing")
    }

    func test_goOnANumberThatNamesNothing_opensNothing() async {
        let script = Script()
        let vm = makeVM(script, text: "412")

        let opened = await vm.submit()
        XCTAssertFalse(opened)
        XCTAssertEqual(vm.status, .nothing("Nothing is numbered 412."))
        XCTAssertEqual(script.opened, [])
        XCTAssertFalse(vm.isOpening)
    }

    func test_foundNumberThatWillNotOpen_saysWhy() async {
        let script = Script()
        script.found(GoToNumberHit(kind: .item, num: 412))
        script.resolutions[412] = .cannotOpen("It isn't on this device yet.")
        let vm = makeVM(script, text: "412")
        await vm.lookUp()

        let opened = await vm.submit()
        XCTAssertFalse(opened)
        XCTAssertEqual(vm.status, .failed("It isn't on this device yet."))
        XCTAssertEqual(script.opened, [])
    }

    /// The row says what the milestone is; Go has nowhere to take it.
    func test_milestoneWithoutItsMission_isShownButCannotBeOpened() async {
        let script = Script()
        let hit = GoToNumberHit(kind: .milestone, num: 30, title: "Parser landed")
        script.found(hit)
        let vm = makeVM(script, text: "30")

        await vm.lookUp()
        XCTAssertEqual(vm.status, .found(hit))
        XCTAssertFalse(vm.canGo)

        vm.text = "#30"
        let opened = await vm.submit()
        XCTAssertFalse(opened)
        XCTAssertEqual(vm.status, .found(hit))
        XCTAssertEqual(script.located, [])
        XCTAssertFalse(vm.isOpening)
    }

    func test_emptyOrNonNumericText_saysAndAsksNothing() async {
        let script = Script()
        let vm = makeVM(script)

        for text in ["", "  ", "four", "#", "41a"] {
            vm.text = text
            await vm.lookUp()
            XCTAssertEqual(vm.status, .idle, "\"\(text)\"")
            XCTAssertFalse(vm.canGo, "\"\(text)\"")
            let opened = await vm.submit()
            XCTAssertFalse(opened)
        }
        XCTAssertEqual(script.asked, [])
    }

    /// A trailing space or a `#` is the same number: its answer stays and
    /// is not asked for again.
    func test_sameNumberTypedAnotherWay_keepsItsAnswer() async {
        let script = Script()
        let hit = GoToNumberHit(kind: .item, num: 412)
        script.found(hit)
        let vm = makeVM(script, text: "412")
        await vm.lookUp()

        vm.text = "#412 "
        XCTAssertEqual(vm.status, .found(hit))
        await vm.lookUp()
        XCTAssertEqual(script.asked, [412])
    }

    func test_cancelWhileOpening_opensNothing() async {
        let script = Script()
        script.gated = [412]
        script.found(GoToNumberHit(kind: .item, num: 412))
        let vm = makeVM(script, text: "412")

        let run = Task { await vm.submit() }
        await settle { script.asked == [412] }
        XCTAssertTrue(vm.isOpening)
        XCTAssertFalse(vm.canGo)
        vm.cancel()
        script.release(412)
        let opened = await run.value
        XCTAssertFalse(opened)
        XCTAssertEqual(script.opened, [], "a lookup that answers after Cancel moves nothing")
        XCTAssertFalse(vm.isOpening)
    }

    /// The answer for the number that was in the field must not open, or
    /// be reported, once the number has been edited.
    func test_editingWhileOpening_dropsTheStaleAnswer() async {
        let script = Script()
        script.gated = [412]
        script.found(GoToNumberHit(kind: .item, num: 412))
        let vm = makeVM(script, text: "412")

        let run = Task { await vm.submit() }
        await settle { script.asked == [412] }
        vm.text = "4123"
        script.release(412)
        let opened = await run.value
        XCTAssertFalse(opened)
        XCTAssertEqual(script.opened, [])
        XCTAssertEqual(vm.status, .looking, "about the new number now")
        XCTAssertFalse(vm.isOpening)
    }
}
