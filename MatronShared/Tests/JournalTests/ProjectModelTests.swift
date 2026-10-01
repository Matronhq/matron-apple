import XCTest
import MatronModels
@testable import MatronJournal

final class ProjectModelTests: XCTestCase {
    static let projectJSON: [String: Any] = [
        "id": "pj_1", "num": 4000, "state": "open", "title": "Promo launch",
        "body": "New promo site, blog and leavers' page.",
        "status": "Launch Wed 7 Oct, 07:00.", "status_by": "agent", "status_updated_at": 1_700_000_006_000,
        "close_summary": NSNull(), "closed_at": NSNull(), "merged_into": NSNull(),
        "origin_convo_id": "c-coord", "created_by": "agent",
        "created_at": 1_700_000_000_000, "updated_at": 1_700_000_006_000,
        "missions": ["running": 2, "waiting": 2, "idle": 0, "quiet": 1, "closed": 3],
        "needs_you": 6, "open_items": 37, "last_activity_at": 1_700_000_005_000,
    ]

    func testProjectDecodesAListRow() throws {
        let p = try XCTUnwrap(Project(json: Self.projectJSON))
        XCTAssertEqual(p.id, "pj_1"); XCTAssertEqual(p.num, 4000); XCTAssertEqual(p.state, .open)
        XCTAssertEqual(p.title, "Promo launch")
        XCTAssertEqual(p.status, "Launch Wed 7 Oct, 07:00.")
        XCTAssertEqual(p.statusBy, .agent)
        XCTAssertEqual(p.statusUpdatedAt, Date(timeIntervalSince1970: 1_700_000_006))
        XCTAssertEqual(p.missions, ProjectMissionCounts(running: 2, waiting: 2, idle: 0, quiet: 1, closed: 3))
        XCTAssertEqual(p.missions.open, 5)
        XCTAssertEqual(p.needsYou, 6); XCTAssertEqual(p.openItems, 37)
        XCTAssertEqual(p.lastActivityAt, Date(timeIntervalSince1970: 1_700_000_005))
        XCTAssertEqual(p.label, "#4000 Promo launch")
    }

    /// An older or partial row without the rollup keys decodes with zero
    /// counts; a sieved status is null; a merged one names its target.
    func testProjectToleratesMissingCountsAndReadsMergedInto() throws {
        var json = Self.projectJSON
        json.removeValue(forKey: "missions"); json.removeValue(forKey: "needs_you")
        json["status"] = NSNull(); json["state"] = "closed"; json["merged_into"] = "pj_2"
        let p = try XCTUnwrap(Project(json: json))
        XCTAssertEqual(p.missions, ProjectMissionCounts())
        XCTAssertEqual(p.needsYou, 0)
        XCTAssertNil(p.status)
        XCTAssertEqual(p.state, .closed)
        XCTAssertEqual(p.mergedInto, "pj_2")
    }

    // MARK: Projects view v2 (journal PR 112)

    static let cardJSON: [String: Any] = [
        "waiting_on": ["item_id": "it_9", "num": 4120, "kind": "question", "title": "Which launch date?",
                       "mission_num": 4001, "more": 2],
        "latest": ["title": "Blog drafted", "kind": "progress", "at": 1_700_000_005_000, "mission_num": 4002],
        "sessions_now": 3,
    ]

    static let decisionJSON: [String: Any] = [
        "id": "it_d1", "num": 4130, "kind": "decision", "state": "open", "resolution": NSNull(),
        "title": "Launch on Wednesday", "supersedes": "it_d0", "created_at": 1_700_000_001_000,
        "closed_at": NSNull(), "mission_id": "ms_a1", "mission_num": 4001, "answer": NSNull(),
    ]
    static let answeredJSON: [String: Any] = [
        "id": "it_q1", "num": 4131, "kind": "question", "state": "closed", "resolution": "answered",
        "title": "Which colour?", "supersedes": NSNull(), "created_at": 1_700_000_001_000,
        "closed_at": 1_700_000_003_000, "mission_id": "ms_a1", "mission_num": 4001, "answer": "Blue",
    ]
    static let itemFileJSON: [String: Any] = [
        "blob_id": "b_1", "name": "plan.pdf", "content_type": "application/pdf", "size": 2048,
        "caption": NSNull(), "mission_num": 4001, "posted_at": 1_700_000_002_000, "source": ["item_num": 4131],
    ]
    static let chatFileJSON: [String: Any] = [
        "blob_id": "b_2", "name": "shot.png", "content_type": "image/png", "size": 99,
        "caption": "the hero", "mission_num": 4002, "posted_at": 1_700_000_002_500,
        "source": ["convo_id": "c1", "seq": 4211],
    ]
    static var milestoneRowJSON: [String: Any] {
        var row = MissionModelTests.milestoneJSON
        row["mission_num"] = 4001
        return row
    }

    func testProjectDecodesTheCardFields() throws {
        let p = try XCTUnwrap(Project(json: Self.projectJSON.merging(Self.cardJSON) { $1 }))
        XCTAssertEqual(p.waitingOn, ProjectWaitingOn(itemID: "it_9", num: 4120, kind: .question,
                                                     title: "Which launch date?", missionNum: 4001, more: 2))
        XCTAssertEqual(p.latest, ProjectLatest(title: "Blog drafted", kind: .progress,
                                               at: Date(timeIntervalSince1970: 1_700_000_005), missionNum: 4002))
        XCTAssertEqual(p.sessionsNow, 3)
        XCTAssertNotNil(p.card)
    }

    /// Sent, and empty: a project nobody waits on, with no milestone yet.
    /// The card is known (`card != nil`), so a list refresh replaces it.
    func testNullCardFieldsAreKnownAndEmpty() throws {
        let json = Self.projectJSON.merging(["waiting_on": NSNull(), "latest": NSNull(), "sessions_now": 0]) { $1 }
        let p = try XCTUnwrap(Project(json: json))
        XCTAssertEqual(p.card, ProjectCardFields())
        XCTAssertNil(p.waitingOn); XCTAssertNil(p.latest); XCTAssertEqual(p.sessionsNow, 0)
    }

    /// An older journal (or the detail route) sends no card keys at all:
    /// the row still decodes, with no card.
    func testAnOlderJournalsRowHasNoCard() throws {
        let p = try XCTUnwrap(Project(json: Self.projectJSON))
        XCTAssertNil(p.card)
        XCTAssertNil(p.waitingOn); XCTAssertNil(p.latest); XCTAssertEqual(p.sessionsNow, 0)
    }

    /// A malformed `waiting_on` / `latest` drops that field, not the row.
    func testAMalformedCardFieldDropsOnlyThatField() throws {
        let json = Self.projectJSON.merging(["waiting_on": ["num": 1], "latest": ["title": "no kind"],
                                             "sessions_now": 2]) { $1 }
        let p = try XCTUnwrap(Project(json: json))
        XCTAssertNil(p.waitingOn); XCTAssertNil(p.latest); XCTAssertEqual(p.sessionsNow, 2)
    }

    func testFeedRowsDecode() throws {
        let decision = try XCTUnwrap(ProjectDecision(json: Self.decisionJSON))
        XCTAssertEqual(decision.kind, .decision); XCTAssertEqual(decision.state, .open)
        XCTAssertNil(decision.resolution); XCTAssertNil(decision.answer)
        XCTAssertEqual(decision.supersedes, "it_d0"); XCTAssertEqual(decision.missionNum, 4001)
        XCTAssertEqual(decision.at, Date(timeIntervalSince1970: 1_700_000_001), "a decision dates from its record")

        let answered = try XCTUnwrap(ProjectDecision(json: Self.answeredJSON))
        XCTAssertEqual(answered.resolution, .answered); XCTAssertEqual(answered.answer, "Blue")
        XCTAssertEqual(answered.at, Date(timeIntervalSince1970: 1_700_000_003), "an answer dates from its close")

        let itemFile = try XCTUnwrap(ProjectFile(json: Self.itemFileJSON))
        XCTAssertEqual(itemFile.source, .item(num: 4131))
        XCTAssertEqual(itemFile.size, 2048); XCTAssertNil(itemFile.caption); XCTAssertFalse(itemFile.isImage)
        XCTAssertEqual(itemFile.postedAt, Date(timeIntervalSince1970: 1_700_000_002))
        XCTAssertEqual(itemFile.id, "item:4131:b_1")

        let chatFile = try XCTUnwrap(ProjectFile(json: Self.chatFileJSON))
        XCTAssertEqual(chatFile.source, .chat(convoID: "c1", seq: 4211))
        XCTAssertEqual(chatFile.caption, "the hero"); XCTAssertTrue(chatFile.isImage)
        XCTAssertEqual(chatFile.id, "chat:c1:4211")

        var noTime = Self.itemFileJSON
        noTime.removeValue(forKey: "posted_at")
        XCTAssertNil(try XCTUnwrap(ProjectFile(json: noTime)).postedAt, "no posted_at: the row stays, undated")

        let milestone = try XCTUnwrap(ProjectMilestone(json: Self.milestoneRowJSON))
        XCTAssertEqual(milestone.id, "ml_b2"); XCTAssertEqual(milestone.milestone.seq, 4210)
        XCTAssertEqual(milestone.missionNum, 4001)
    }

    func testFeedRowsWithoutTheirIdentityAreDropped() {
        XCTAssertNil(ProjectDecision(json: ["id": "it_x", "num": 1, "kind": "task", "title": "no state"]))
        XCTAssertNil(ProjectFile(json: ["blob_id": "b", "source": ["seq": 1]]), "a chat source needs its conversation")
        XCTAssertNil(ProjectFile(json: ["name": "x", "source": ["item_num": 1]]), "no blob, nothing to open")
        var noSeq = Self.milestoneRowJSON
        noSeq.removeValue(forKey: "seq")
        XCTAssertNil(ProjectMilestone(json: noSeq))
    }

    func testAFeedPageDropsBadRowsAndKeepsItsCursor() throws {
        let page = try XCTUnwrap(ProjectFeedPage<ProjectDecision>(json: [
            "total": 9, "rows": [Self.decisionJSON, ["id": "broken"], Self.answeredJSON],
            "next_before": "1700000001000:000000004130",
        ]))
        XCTAssertEqual(page.rows.map(\.id), ["it_d1", "it_q1"])
        XCTAssertEqual(page.total, 9)
        XCTAssertEqual(page.nextBefore, "1700000001000:000000004130")
        XCTAssertTrue(page.hasMore)
        let last = try XCTUnwrap(ProjectFeedPage<ProjectDecision>(json: ["total": 1, "rows": [Self.decisionJSON],
                                                                         "next_before": NSNull()]))
        XCTAssertNil(last.nextBefore); XCTAssertFalse(last.hasMore)
        XCTAssertNil(ProjectFeedPage<ProjectDecision>(json: ["total": 1]), "no rows array, no page")
    }

    func testAppendingSkipsRowsAlreadyShownAndTakesTheNewCursor() {
        let a = ProjectDecision(json: Self.decisionJSON)!, b = ProjectDecision(json: Self.answeredJSON)!
        let first = ProjectFeedPage(total: 2, rows: [a], nextBefore: "x")
        let merged = first.appending(ProjectFeedPage(total: 3, rows: [a, b], nextBefore: nil))
        XCTAssertEqual(merged.rows.map(\.id), ["it_d1", "it_q1"])
        XCTAssertEqual(merged.total, 3); XCTAssertNil(merged.nextBefore)
    }

    func testDetailFeedIsNilFromAnOlderJournalAndFillsMissingKinds() throws {
        XCTAssertNil(ProjectFeed(detailJSON: ["project": Self.projectJSON]))
        let feed = try XCTUnwrap(ProjectFeed(detailJSON: [
            "files": ["total": 1, "rows": [Self.chatFileJSON], "next_before": NSNull()],
        ]))
        XCTAssertEqual(feed.files.rows.count, 1)
        XCTAssertEqual(feed.decisions, ProjectFeedPage())
        XCTAssertEqual(feed.milestones, ProjectFeedPage())
    }

    /// The store keeps the feed and card as JSON: both round-trip exactly.
    func testFeedAndCardRoundTripThroughCodable() throws {
        let feed = ProjectFeed(
            decisions: ProjectFeedPage(total: 2, rows: [ProjectDecision(json: Self.decisionJSON)!,
                                                         ProjectDecision(json: Self.answeredJSON)!], nextBefore: "c"),
            files: ProjectFeedPage(total: 2, rows: [ProjectFile(json: Self.itemFileJSON)!,
                                                     ProjectFile(json: Self.chatFileJSON)!]),
            milestones: ProjectFeedPage(total: 1, rows: [ProjectMilestone(json: Self.milestoneRowJSON)!]))
        XCTAssertEqual(try JSONDecoder().decode(ProjectFeed.self, from: JSONEncoder().encode(feed)), feed)
        let card = try XCTUnwrap(ProjectCardFields(json: Self.cardJSON))
        XCTAssertEqual(try JSONDecoder().decode(ProjectCardFields.self, from: JSONEncoder().encode(card)), card)
    }

    func testProjectWithoutItsIdentityIsDropped() {
        XCTAssertNil(Project(json: ["id": "pj_x", "title": "No number"]))
    }

    func testConversationMissionLinkDecodesAFlatRow() throws {
        var row = MissionModelTests.missionJSON
        row["current"] = true; row["active"] = true; row["joined_at"] = 1_700_000_001_000; row["how"] = "origin"
        let link = try XCTUnwrap(ConversationMissionLink(json: row))
        XCTAssertEqual(link.mission.id, "ms_a1")
        XCTAssertTrue(link.isCurrent); XCTAssertTrue(link.isActive); XCTAssertFalse(link.isEarlier)
        XCTAssertEqual(link.joinedAt, Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertEqual(link.how, "origin")
    }

    /// No `active` key: an `ended_at` decides it. A closed mission's link is
    /// history even while it is still active (spec §3, "Closing a mission").
    func testLinkActivityFallsBackToEndedAtAndClosedMissionsAreEarlier() throws {
        var ended = MissionModelTests.missionJSON
        ended["ended_at"] = 1_700_000_009_000
        XCTAssertFalse(try XCTUnwrap(ConversationMissionLink(json: ended)).isActive)
        var closed = MissionModelTests.missionJSON
        closed["state"] = "closed"
        let link = try XCTUnwrap(ConversationMissionLink(json: closed))
        XCTAssertTrue(link.isActive)
        XCTAssertTrue(link.isEarlier)
    }

    private func link(_ id: String, num: Int, current: Bool = false, joined: TimeInterval? = nil,
                      ended: TimeInterval? = nil, closed: Bool = false) -> ConversationMissionLink {
        ConversationMissionLink(
            mission: Mission(id: id, num: num, state: closed ? .closed : .open, title: "M\(num)", originConvoID: "c1"),
            isCurrent: current, isActive: ended == nil,
            joinedAt: joined.map { Date(timeIntervalSince1970: $0) },
            endedAt: ended.map { Date(timeIntervalSince1970: $0) })
    }

    func testSectionsSplitCurrentAlsoOnAndEarlier() {
        let sections = ConversationMissionSections([
            link("ms_old", num: 1, joined: 1, ended: 5),
            link("ms_also", num: 2, joined: 10),
            link("ms_cur", num: 3, current: true, joined: 20),
            link("ms_newer_also", num: 4, joined: 30),
            link("ms_done", num: 5, joined: 2, closed: true),
        ])
        XCTAssertEqual(sections.current?.id, "ms_cur")
        XCTAssertEqual(sections.alsoOn.map(\.id), ["ms_newer_also", "ms_also"], "newest joined first")
        XCTAssertEqual(Set(sections.earlier.map(\.id)), ["ms_old", "ms_done"])
        XCTAssertEqual(sections.headline?.id, "ms_cur")
        XCTAssertEqual(sections.othersCount(snapshotCount: nil), 4)
    }

    /// Before `GET /conversations/:id/missions` lands, only the snapshot's
    /// `mission_count` knows the others exist.
    func testOthersCountTrustsALargerSnapshotCount() {
        let sections = ConversationMissionSections([link("ms_cur", num: 3, current: true, joined: 20)])
        XCTAssertEqual(sections.othersCount(snapshotCount: 3), 2)
        XCTAssertEqual(sections.othersCount(snapshotCount: nil), 0)
        XCTAssertEqual(ConversationMissionSections([]).othersCount(snapshotCount: 2), 0,
                       "no headline, no chip, no count")
    }

    /// No current link (the conversation left its last mission): the chip
    /// names the newest active one, else the newest earlier one.
    func testHeadlineFallsBackWhenNothingIsCurrent() {
        let sections = ConversationMissionSections([link("ms_old", num: 1, joined: 1, ended: 5)])
        XCTAssertNil(sections.current)
        XCTAssertEqual(sections.headline?.id, "ms_old")
    }
}
