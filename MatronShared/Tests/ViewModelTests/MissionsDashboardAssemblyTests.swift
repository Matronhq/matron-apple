import XCTest
import MatronModels
import MatronChat
@testable import MatronViewModels

final class MissionsDashboardAssemblyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    /// `summary(...)` registers its `state` here rather than on `ChatSummary`
    /// (which carries no session state of its own — see `sessionStates`
    /// below); a test assigns `inputs.sessionStates = sessionStateOverrides`
    /// after building `inputs.summaries`. A fresh instance per test method
    /// (standard XCTest behaviour) keeps this safe to accumulate into.
    private var sessionStateOverrides: [String: String] = [:]

    private func mission(_ id: String, num: Int, state: MissionState = .open, origin: String = "c-origin",
                         lastMilestoneAt: Date? = nil, needsYou: Int = 0, conversations: Int = 1,
                         closedAt: Date? = nil, statusUpdatedAt: Date? = nil) -> Mission {
        Mission(id: id, num: num, state: state, title: "M\(num)", originConvoID: origin,
                createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                lastMilestoneAt: lastMilestoneAt, closedAt: closedAt, needsYou: needsYou,
                conversationCount: conversations,
                lastMilestone: lastMilestoneAt.map { MissionLastMilestone(num: num + 100, title: "step", kind: .progress, createdAt: $0) },
                status: statusUpdatedAt == nil ? nil : "Status", statusBy: statusUpdatedAt == nil ? nil : .agent,
                statusUpdatedAt: statusUpdatedAt)
    }

    /// Builds a `ChatSummary` and records its intended session state in
    /// `sessionStateOverrides`. `ChatSummary` itself has no `sessionState`
    /// field — it was removed for chat-list performance (Task 4 added
    /// `JournalStore.sessionStates()` instead) — so a test that cares about
    /// state must copy `sessionStateOverrides` into `inputs.sessionStates`.
    private func summary(_ id: String, state: String = "waiting", last: Date? = nil, parent: String? = nil,
                         snippet: String = "", title: String? = nil, needs: Int = 0) -> ChatSummary {
        sessionStateOverrides[id] = state
        return ChatSummary(id: id, title: title ?? "Chat \(id)",
                    bot: BotIdentity(matrixID: "agent:claude", displayName: "Claude", avatarURL: nil),
                    lastActivity: last, unreadCount: 0, snippet: snippet, parentConvoID: parent,
                    needsUserCount: needs)
    }

    private func convo(_ id: String, state: String = "waiting", title: String = "", box: String? = nil) -> MissionConversation {
        MissionConversation(id: id, title: title, box: box, state: state)
    }

    // MARK: Grouping

    func testOpenClosedAndUnassignedLandInTheirPlaces() {
        var inputs = MissionsDashboardInputs()
        inputs.coordinatorConvoID = "c-coord"
        inputs.missions = [
            mission("ms_open", num: 61),
            mission("ms_unassigned", num: 62, origin: "c-coord", conversations: 0),
            mission("ms_closed_old", num: 50, state: .closed, closedAt: ago(500)),
            mission("ms_closed_new", num: 51, state: .closed, closedAt: ago(100)),
        ]
        inputs.conversationsByMission = ["ms_open": [convo("c1")]]
        let snapshot = MissionsDashboardAssembly.assemble(inputs, now: now)
        XCTAssertEqual(Set(snapshot.cards.map(\.id)), ["ms_open", "ms_unassigned"])
        XCTAssertEqual(snapshot.closed.map(\.id), ["ms_closed_new", "ms_closed_old"], "newest close first")
        let unassigned = snapshot.cards.first { $0.id == "ms_unassigned" }
        XCTAssertEqual(unassigned?.attribution, "from Coordinator")
        XCTAssertEqual(unassigned?.sessions, [])
        XCTAssertNil(snapshot.cards.first { $0.id == "ms_open" }?.attribution, "only unassigned cards are attributed")
    }

    func testAttributionNamesTheCoordinatorThenTheOriginThenNothing() {
        let fromCoordinator = mission("ms_1", num: 1, origin: "c-coord", conversations: 0)
        let fromElsewhere = mission("ms_2", num: 2, origin: "c-other", conversations: 0)
        let unknown = mission("ms_3", num: 3, origin: "c-gone", conversations: 0)
        let titles = ["c-other": "Parser work"]
        XCTAssertEqual(MissionsDashboardAssembly.attribution(for: fromCoordinator, coordinatorConvoID: "c-coord", titles: titles),
                       "from Coordinator")
        XCTAssertEqual(MissionsDashboardAssembly.attribution(for: fromElsewhere, coordinatorConvoID: "c-coord", titles: titles),
                       "from Parser work")
        XCTAssertNil(MissionsDashboardAssembly.attribution(for: unknown, coordinatorConvoID: "c-coord", titles: titles))
        XCTAssertNil(MissionsDashboardAssembly.attribution(for: fromCoordinator, coordinatorConvoID: "", titles: [:]))
    }

    // MARK: Ordering (spec §3.6)

    func testCardsGroupNeedsYouThenRunningThenRestAndSortByActivityWithin() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [
            mission("ms_quiet_new", num: 1, lastMilestoneAt: ago(10)),
            mission("ms_running", num: 2, lastMilestoneAt: ago(9_000)),
            mission("ms_needs_old", num: 3, lastMilestoneAt: ago(8_000), needsYou: 1),
            mission("ms_needs_new", num: 4, lastMilestoneAt: ago(50), needsYou: 2),
            mission("ms_quiet_old", num: 5, lastMilestoneAt: ago(7_000)),
        ]
        inputs.conversationsByMission = ["ms_running": [convo("c-run", state: "running")]]
        let ids = MissionsDashboardAssembly.assemble(inputs, now: now).cards.map(\.id)
        XCTAssertEqual(ids, ["ms_needs_new", "ms_needs_old", "ms_running", "ms_quiet_new", "ms_quiet_old"])
    }

    func testActivityIsTheMaxOfMilestoneStatusAndSessions() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [
            mission("ms_status", num: 1, lastMilestoneAt: ago(9_000), statusUpdatedAt: ago(20)),
            mission("ms_session", num: 2, lastMilestoneAt: ago(9_000)),
            mission("ms_milestone", num: 3, lastMilestoneAt: ago(30)),
        ]
        inputs.conversationsByMission = ["ms_session": [convo("c1")]]
        inputs.summaries = [summary("c1", last: ago(10))]
        inputs.sessionStates = sessionStateOverrides
        let cards = MissionsDashboardAssembly.assemble(inputs, now: now).cards
        XCTAssertEqual(cards.map(\.id), ["ms_session", "ms_status", "ms_milestone"])
        XCTAssertEqual(cards.first?.lastActivity, ago(10))
    }

    func testSessionsSortRunningWaitingDoneThenActivityAndCapAtFour() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1)]
        inputs.conversationsByMission = ["ms_1": [
            convo("done"), convo("wait_old"), convo("wait_new"), convo("run"), convo("wait_mid"), convo("never"),
        ]]
        inputs.summaries = [
            summary("done", state: "done", last: ago(1)),
            summary("wait_old", last: ago(300)),
            summary("wait_new", last: ago(10)),
            summary("run", state: "running", last: ago(5_000)),
            summary("wait_mid", last: ago(100)),
            summary("never", last: nil),
        ]
        inputs.sessionStates = sessionStateOverrides
        let card = MissionsDashboardAssembly.assemble(inputs, now: now).cards[0]
        XCTAssertEqual(card.sessions.map(\.id), ["run", "wait_new", "wait_mid", "wait_old"])
        XCTAssertEqual(card.moreSessions, 2)
        XCTAssertTrue(card.anyRunning)
    }

    /// The map that carries a session's live state wins over the mission
    /// detail row's own `state`, which the journal returns as of the last
    /// `GET /missions/:id` fetch and can be stale by the time this device's
    /// own sync has seen fresher activity.
    func testSessionStatesMapWinsOverAStaleMissionConversationState() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1)]
        inputs.conversationsByMission = ["ms_1": [convo("c1", state: "waiting")]]
        inputs.sessionStates = ["c1": "running"]
        let session = MissionsDashboardAssembly.assemble(inputs, now: now).cards[0].sessions[0]
        XCTAssertEqual(session.state, .running, "the live sessionStates map beats the stale detail-row state")
    }

    // MARK: Loose sessions (spec §3.3)

    func testLooseSessionMembership() {
        var inputs = MissionsDashboardInputs()
        inputs.coordinatorConvoID = "c-coord"
        inputs.missions = [mission("ms_1", num: 1, origin: "c-origin"),
                           mission("ms_closed", num: 2, state: .closed, origin: "c-closed-origin", closedAt: ago(1))]
        inputs.conversationsByMission = ["ms_1": [convo("c-member")], "ms_closed": [convo("c-on-closed", state: "running")]]
        inputs.summaries = [
            summary("c-running-old", state: "running", last: ago(10 * 86_400)),
            summary("c-waiting-recent", last: ago(3_600)),
            summary("c-waiting-stale", last: ago(25 * 3_600)),
            summary("c-waiting-never", last: nil),
            summary("c-done", state: "done", last: ago(60)),
            summary("c-child", state: "running", last: ago(60), parent: "c-running-old"),
            summary("c-coord", state: "running", last: ago(60)),
            summary("c-member", state: "running", last: ago(60)),
            summary("c-origin", state: "running", last: ago(60)),
            summary("c-on-closed", state: "running", last: ago(60)),
        ]
        inputs.sessionStates = sessionStateOverrides
        let ids = Set(MissionsDashboardAssembly.assemble(inputs, now: now).looseSessions.map(\.id))
        XCTAssertEqual(ids, ["c-running-old", "c-waiting-recent", "c-on-closed"],
                       "running always, waiting only inside 24 h; never a child, the Coordinator or an open mission's session")
    }

    func testLooseSessionsPutRunningFirstThenActivity() {
        var inputs = MissionsDashboardInputs()
        inputs.summaries = [
            summary("wait_new", last: ago(10)),
            summary("run_old", state: "running", last: ago(5_000)),
            summary("wait_old", last: ago(600)),
            summary("run_new", state: "running", last: ago(100)),
        ]
        inputs.sessionStates = sessionStateOverrides
        XCTAssertEqual(MissionsDashboardAssembly.assemble(inputs, now: now).looseSessions.map(\.id),
                       ["run_new", "run_old", "wait_new", "wait_old"])
    }

    // MARK: Summary text (spec §3.5)

    func testSummaryFallsBackFromRosterToTOCToSnippet() {
        let roster = ["c1": "Roster line", "c2": "   "]
        let tocs = ["c1": "TOC 1", "c2": "TOC 2"]
        XCTAssertEqual(MissionsDashboardAssembly.summaryText(convoID: "c1", roster: roster, tocs: tocs, snippet: "s"), "Roster line")
        XCTAssertEqual(MissionsDashboardAssembly.summaryText(convoID: "c2", roster: roster, tocs: tocs, snippet: "s"), "TOC 2",
                       "a blank roster summary falls through")
        XCTAssertEqual(MissionsDashboardAssembly.summaryText(convoID: "c3", roster: roster, tocs: tocs, snippet: "last line"), "last line")
        XCTAssertNil(MissionsDashboardAssembly.summaryText(convoID: "c3", roster: roster, tocs: tocs, snippet: ""))
        XCTAssertNil(MissionsDashboardAssembly.summaryText(convoID: "c3", roster: roster, tocs: tocs, snippet: nil))
    }

    // MARK: Review Focus

    /// Review Focus: the server's count can be ahead of the local items.
    func testNeedsYouUsesTheLargerCountAndCapsRowsAtThree() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_ahead", num: 1, needsYou: 5), mission("ms_local", num: 2, needsYou: 0),
                           mission("ms_closed", num: 3, state: .closed, needsYou: 99, closedAt: ago(1))]
        let items = (1...4).map { i in
            TrackerItem(id: "it_\(i)", num: i, kind: .question, awaiting: .user, title: "Q\(i)",
                        originConvoID: "c1", missionID: "ms_local", missionNum: 2)
        }
        let onlyOneSynced = TrackerItem(id: "it_a", num: 9, kind: .question, awaiting: .user, title: "Only one synced",
                                        originConvoID: "c1", missionID: "ms_ahead", missionNum: 1)
        inputs.needsYouItems = ["ms_ahead": [onlyOneSynced], "ms_local": items]
        let cards = Dictionary(uniqueKeysWithValues: MissionsDashboardAssembly.assemble(inputs, now: now).cards.map { ($0.id, $0) })
        XCTAssertEqual(cards["ms_ahead"]?.needsYouCount, 5)
        XCTAssertEqual(cards["ms_ahead"]?.needsYouItems.map(\.id), ["it_a"])
        XCTAssertEqual(cards["ms_ahead"]?.moreNeedsYou, 4)
        XCTAssertEqual(cards["ms_local"]?.needsYouCount, 4, "the server's stale 0 never hides local asks")
        XCTAssertEqual(cards["ms_local"]?.needsYouItems.count, 3)
        XCTAssertEqual(cards["ms_local"]?.moreNeedsYou, 1)
        XCTAssertNil(cards["ms_closed"], "closed missions never produce a card, however high their needs-you count")
    }

    /// Review Focus: a session on another box this device never synced.
    func testAnUncachedMissionSessionRendersFromTheDetailRow() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1)]
        inputs.conversationsByMission = ["ms_1": [convo("c-far", state: "running", title: "[xy] Far away work", box: "dev-9")]]
        inputs.tocs = ["c-far": "Heading from the TOC"]
        let session = MissionsDashboardAssembly.assemble(inputs, now: now).cards[0].sessions[0]
        XCTAssertEqual(session.title, "Far away work", "the [bc] short is peeled off the detail title")
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.boxName, "dev-9")
        XCTAssertEqual(session.tag?.sessionShort, "xy")
        XCTAssertEqual(session.summary, "Heading from the TOC")
    }

    func testLatestStepPrefersTheCachedMilestoneWithItsBody() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1, lastMilestoneAt: ago(60)), mission("ms_2", num: 2, lastMilestoneAt: ago(60))]
        inputs.latestMilestones = ["ms_1": Milestone(id: "ml_1", missionID: "ms_1", num: 101, kind: .progress, title: "step",
                                                     body: "Wired the migration", convoID: "c1", seq: 4, createdAt: ago(60))]
        let cards = Dictionary(uniqueKeysWithValues: MissionsDashboardAssembly.assemble(inputs, now: now).cards.map { ($0.id, $0) })
        XCTAssertEqual(cards["ms_1"]?.latestStep?.body, "Wired the migration")
        XCTAssertEqual(cards["ms_2"]?.latestStep?.title, "step", "no cached milestone: the list row's title, no body")
        XCTAssertEqual(cards["ms_2"]?.latestStep?.body, "")

        var none = MissionsDashboardInputs()
        none.missions = [mission("ms_3", num: 3)]
        XCTAssertNil(MissionsDashboardAssembly.assemble(none, now: now).cards[0].latestStep, "no milestone, no step")
    }
}
