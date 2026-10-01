import XCTest
import MatronModels
@testable import MatronViewModels

final class ProjectsHomeAssemblyTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
    static let day: TimeInterval = 86_400

    static func mission(_ id: String, num: Int, project: String? = nil, activity: MissionActivity? = nil,
                        needsYou: Int = 0, lastMilestone: TimeInterval? = 3_600, state: MissionState = .open,
                        closedAt: TimeInterval? = nil, milestoneTitle: String = "step") -> Mission {
        Mission(id: id, num: num, state: state, title: "M\(num)", originConvoID: "c1",
                createdAt: ago(30 * day), updatedAt: ago(30 * day),
                lastMilestoneAt: lastMilestone.map(ago), closedAt: closedAt.map(ago), needsYou: needsYou,
                lastMilestone: lastMilestone.map { MissionLastMilestone(num: num + 1000, title: milestoneTitle,
                                                                        kind: .progress, createdAt: ago($0)) },
                projectID: project, activity: activity)
    }

    static func project(_ id: String, num: Int, running: Int = 0, needsYou: Int = 0,
                        lastActivity: TimeInterval = 3_600, state: MissionState = .open) -> Project {
        Project(id: id, num: num, state: state, title: "P\(num)", createdAt: ago(30 * day), updatedAt: ago(day),
                missions: ProjectMissionCounts(running: running, waiting: 1), needsYou: needsYou,
                lastActivityAt: ago(lastActivity))
    }

    // MARK: Activity

    func testActivityPrefersTheServerValue() {
        let m = Self.mission("ms_1", num: 1, activity: .running, lastMilestone: 30 * Self.day)
        XCTAssertEqual(ProjectsHomeAssembly.activity(of: m, needsYou: 0, now: Self.now), .running)
    }

    func testActivityDerivesQuietAfterSevenDaysAndNeverWithNeedsYou() {
        let old = Self.mission("ms_1", num: 1, lastMilestone: 8 * Self.day)
        XCTAssertEqual(ProjectsHomeAssembly.activity(of: old, needsYou: 0, now: Self.now), .quiet)
        XCTAssertEqual(ProjectsHomeAssembly.activity(of: old, needsYou: 1, now: Self.now), .waiting)
        let fresh = Self.mission("ms_2", num: 2, lastMilestone: 6 * Self.day)
        XCTAssertEqual(ProjectsHomeAssembly.activity(of: fresh, needsYou: 0, now: Self.now), .idle)
        let serverQuietButAsking = Self.mission("ms_3", num: 3, activity: .quiet)
        XCTAssertEqual(ProjectsHomeAssembly.activity(of: serverQuietButAsking, needsYou: 2, now: Self.now), .waiting)
    }

    /// The journal's boundary: quiet at exactly seven days (`>= QUIET_MS`).
    func testActivityIsQuietAtExactlySevenDays() {
        let edge = Self.mission("ms_1", num: 1, lastMilestone: ProjectsHomeAssembly.quietAfter)
        XCTAssertEqual(ProjectsHomeAssembly.activity(of: edge, needsYou: 0, now: Self.now), .quiet)
    }

    /// The server's `last_activity_at` sees joins and messages the local
    /// derivation can't, so it wins — even when older than a milestone.
    func testLastActivityPrefersTheServerValue() {
        let base = Self.mission("ms_1", num: 1, lastMilestone: 60)
        XCTAssertEqual(ProjectsHomeAssembly.lastActivity(of: base), Self.ago(60), "derived without the server value")
        let served = Mission(id: "ms_2", num: 2, title: "M2", originConvoID: "c1",
                             createdAt: Self.ago(30 * Self.day), updatedAt: Self.ago(30 * Self.day),
                             lastMilestoneAt: Self.ago(60), lastActivityAt: Self.ago(8 * Self.day))
        XCTAssertEqual(ProjectsHomeAssembly.lastActivity(of: served), Self.ago(8 * Self.day))
        XCTAssertEqual(ProjectsHomeAssembly.activity(of: served, needsYou: 0, now: Self.now), .quiet)
    }

    // MARK: Home

    func testCardsSortNeedsYouThenRunningThenActivity() {
        let snapshot = ProjectsHomeAssembly.assemble(
            projects: [Self.project("pj_quiet", num: 1, lastActivity: 60),
                       Self.project("pj_running", num: 2, running: 1, lastActivity: 7_200),
                       Self.project("pj_asks", num: 3, needsYou: 2, lastActivity: 9_000),
                       Self.project("pj_closed", num: 4, state: .closed)],
            missions: [], needsYouItems: [:], now: Self.now)
        XCTAssertEqual(snapshot.cards.map(\.id), ["pj_asks", "pj_running", "pj_quiet"])
    }

    func testCardNeedsYouUsesTheLargerCountAndCarriesTheLatestMilestone() {
        let snapshot = ProjectsHomeAssembly.assemble(
            projects: [Self.project("pj_1", num: 1, needsYou: 1)],
            missions: [Self.mission("ms_1", num: 10, project: "pj_1", needsYou: 2, lastMilestone: 9_000, milestoneTitle: "older"),
                       Self.mission("ms_2", num: 11, project: "pj_1", lastMilestone: 60, milestoneTitle: "newest")],
            needsYouItems: ["ms_2": [TrackerItem(id: "it_1", num: 90, kind: .question, awaiting: .user, title: "Q",
                                                 originConvoID: "c1", missionID: "ms_2")]],
            now: Self.now)
        XCTAssertEqual(snapshot.cards.first?.needsYouCount, 3)
        XCTAssertEqual(snapshot.cards.first?.latestMilestone?.title, "newest")
    }

    func testUnfiledRowsSplitQuietAndSortNeedsYouThenActivityRank() {
        let snapshot = ProjectsHomeAssembly.assemble(
            projects: [Self.project("pj_1", num: 1)],
            missions: [Self.mission("ms_filed", num: 1, project: "pj_1"),
                       Self.mission("ms_idle", num: 2, activity: .idle, lastMilestone: 60),
                       Self.mission("ms_running", num: 3, activity: .running, lastMilestone: 7_200),
                       Self.mission("ms_asks", num: 4, activity: .waiting, needsYou: 1, lastMilestone: 90_000),
                       Self.mission("ms_quiet_old", num: 5, activity: .quiet, lastMilestone: 20 * Self.day),
                       Self.mission("ms_quiet_new", num: 6, activity: .quiet, lastMilestone: 9 * Self.day),
                       Self.mission("ms_closed", num: 7, state: .closed, closedAt: 60)],
            needsYouItems: [:], now: Self.now)
        XCTAssertEqual(snapshot.unfiled.map(\.id), ["ms_asks", "ms_running", "ms_idle"])
        XCTAssertEqual(snapshot.quiet.map(\.id), ["ms_quiet_new", "ms_quiet_old"])
        XCTAssertEqual(snapshot.closed.map(\.id), ["ms_closed"])
    }

    /// Review Focus: a project this device hasn't cached (or one that
    /// closed) must not swallow its missions.
    func testAMissionInAnUnknownProjectStaysOnTheHomeScreen() {
        let snapshot = ProjectsHomeAssembly.assemble(
            projects: [Self.project("pj_closed", num: 9, state: .closed)],
            missions: [Self.mission("ms_1", num: 1, project: "pj_unknown", activity: .running),
                       Self.mission("ms_2", num: 2, project: "pj_closed", activity: .idle)],
            needsYouItems: [:], now: Self.now)
        XCTAssertEqual(Set(snapshot.unfiled.map(\.id)), ["ms_1", "ms_2"])
    }

    func testStatusRefreshedIsTheNewestProjectStatus() {
        let a = Project(id: "pj_a", num: 1, title: "A", statusUpdatedAt: Self.ago(600))
        let b = Project(id: "pj_b", num: 2, title: "B", statusUpdatedAt: Self.ago(60))
        let snapshot = ProjectsHomeAssembly.assemble(projects: [a, b], missions: [], needsYouItems: [:], now: Self.now)
        XCTAssertEqual(snapshot.statusRefreshedAt, Self.ago(60))
    }

    // MARK: Conversation groups

    private func convo(_ id: String, state: String = "running", joined: TimeInterval? = 100, ended: TimeInterval? = nil,
                       parent: String? = nil, subchats: Int = 0) -> MissionConversation {
        MissionConversation(id: id, title: id, box: "greg", state: state,
                            joinedAt: joined.map(Self.ago), endedAt: ended.map(Self.ago), how: "joined",
                            parentConvoID: parent, subchatCount: subchats)
    }

    func testGroupsSplitOnItNowAndEarlier() {
        let groups = MissionConversationGroups(conversations: [
            convo("c-wait", state: "waiting", joined: 50),
            convo("c-run", state: "running", joined: 500),
            convo("c-gone-old", ended: 900),
            convo("c-gone-new", ended: 100),
        ], missionState: .open)
        XCTAssertEqual(groups.onItNow.map(\.id), ["c-run", "c-wait"], "running first")
        XCTAssertEqual(groups.earlier.map(\.id), ["c-gone-new", "c-gone-old"], "most recently ended first")
    }

    func testSubChatsFoldUnderTheirParent() {
        let groups = MissionConversationGroups(conversations: [
            convo("c1"), convo("c1:sub:a", parent: "c1"), convo("c1:sub:b", parent: "c1"),
        ], missionState: .open)
        XCTAssertEqual(groups.onItNow.map(\.id), ["c1"])
        XCTAssertEqual(groups.onItNow.first?.subchats.map(\.id), ["c1:sub:a", "c1:sub:b"])
        XCTAssertEqual(groups.subchatTotal, 2)
    }

    /// Review Focus: the parent never joined — the child is its own row.
    func testAnOrphanSubChatIsItsOwnRow() {
        let groups = MissionConversationGroups(conversations: [convo("c9:sub:x", parent: "c9")], missionState: .open)
        XCTAssertEqual(groups.onItNow.map(\.id), ["c9:sub:x"])
    }

    func testTheJournalsFoldedCountIsKeptWhenSubChatsAreNotListed() {
        let groups = MissionConversationGroups(conversations: [convo("c1", subchats: 6)], missionState: .open)
        XCTAssertEqual(groups.onItNow.first?.subchatCount, 6)
    }

    // MARK: also on / moved to (other_missions)

    private func other(_ num: Int, current: Bool = false, joined: TimeInterval? = 500, ended: TimeInterval? = nil)
        -> MissionOtherLink {
        MissionOtherLink(id: "ms_\(num)", num: num, title: "M\(num)", isCurrent: current, isActive: ended == nil,
                         joinedAt: joined.map(Self.ago), endedAt: ended.map(Self.ago))
    }

    private func linked(_ own: MissionConversation) -> MissionConversationRow {
        MissionConversationRow(conversation: own, state: .running)
    }

    /// An active row with another active link: "also on #N", the current
    /// one first (journal order), never an ended one.
    func testAlsoOnNamesTheOtherActiveLinkCurrentFirst() {
        let own = MissionConversation(id: "c1", title: "t", box: nil, state: "running", joinedAt: Self.ago(900),
                                      otherMissions: [other(4791, current: true), other(4905), other(4083, ended: 100)])
        XCTAssertEqual(linked(own).alsoOn?.num, 4791)
        XCTAssertNil(linked(own).movedTo, "an active row never moved")
        XCTAssertEqual(linked(own).linkedMission, .alsoOn(other(4791, current: true)))
        let onlyEnded = MissionConversation(id: "c2", title: "t", box: nil, state: "running",
                                            otherMissions: [other(4083, ended: 100)])
        XCTAssertNil(linked(onlyEnded).alsoOn)
    }

    /// An Earlier row whose own link ended while another was then current:
    /// "moved to #N". "Then current" = joined at or before this link ended
    /// and not ended before it; a link flagged current wins, else the one
    /// joined latest.
    func testMovedToNamesTheLinkThatWasCurrentWhenThisOneEnded() {
        let own = MissionConversation(id: "c1", title: "t", box: nil, state: "done",
                                      joinedAt: Self.ago(9_000), endedAt: Self.ago(3_000),
                                      otherMissions: [other(4905, joined: 3_000),          // joined as this ended
                                                      other(5000, joined: 1_000),          // joined after: not "then"
                                                      other(4001, joined: 8_000, ended: 5_000)]) // ended before: not "then"
        XCTAssertEqual(linked(own).movedTo?.num, 4905)
        XCTAssertNil(linked(own).alsoOn, "an ended row is never 'also on'")
        XCTAssertEqual(linked(own).linkedMission?.link.id, "ms_4905", "the chip opens that mission")
        XCTAssertEqual(linked(own).linkedMission?.label, "moved to")
        let two = MissionConversation(id: "c2", title: "t", box: nil, state: "done", endedAt: Self.ago(3_000),
                                      otherMissions: [other(10, joined: 5_000), other(11, current: true, joined: 6_000)])
        XCTAssertEqual(linked(two).movedTo?.num, 11, "the flagged-current link wins over the later join")
    }

    /// Old journal / folded sub-chat: no `other_missions`, no chip.
    func testNoOtherMissionsNoChip() {
        let own = MissionConversation(id: "c1", title: "t", box: nil, state: "done", endedAt: Self.ago(60))
        XCTAssertNil(linked(own).linkedMission)
    }

    func testAClosedMissionHasOnlyEarlierAndLiveStateWins() {
        let closed = MissionConversationGroups(conversations: [convo("c1")], missionState: .closed)
        XCTAssertEqual(closed.onItNow, []); XCTAssertEqual(closed.earlier.map(\.id), ["c1"])
        let live = MissionConversationGroups(conversations: [convo("c1", state: "running")], missionState: .open,
                                             liveStates: ["c1": "done"])
        XCTAssertEqual(live.onItNow.first?.state, .done)
    }
}
