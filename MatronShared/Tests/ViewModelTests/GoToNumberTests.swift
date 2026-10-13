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
        XCTAssertEqual(resolution.message(num: 412), "No #412")
        XCTAssertEqual(fake.itemRefreshes, 0, "no kind, so nothing to sync")
    }

    func test_anyOtherJournalFailure_isALookupFailure() async {
        let fake = Fake()
        fake.journalError = JournalAPIError.transport("offline")
        let resolution = await fake.resolver.resolve(num: 412)

        guard case .lookupFailed = resolution else { return XCTFail("expected .lookupFailed, got \(resolution)") }
        XCTAssertEqual(resolution.message(num: 412), "Couldn't look up #412 — Couldn't reach the server — offline")
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
}

@MainActor
final class GoToNumberViewModelTests: XCTestCase {

    /// Resolutions by number, each optionally slow, and what was opened.
    private final class Script: @unchecked Sendable {
        var resolutions: [Int: GoToNumberResolver.Resolution] = [:]
        var delay: Duration = .zero
        private(set) var asked: [Int] = []
        var opened: [GoToNumberTarget] = []

        func resolve(_ num: Int) async -> GoToNumberResolver.Resolution {
            asked.append(num)
            if delay > .zero { try? await Task.sleep(for: delay) }
            return resolutions[num] ?? .none
        }
    }

    private func makeVM(_ script: Script, text: String = "") -> GoToNumberViewModel {
        GoToNumberViewModel(text: text, resolve: { await script.resolve($0) }, open: { script.opened.append($0) })
    }

    func test_submit_opensTheTarget() async {
        let script = Script()
        script.resolutions[412] = .open(.item(id: "it_1"), GoToNumberHit(kind: .item, num: 412))
        let vm = makeVM(script)
        vm.text = " #412 "

        let opened = await vm.submit()
        XCTAssertTrue(opened)
        XCTAssertEqual(script.opened, [.item(id: "it_1")])
        XCTAssertNil(vm.message)
        XCTAssertFalse(vm.isBusy)
    }

    func test_noSuchNumber_saysSoUnderTheField_andEditingClearsIt() async {
        let script = Script()
        let vm = makeVM(script, text: "412")

        let opened = await vm.submit()
        XCTAssertFalse(opened)
        XCTAssertEqual(vm.message, "No #412")
        XCTAssertEqual(script.opened, [])

        vm.text = "41"
        XCTAssertNil(vm.message, "the line was about the number that was there")
    }

    func test_lookupFailureAndCannotOpen_showTheirMessages() async {
        let script = Script()
        script.resolutions[412] = .lookupFailed(JournalAPIError.transport(""))
        script.resolutions[30] = .cannotOpen("Couldn't open milestone #30.")
        let vm = makeVM(script, text: "412")

        await vm.submit()
        XCTAssertEqual(vm.message, "Couldn't look up #412 — Couldn't reach the server.")
        vm.text = "30"
        await vm.submit()
        XCTAssertEqual(vm.message, "Couldn't open milestone #30.")
    }

    func test_invalidText_asksNothing() async {
        let script = Script()
        let vm = makeVM(script, text: "four")

        let opened = await vm.submit()
        XCTAssertFalse(opened)
        XCTAssertEqual(vm.message, "Type a number, such as 412.")
        XCTAssertEqual(script.asked, [])
        XCTAssertTrue(vm.canGo)
        vm.text = "  "
        XCTAssertFalse(vm.canGo, "nothing typed, nothing to go to")
    }

    func test_busyWhileLookingUp_andCancelOpensNothing() async {
        let script = Script()
        script.delay = .milliseconds(100)
        script.resolutions[412] = .open(.item(id: "it_1"), GoToNumberHit(kind: .item, num: 412))
        let vm = makeVM(script, text: "412")

        let run = Task { await vm.submit() }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(vm.isBusy)
        XCTAssertFalse(vm.canGo)
        vm.cancel()
        let opened = await run.value
        XCTAssertFalse(opened)
        XCTAssertEqual(script.opened, [], "a lookup that answers after Cancel moves nothing")
        XCTAssertFalse(vm.isBusy)
    }

    /// The answer for the number that was in the field must not open, or
    /// be reported, once the number has been edited.
    func test_editingWhileLookingUp_dropsTheStaleAnswer() async {
        let script = Script()
        script.delay = .milliseconds(100)
        script.resolutions[412] = .open(.item(id: "it_1"), GoToNumberHit(kind: .item, num: 412))
        let vm = makeVM(script, text: "412")

        let run = Task { await vm.submit() }
        try? await Task.sleep(for: .milliseconds(20))
        vm.text = "4123"
        let opened = await run.value
        XCTAssertFalse(opened)
        XCTAssertEqual(script.opened, [])
        XCTAssertNil(vm.message)
        XCTAssertFalse(vm.isBusy)
    }
}
