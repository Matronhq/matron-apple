import XCTest
import MatronModels
import MatronChat
@testable import MatronViewModels

/// Builds `summaries` and their `sessionStates` together, so a test can't
/// forget to copy one into the other — `ChatSummary` carries no session
/// state of its own (removed for chat-list performance; Task 4 added
/// `JournalStore.sessionStates()` instead), so the two must always travel
/// as a pair.
private extension MissionsDashboardInputs {
    mutating func setSummaries(_ pairs: [(ChatSummary, String)]) {
        summaries = pairs.map(\.0)
        sessionStates = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.id, $0.1) })
    }
}

final class MissionsDashboardAssemblyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

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

    /// Builds a `ChatSummary` alongside its intended session state, for
    /// `MissionsDashboardInputs.setSummaries(_:)`. `ChatSummary` itself has
    /// no `sessionState` field, so a test that doesn't care about state
    /// (e.g. testing the `roster`/`toc`/`snippet` fallback) can drop the
    /// `.1` and assign `.summaries` directly, leaving `.sessionStates`
    /// empty — which is itself how the "no entry" fallback tests work.
    private func summary(_ id: String, state: String = "waiting", last: Date? = nil, parent: String? = nil,
                         snippet: String = "", title: String? = nil, needs: Int = 0,
                         rooms: [String] = []) -> (ChatSummary, String) {
        (ChatSummary(id: id, title: title ?? "Chat \(id)",
                    bot: BotIdentity(matrixID: "agent:claude", displayName: "Claude", avatarURL: nil),
                    lastActivity: last, unreadCount: 0, snippet: snippet, parentConvoID: parent,
                    roomConvoIDs: rooms, needsUserCount: needs), state)
    }

    private func convo(_ id: String, state: String = "waiting", title: String = "", box: String? = nil,
                       endedAt: Date? = nil) -> MissionConversation {
        MissionConversation(id: id, title: title, box: box, state: state, endedAt: endedAt)
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
        XCTAssertEqual(MissionsDashboardAssembly.attribution(for: fromCoordinator, coordinatorConvoID: "c-coord", originTitle: "Parser work"),
                       "from Coordinator", "the Coordinator wins even when this device also has a title cached")
        XCTAssertEqual(MissionsDashboardAssembly.attribution(for: fromElsewhere, coordinatorConvoID: "c-coord", originTitle: "Parser work"),
                       "from Parser work")
        XCTAssertNil(MissionsDashboardAssembly.attribution(for: unknown, coordinatorConvoID: "c-coord", originTitle: nil))
        XCTAssertNil(MissionsDashboardAssembly.attribution(for: fromCoordinator, coordinatorConvoID: "", originTitle: nil))
        XCTAssertNil(MissionsDashboardAssembly.attribution(for: fromElsewhere, coordinatorConvoID: "c-coord", originTitle: ""),
                     "a blank cached title is treated as unknown")
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
        inputs.setSummaries([summary("c1", last: ago(10))])
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
        inputs.setSummaries([
            summary("done", state: "done", last: ago(1)),
            summary("wait_old", last: ago(300)),
            summary("wait_new", last: ago(10)),
            summary("run", state: "running", last: ago(5_000)),
            summary("wait_mid", last: ago(100)),
            summary("never", last: nil),
        ])
        let card = MissionsDashboardAssembly.assemble(inputs, now: now).cards[0]
        XCTAssertEqual(card.sessions.map(\.id), ["run", "wait_new", "wait_mid", "wait_old"])
        XCTAssertEqual(card.moreSessions, 2)
        XCTAssertTrue(card.anyRunning)
    }

    func testSubAgentSessionsStayOffTheCard() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1)]
        inputs.conversationsByMission = ["ms_1": [
            convo("parent", state: "running"), convo("parent:sub:a1", state: "running"),
        ]]
        // Production summaries never carry a child (the conversations
        // stream drops rows with a parent), so only the parent has one.
        inputs.setSummaries([summary("parent", state: "running", last: ago(10))])
        let card = MissionsDashboardAssembly.assemble(inputs, now: now).cards[0]
        XCTAssertEqual(card.sessions.map(\.id), ["parent"])
        XCTAssertEqual(card.moreSessions, 0)
    }

    /// Preflight R7: the detail now asks for `history=1`, so a conversation
    /// that LEFT the mission is cached too — it is not one of its sessions.
    func testAnEndedLinkIsNotASession() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1)]
        inputs.conversationsByMission = ["ms_1": [
            convo("c-on", state: "running"),
            MissionConversation(id: "c-left", title: "Left", box: nil, state: "running",
                                endedAt: ago(60)),
        ]]
        let snapshot = MissionsDashboardAssembly.assemble(inputs, now: now)
        XCTAssertEqual(snapshot.cards[0].sessions.map(\.id), ["c-on"])
        XCTAssertEqual(snapshot.sessionsByMission["ms_1"]?.map(\.id), ["c-on"])
    }

    /// `subchats=1` lists sub-chats with a `parent_convo_id`; they are the
    /// work of a listed session, whatever their id looks like.
    func testASubChatRowIsNotASession() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1)]
        inputs.conversationsByMission = ["ms_1": [
            convo("parent", state: "running"),
            MissionConversation(id: "child", title: "Child", box: nil, state: "running", parentConvoID: "parent"),
        ]]
        XCTAssertEqual(MissionsDashboardAssembly.assemble(inputs, now: now).sessionsByMission["ms_1"]?.map(\.id),
                       ["parent"])
    }

    /// Preflight R7: a conversation whose only link ended is on no mission,
    /// so it reaches the loose list.
    func testAConversationWhoseOnlyLinkEndedIsLoose() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1)]
        inputs.conversationsByMission = ["ms_1": [
            convo("c-on", state: "running"),
            MissionConversation(id: "c-left", title: "Left", box: nil, state: "running", endedAt: ago(60)),
        ]]
        inputs.setSummaries([summary("c-on", state: "running", last: ago(10)),
                             summary("c-left", state: "running", last: ago(10))])
        XCTAssertEqual(MissionsDashboardAssembly.assemble(inputs, now: now).looseSessions.map(\.id), ["c-left"])
    }

    /// The Mac mission page lists every session (no cap), with the card's
    /// order and the card's sub-agent rule — a `:sub:` id stays off.
    func testSessionsByMissionIsUncappedSortedAndExcludesSubAgents() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1), mission("ms_2", num: 2, state: .closed)]
        inputs.conversationsByMission = [
            "ms_1": [convo("done"), convo("wait_old"), convo("wait_new"), convo("run"), convo("wait_mid"),
                     convo("never"), convo("run:sub:a1", state: "running")],
            "ms_2": [convo("closed_run", state: "running")],
        ]
        inputs.setSummaries([
            summary("done", state: "done", last: ago(1)),
            summary("wait_old", last: ago(300)),
            summary("wait_new", last: ago(10)),
            summary("run", state: "running", last: ago(5_000)),
            summary("wait_mid", last: ago(100)),
            summary("never", last: nil),
        ])
        let snapshot = MissionsDashboardAssembly.assemble(inputs, now: now)
        XCTAssertEqual(snapshot.sessionsByMission["ms_1"]?.map(\.id),
                       ["run", "wait_new", "wait_mid", "wait_old", "never", "done"])
        XCTAssertEqual(snapshot.cards[0].sessions.map(\.id), ["run", "wait_new", "wait_mid", "wait_old"],
                       "the card is the same list, capped")
        XCTAssertEqual(snapshot.sessionsByMission["ms_2"]?.map(\.id), ["closed_run"],
                       "a closed mission's page still lists its sessions")
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

    /// No `sessionStates` entry at all for a cached mission conversation:
    /// falls back to the detail row's own `state` — never to a blanket
    /// "waiting" (that fallback is for loose sessions only, which have no
    /// detail row to fall back to).
    func testCachedMissionConversationWithNoStateEntryFallsBackToConvoState() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1)]
        inputs.conversationsByMission = ["ms_1": [convo("c1", state: "running")]]
        // A ChatSummary IS cached for "c1" (so the summary branch runs), but
        // `sessionStates` is left empty — no entry for "c1" anywhere.
        inputs.summaries = [summary("c1", last: ago(60)).0]
        let session = MissionsDashboardAssembly.assemble(inputs, now: now).cards[0].sessions[0]
        XCTAssertEqual(session.state, .running, "no sessionStates entry: falls back to the mission detail row's state")
    }

    // MARK: Loose sessions (spec §3.3)

    func testLooseSessionMembership() {
        var inputs = MissionsDashboardInputs()
        inputs.coordinatorConvoID = "c-coord"
        inputs.missions = [mission("ms_1", num: 1, origin: "c-origin"),
                           mission("ms_closed", num: 2, state: .closed, origin: "c-closed-origin", closedAt: ago(1))]
        inputs.conversationsByMission = ["ms_1": [convo("c-member")], "ms_closed": [convo("c-on-closed", state: "running")]]
        inputs.setSummaries([
            summary("c-running-old", state: "running", last: ago(10 * 86_400)),
            summary("c-waiting-recent", last: ago(3_600)),
            summary("c-waiting-stale", last: ago(25 * 3_600)),
            summary("c-waiting-never", last: nil),
            summary("c-done", state: "done", last: ago(60)),
            summary("c-child", state: "running", last: ago(60), parent: "c-running-old"),
            summary("c-coord", state: "running", last: ago(60)),
            summary("c-member", state: "running", last: ago(60)),
            // "c-origin" is ms_1's originConvoID, but ms_1's conversation
            // list HAS loaded (it's just ["c-member"]) — the origin only
            // stands in for a not-yet-loaded list (spec §3.3: "on a
            // mission" means literally on its loaded conversation list), so
            // this running session is loose, not excluded.
            summary("c-origin", state: "running", last: ago(60)),
            summary("c-on-closed", state: "running", last: ago(60)),
        ])
        let ids = Set(MissionsDashboardAssembly.assemble(inputs, now: now).looseSessions.map(\.id))
        XCTAssertEqual(ids, ["c-running-old", "c-waiting-recent", "c-origin", "c-on-closed"],
                       "running always, waiting only inside 24 h; never a child, the Coordinator, or a session actually on an open mission's loaded list")
    }

    /// A mission made with `mission_create` and never assigned a
    /// conversation (`conversationCount == 0`) has an origin session that
    /// isn't "on" it in any list sense — that origin must stay loose, or an
    /// unassigned mission born outside the Coordinator would make its own
    /// still-running session vanish from the page entirely (its card has no
    /// sessions either).
    func testUnassignedMissionsRunningOriginStaysLoose() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_unassigned", num: 1, origin: "c-origin", conversations: 0)]
        inputs.setSummaries([summary("c-origin", state: "running", last: ago(60))])
        let ids = MissionsDashboardAssembly.assemble(inputs, now: now).looseSessions.map(\.id)
        XCTAssertEqual(ids, ["c-origin"], "an unassigned mission's origin session has nowhere else on the page to appear")
    }

    /// The origin stands in for an open mission's conversation list only
    /// while that list genuinely hasn't loaded yet (no entry in
    /// `conversationsByMission`, as opposed to a loaded-but-empty one) AND
    /// the mission is known (from its list-row `conversationCount`) to have
    /// at least one conversation — otherwise the origin would flash into
    /// "loose" between the missions list fetch and the per-mission detail
    /// fetch landing.
    func testOriginStandsInForAnOpenMissionWhoseConversationListHasNotLoadedYet() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1, origin: "c-origin", conversations: 3)]
        // No `conversationsByMission["ms_1"]` entry at all — detail not fetched yet.
        inputs.setSummaries([summary("c-origin", state: "running", last: ago(60))])
        let ids = MissionsDashboardAssembly.assemble(inputs, now: now).looseSessions.map(\.id)
        XCTAssertEqual(ids, [], "the origin stands in for the not-yet-loaded list, so it's excluded from loose")
    }

    func testLooseSessionsPutRunningFirstThenActivity() {
        var inputs = MissionsDashboardInputs()
        inputs.setSummaries([
            summary("wait_new", last: ago(10)),
            summary("run_old", state: "running", last: ago(5_000)),
            summary("wait_old", last: ago(600)),
            summary("run_new", state: "running", last: ago(100)),
        ])
        XCTAssertEqual(MissionsDashboardAssembly.assemble(inputs, now: now).looseSessions.map(\.id),
                       ["run_new", "run_old", "wait_new", "wait_old"])
    }

    /// No `sessionStates` entry for a loose summary reads as "waiting" (the
    /// store's own fallback): dropped once its last activity falls outside
    /// the 24 h window, kept while it's recent.
    func testLooseSessionWithNoStateEntryFallsBackToWaiting() {
        var inputs = MissionsDashboardInputs()
        inputs.summaries = [summary("no-entry-recent", last: ago(60)).0,
                            summary("no-entry-stale", last: ago(25 * 3_600)).0]
        // `sessionStates` is left empty — no entry for either id.
        let ids = Set(MissionsDashboardAssembly.assemble(inputs, now: now).looseSessions.map(\.id))
        XCTAssertEqual(ids, ["no-entry-recent"], "no entry reads as waiting: dropped once stale, kept while recent")
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

    // MARK: Closed missions

    func testClosedMissionsBreakEqualOrNilCloseTimesByNumber() {
        var inputs = MissionsDashboardInputs()
        let closedTogether = ago(100)
        inputs.missions = [
            mission("ms_a", num: 5, state: .closed, closedAt: closedTogether),
            mission("ms_b", num: 9, state: .closed, closedAt: closedTogether),
            mission("ms_c", num: 1, state: .closed, closedAt: nil),
            mission("ms_d", num: 2, state: .closed, closedAt: nil),
        ]
        let ids = MissionsDashboardAssembly.assemble(inputs, now: now).closed.map(\.id)
        XCTAssertEqual(ids, ["ms_b", "ms_a", "ms_d", "ms_c"], "equal (including nil) closedAt breaks by the higher mission number")
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

    // MARK: Rooms (Dan, 2026-10-01: rooms show in the work views)

    func testARoomWithAnActiveParticipantIsOnThatMissionAndNotLoose() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1)]
        inputs.conversationsByMission = ["ms_1": [convo("c-a")]]
        inputs.setSummaries([summary("c-a", state: "running", last: ago(10)),
                             summary("c-b", state: "running", last: ago(10)),
                             summary("room", state: "running", last: ago(5), rooms: ["c-a", "c-b"])])
        let snapshot = MissionsDashboardAssembly.assemble(inputs, now: now)
        XCTAssertEqual(snapshot.roomCountsByMission, ["ms_1": 1])
        XCTAssertEqual(snapshot.cards.first?.roomCount, 1)
        XCTAssertEqual(snapshot.cards.first?.sessions.map(\.id), ["c-a"], "a room is never a session row")
        XCTAssertFalse(snapshot.looseSessions.map(\.id).contains("room"))
        XCTAssertEqual(snapshot.looseSessions.map(\.id), ["c-b"])
    }

    func testARoomWhoseParticipantsAreAllOffMissionIsOnNoMission() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1)]
        inputs.conversationsByMission = ["ms_1": [convo("c-x")]]
        inputs.setSummaries([summary("room", state: "running", last: ago(5), rooms: ["c-a", "c-b"])])
        let snapshot = MissionsDashboardAssembly.assemble(inputs, now: now)
        XCTAssertEqual(snapshot.roomCountsByMission, [:])
        XCTAssertEqual(snapshot.cards.first?.roomCount, 0)
        XCTAssertEqual(snapshot.looseSessions.map(\.id), ["room"])
    }

    func testAParticipantWhoseLinkEndedDoesNotPlaceTheRoom() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1)]
        inputs.conversationsByMission = ["ms_1": [convo("c-a", endedAt: ago(100))]]
        inputs.setSummaries([summary("room", state: "running", last: ago(5), rooms: ["c-a"])])
        let snapshot = MissionsDashboardAssembly.assemble(inputs, now: now)
        XCTAssertEqual(snapshot.roomCountsByMission, [:], "R7: active links only")
    }

    func testARoomSpanningTwoMissionsIsOnBoth() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1), mission("ms_2", num: 2)]
        inputs.conversationsByMission = ["ms_1": [convo("c-a")], "ms_2": [convo("c-b")]]
        inputs.setSummaries([summary("room", last: ago(5), rooms: ["c-a", "c-b"])])
        let snapshot = MissionsDashboardAssembly.assemble(inputs, now: now)
        XCTAssertEqual(snapshot.roomCountsByMission, ["ms_1": 1, "ms_2": 1])
    }

    func testAParticipantOnAClosedMissionDoesNotPlaceTheRoom() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1, state: .closed, closedAt: ago(50))]
        inputs.conversationsByMission = ["ms_1": [convo("c-a")]]
        inputs.setSummaries([summary("room", state: "running", last: ago(5), rooms: ["c-a"])])
        let snapshot = MissionsDashboardAssembly.assemble(inputs, now: now)
        XCTAssertEqual(snapshot.roomCountsByMission, [:])
        XCTAssertEqual(snapshot.looseSessions.map(\.id), ["room"])
    }

    func testTheOriginStandsInForAMissionWhoseDetailHasNotLoaded() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1, origin: "c-a", conversations: 2)]
        inputs.setSummaries([summary("room", state: "running", last: ago(5), rooms: ["c-a"])])
        let snapshot = MissionsDashboardAssembly.assemble(inputs, now: now)
        XCTAssertEqual(snapshot.roomCountsByMission, ["ms_1": 1])
        XCTAssertEqual(snapshot.cards.first?.roomCount, 1)
        XCTAssertEqual(snapshot.looseSessions, [])
    }

    func testRoomsDoNotTakeSessionRows() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1)]
        inputs.conversationsByMission = ["ms_1": (1...4).map { convo("c\($0)") }]
        inputs.setSummaries((1...4).map { summary("c\($0)", last: ago(Double($0))) }
            + (1...3).map { summary("room\($0)", last: ago(1), rooms: ["c\($0)"]) })
        let card = MissionsDashboardAssembly.assemble(inputs, now: now).cards.first
        XCTAssertEqual(card?.sessions.map(\.id), ["c1", "c2", "c3", "c4"])
        XCTAssertEqual(card?.moreSessions, 0)
        XCTAssertEqual(card?.roomCount, 3)
        XCTAssertEqual(MissionsDashboardAssembly.assemble(inputs, now: now).sessionsByMission["ms_1"]?.count, 4)
    }

    func testARoomWithTwoParticipantsOnOneMissionCountsOnce() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1)]
        inputs.conversationsByMission = ["ms_1": [convo("c-a"), convo("c-b")]]
        inputs.setSummaries([summary("room", last: ago(5), rooms: ["c-a", "c-b"])])
        XCTAssertEqual(MissionsDashboardAssembly.assemble(inputs, now: now).roomCountsByMission, ["ms_1": 1])
    }

    func testARoomWithNoKnownParticipantsIsOnNoMission() {
        var inputs = MissionsDashboardInputs()
        inputs.missions = [mission("ms_1", num: 1)]
        inputs.conversationsByMission = ["ms_1": [convo("c-a")]]
        inputs.setSummaries([summary("room", state: "running", last: ago(5), title: "↔️ a ↔ b")])
        let snapshot = MissionsDashboardAssembly.assemble(inputs, now: now)
        XCTAssertEqual(snapshot.roomCountsByMission, [:])
        XCTAssertEqual(snapshot.looseSessions.map(\.id), ["room"])
    }
}
