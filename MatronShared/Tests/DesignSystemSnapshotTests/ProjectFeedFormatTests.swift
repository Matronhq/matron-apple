import XCTest
import MatronModels
@testable import MatronDesignSystem

/// Projects view v2's words: the card's waiting line and footer, the page's
/// meta line and roll-up counts, the milestone days and the decision marks.
final class ProjectFeedFormatTests: XCTestCase {
    typealias F = ProjectsSnapshotTests

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = F.utc
        return calendar
    }

    // MARK: Card

    func testWaitingRows() {
        let one = ProjectWaitingOn(itemID: "it_1", num: 5882, kind: .question,
                                   title: "Redrawn letters on by default,\nor per crest?")
        XCTAssertEqual(ProjectFeedFormat.waitingHeading, "Waiting on you")
        XCTAssertEqual(ProjectFeedFormat.waitingRowTitle(one), "Redrawn letters on by default, or per crest?")
        XCTAssertEqual(ProjectFeedFormat.waitingRowTrailing(one), "#5882")
        XCTAssertNil(ProjectFeedFormat.waitingMoreLine(0), "no '+0 more'")
        XCTAssertEqual(ProjectFeedFormat.waitingMoreLine(3), "+3 more")
    }

    func testCardFooter() {
        XCTAssertEqual(ProjectFeedFormat.cardFooter(openMissions: 2, sessionsNow: 14), "2 missions · 14 sessions on it now")
        XCTAssertEqual(ProjectFeedFormat.cardFooter(openMissions: 1, sessionsNow: 1), "1 mission · 1 session on it now")
        XCTAssertEqual(ProjectFeedFormat.cardFooter(openMissions: 6, sessionsNow: 0), "6 missions", "no sessions, no clause")
        XCTAssertEqual(ProjectFeedFormat.cardFooter(openMissions: 0, sessionsNow: 0), "0 missions")
    }

    func testCardDescriptionPrefersTheStatusThenTheGoal() {
        XCTAssertEqual(ProjectFeedFormat.cardDescription(Project(id: "p", num: 1, title: "T", body: "Goal", status: "Status")),
                       "Status")
        XCTAssertEqual(ProjectFeedFormat.cardDescription(Project(id: "p", num: 1, title: "T", body: "Goal")), "Goal")
        XCTAssertNil(ProjectFeedFormat.cardDescription(Project(id: "p", num: 1, title: "T", body: "  \n")))
    }

    // MARK: Page

    func testPageMetaLine() {
        XCTAssertEqual(ProjectFeedFormat.pageMetaLine(openMissions: 5, sessions: 9, boxes: 7,
                                                      lastActivityAt: F.ago(3 * 3_600), now: F.now),
                       "5 missions · 9 sessions on 7 boxes · last activity 3h ago")
        XCTAssertEqual(ProjectFeedFormat.pageMetaLine(openMissions: 1, sessions: 1, boxes: 1, lastActivityAt: nil, now: F.now),
                       "1 mission · 1 session on 1 box")
        XCTAssertEqual(ProjectFeedFormat.pageMetaLine(openMissions: 2, sessions: 3, boxes: 0, lastActivityAt: nil, now: F.now),
                       "2 missions · 3 sessions", "a single-box journal names no box")
        XCTAssertEqual(ProjectFeedFormat.pageMetaLine(openMissions: 2, sessions: 0, boxes: 0,
                                                      lastActivityAt: F.ago(30), now: F.now),
                       "2 missions · last activity just now")
    }

    func testPageMetaLineCountsTheLiveSessionsElseTheJournalsBoxes() {
        var page = ProjectDetailSnapshotTests.page
        XCTAssertEqual(ProjectFeedFormat.pageMetaLine(page, now: F.now),
                       "2 missions · 3 sessions on 3 boxes · last activity 4m ago")
        page.sessionsByMission = [:]
        XCTAssertEqual(ProjectFeedFormat.pageMetaLine(page, now: F.now),
                       "2 missions · 4 sessions on 3 boxes · last activity 4m ago", "sessions_by_box until they load")
    }

    func testFeedCount() {
        XCTAssertEqual(ProjectFeedFormat.feedCount(total: 23, missionNums: [2407, 2407, 4907, nil, 4791], complete: true),
                       "23 across 3 missions")
        XCTAssertEqual(ProjectFeedFormat.feedCount(total: 23, missionNums: [2407, 4907], complete: false),
                       "23 across 2+ missions", "more pages may name more missions")
        XCTAssertEqual(ProjectFeedFormat.feedCount(total: 1, missionNums: [2407], complete: true), "1 across 1 mission")
        XCTAssertEqual(ProjectFeedFormat.feedCount(total: 4, missionNums: [nil], complete: true), "4")
    }

    // MARK: Days

    func testDayLabel() {
        // F.now is 2027-01-15 08:00 UTC.
        XCTAssertEqual(ProjectFeedFormat.dayLabel(F.ago(3_600), now: F.now, calendar: Self.utc), "Today")
        XCTAssertEqual(ProjectFeedFormat.dayLabel(F.ago(9 * 3_600), now: F.now, calendar: Self.utc), "Yesterday")
        XCTAssertEqual(ProjectFeedFormat.dayLabel(F.ago(3 * 86_400), now: F.now, calendar: Self.utc), "12 Jan")
        XCTAssertEqual(ProjectFeedFormat.timeOfDay(F.ago(3_600 + 6 * 60), timeZone: F.utc), "06:54")
    }

    func testMilestoneDaysGroupRunsOfOneDayInOrder() {
        func row(_ id: String, _ age: TimeInterval) -> ProjectMilestone {
            ProjectMilestone(milestone: Milestone(id: id, missionID: "ms_1", num: 1, kind: .progress, title: id,
                                                  convoID: "c", seq: 1, createdAt: F.ago(age)), missionNum: 1)
        }
        let days = ProjectFeedFormat.milestoneDays(
            [row("a", 600), row("b", 7_200), row("c", 9 * 3_600), row("d", 10 * 3_600), row("e", 4 * 86_400)],
            now: F.now, calendar: Self.utc)
        XCTAssertEqual(days.map(\.label), ["Today", "Yesterday", "11 Jan"])
        XCTAssertEqual(days.map { $0.rows.map(\.id) }, [["a", "b"], ["c", "d"], ["e"]])
        XCTAssertTrue(ProjectFeedFormat.milestoneDays([], now: F.now).isEmpty)
    }

    // MARK: Decisions

    func testDecisionMark() {
        func decision(_ kind: ItemKind, _ state: ItemState, _ resolution: ItemResolution?) -> ProjectDecision {
            ProjectDecision(id: "it", num: 1, kind: kind, state: state, resolution: resolution, title: "t", createdAt: F.now)
        }
        XCTAssertEqual(ProjectDecisionMark(decision(.decision, .open, nil)), .decided, "in force")
        XCTAssertEqual(ProjectDecisionMark(decision(.decision, .closed, .decided)), .decided)
        XCTAssertEqual(ProjectDecisionMark(decision(.decision, .closed, .reversed)), .reversed)
        XCTAssertEqual(ProjectDecisionMark(decision(.question, .closed, .answered)), .answered)
        XCTAssertTrue(ProjectDecisionMark.reversed.isStruck)
        XCTAssertFalse(ProjectDecisionMark.decided.isStruck)
        XCTAssertEqual(ProjectDecisionMark.answered.symbol, "questionmark.circle.fill")
    }

    // MARK: Files

    func testFileLabels() {
        let pdf = ProjectFile(blobID: "b1", name: "Claims list.pdf", contentType: "application/pdf",
                              source: .item(num: 5090), postedAt: F.ago(2 * 86_400))
        XCTAssertEqual(ProjectFeedFormat.fileMeta(pdf, now: F.now), "#5090 · 2d")
        XCTAssertEqual(ProjectFeedFormat.fileExtension(pdf), "PDF")
        let chat = ProjectFile(blobID: "b2", contentType: "image/png", caption: "Hero: slate\nflat-lay",
                               source: .chat(convoID: "c", seq: 4), postedAt: nil)
        XCTAssertEqual(ProjectFeedFormat.fileMeta(chat, now: F.now), "chat", "no age without posted_at")
        XCTAssertEqual(ProjectFeedFormat.fileName(chat), "Hero: slate flat-lay")
        let bare = ProjectFile(blobID: "b3", contentType: "application/vnd.openxmlformats-officedocument",
                               source: .item(num: 1), postedAt: nil)
        XCTAssertEqual(ProjectFeedFormat.fileName(bare), "File")
        XCTAssertEqual(ProjectFeedFormat.fileExtension(bare), "FILE", "an unreadable subtype is not a label")
        XCTAssertEqual(ProjectFeedFormat.fileExtension(ProjectFile(blobID: "b4", contentType: "application/zip",
                                                                   source: .item(num: 1), postedAt: nil)), "ZIP")
    }
}
