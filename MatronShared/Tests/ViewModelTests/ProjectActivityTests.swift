import XCTest
import MatronModels

/// The project page's merged activity feed: what goes in, the order, the
/// horizon that holds back a kind's old rows while another kind's pages
/// are still to load, the fold and "Show more".
final class ProjectActivityTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    private static func milestone(_ num: Int, age: TimeInterval, kind: MilestoneKind = .progress) -> ProjectMilestone {
        ProjectMilestone(milestone: Milestone(id: "ml_\(num)", missionID: "ms_1", num: num, kind: kind, title: "M\(num)",
                                              convoID: "c1", seq: Int64(num), createdAt: ago(age)), missionNum: 1)
    }

    private static func decision(_ num: Int, age: TimeInterval, question: Bool = false) -> ProjectDecision {
        ProjectDecision(id: "it_\(num)", num: num, kind: question ? .question : .decision,
                        state: question ? .closed : .open, resolution: question ? .answered : nil, title: "D\(num)",
                        createdAt: question ? ago(age + 3_600) : ago(age), closedAt: question ? ago(age) : nil, missionNum: 2,
                        answer: question ? "Yes" : nil)
    }

    private static func file(_ blob: String, age: TimeInterval?) -> ProjectFile {
        ProjectFile(blobID: blob, name: "\(blob).png", contentType: "image/png", missionNum: 1,
                    source: .item(num: 9), postedAt: age.map(ago))
    }

    private static func item(_ num: Int, kind: ItemKind, awaiting: ItemAwaiting? = .user, age: TimeInterval) -> TrackerItem {
        TrackerItem(id: "it_\(num)", num: num, kind: kind, awaiting: awaiting, title: "I\(num)", originConvoID: "c1",
                    createdAt: ago(age), updatedAt: ago(age), missionID: "ms_1", missionNum: 1)
    }

    private static func page(milestones: ProjectFeedPage<ProjectMilestone> = .init(),
                             decisions: ProjectFeedPage<ProjectDecision> = .init(),
                             files: ProjectFeedPage<ProjectFile> = .init(),
                             items: [TrackerItem] = []) -> ProjectPageModel {
        ProjectPageModel(project: Project(id: "pj_1", num: 1, title: "P"), openItems: items,
                         decisions: decisions, files: files, milestonesPage: milestones, hasFeed: true)
    }

    // MARK: What goes in, and the order

    func testEventsMergeEveryKindNewestFirst() {
        let page = Self.page(
            milestones: ProjectFeedPage(rows: [Self.milestone(1, age: 60), Self.milestone(2, age: 7_200)]),
            decisions: ProjectFeedPage(rows: [Self.decision(3, age: 600, question: true), Self.decision(4, age: 86_400)]),
            files: ProjectFeedPage(rows: [Self.file("b1", age: 3_600)]),
            items: [Self.item(5, kind: .question, age: 1_800), Self.item(6, kind: .notice, awaiting: .user, age: 90_000)])
        XCTAssertEqual(ProjectActivity.events(page).map(\.id),
                       ["milestone:ml_1", "decision:it_3", "item:it_5", "file:item:9:b1", "milestone:ml_2",
                        "decision:it_4", "item:it_6"])
    }

    func testTasksAndDecisionItemsStayOutOfTheFeed() {
        let page = Self.page(items: [Self.item(1, kind: .task, awaiting: .agent, age: 10),
                                     Self.item(2, kind: .decision, awaiting: nil, age: 20),
                                     Self.item(3, kind: .question, age: 30),
                                     Self.item(4, kind: .notice, age: 40)])
        XCTAssertEqual(ProjectActivity.events(page).map(\.id), ["item:it_3", "item:it_4"],
                       "questions and notices only: tasks doubled up with their milestones, decisions have the roll-up")
    }

    func testTheSameInstantOrdersByKindThenID() {
        let page = Self.page(
            milestones: ProjectFeedPage(rows: [Self.milestone(1, age: 60)]),
            decisions: ProjectFeedPage(rows: [Self.decision(2, age: 60)]),
            files: ProjectFeedPage(rows: [Self.file("b", age: 60), Self.file("a", age: 60)]),
            items: [Self.item(3, kind: .question, age: 60)])
        XCTAssertEqual(ProjectActivity.events(page).map(\.id),
                       ["milestone:ml_1", "decision:it_2", "item:it_3", "file:item:9:a", "file:item:9:b"])
    }

    func testAFileWithNoPostedTimeSortsLast() {
        let page = Self.page(milestones: ProjectFeedPage(rows: [Self.milestone(1, age: 10 * 86_400)]),
                             files: ProjectFeedPage(rows: [Self.file("undated", age: nil)]))
        XCTAssertEqual(ProjectActivity.events(page).map(\.id), ["milestone:ml_1", "file:item:9:undated"])
    }

    func testWithoutTheRollUpTheFeedUsesTheRecentMilestones() {
        var page = Self.page(milestones: ProjectFeedPage(rows: [Self.milestone(9, age: 10)]))
        page.hasFeed = false
        page.recentMilestones = [Self.milestone(1, age: 60).milestone]
        page.missionNums = ["ms_1": 41]
        let events = ProjectActivity.events(page)
        XCTAssertEqual(events.map(\.id), ["milestone:ml_1"], "the roll-up page is not trusted without the roll-up")
        XCTAssertEqual(events.first?.missionNum, 41)
    }

    // MARK: Horizon

    func testNoHorizonWhenEveryKindIsFullyLoaded() {
        let page = Self.page(milestones: ProjectFeedPage(rows: [Self.milestone(1, age: 60)]),
                             decisions: ProjectFeedPage(rows: [Self.decision(2, age: 30 * 86_400)]))
        XCTAssertNil(ProjectActivity.horizon(page))
        XCTAssertEqual(ProjectActivity.rows(page, limit: nil).count, 2, "an old decision shows when nothing is still to load")
    }

    func testTheHorizonIsTheNewestOldestLoadedRowAmongTheKindsWithMorePages() {
        // Milestones loaded back one day with more to come; decisions loaded
        // back a month, also with more; files complete.
        let page = Self.page(
            milestones: ProjectFeedPage(rows: [Self.milestone(1, age: 60), Self.milestone(2, age: 86_400)], nextBefore: "m"),
            decisions: ProjectFeedPage(rows: [Self.decision(3, age: 3_600), Self.decision(4, age: 30 * 86_400)], nextBefore: "d"),
            files: ProjectFeedPage(rows: [Self.file("old", age: 40 * 86_400)]))
        XCTAssertEqual(ProjectActivity.horizon(page), Self.ago(86_400), "the milestones' oldest loaded row")
        XCTAssertEqual(ProjectActivity.rows(page, limit: nil).map(\.id), ["milestone:ml_1", "decision:it_3", "milestone:ml_2"],
                       "the month-old decision and the older file wait for the milestones' next page")
        XCTAssertTrue(ProjectActivity.hasMore(page, limit: nil))
        XCTAssertEqual(ProjectActivity.kindsWithMore(page), [.milestones, .decisions])
    }

    func testAKindWithMorePagesButNoRowsYetSetsNoHorizon() {
        let page = Self.page(milestones: ProjectFeedPage(rows: [], nextBefore: "m"),
                             decisions: ProjectFeedPage(rows: [Self.decision(1, age: 60)]))
        XCTAssertNil(ProjectActivity.horizon(page))
        XCTAssertEqual(ProjectActivity.rows(page, limit: nil).count, 1)
    }

    func testOpenItemsAreNeverHeldBackByTheHorizon() {
        // An open question is on the page in full, so an old one that is
        // newer than the horizon shows, and an older one waits like any
        // other row.
        let page = Self.page(
            milestones: ProjectFeedPage(rows: [Self.milestone(1, age: 3_600)], nextBefore: "m"),
            items: [Self.item(2, kind: .question, age: 60), Self.item(3, kind: .question, age: 86_400)])
        XCTAssertEqual(ProjectActivity.rows(page, limit: nil).map(\.id), ["item:it_2", "milestone:ml_1"])
    }

    // MARK: Fold and "Show more"

    func testTheFirstPageIsCutToTheLimit() {
        let rows = (1...20).map { Self.milestone($0, age: TimeInterval($0) * 60) }
        let page = Self.page(milestones: ProjectFeedPage(rows: rows))
        XCTAssertEqual(ProjectActivity.rows(page, limit: ProjectActivity.firstPageLimit).count, 12)
        XCTAssertTrue(ProjectActivity.hasMore(page, limit: 12), "eight more are already loaded")
        XCTAssertFalse(ProjectActivity.hasMore(page, limit: nil), "nothing left once every row shows")
        XCTAssertTrue(ProjectActivity.kindsWithMore(page).isEmpty)
    }

    func testHasMoreWhenEveryLoadedRowShowsButAKindHasPagesLeft() {
        let page = Self.page(files: ProjectFeedPage(rows: [Self.file("b1", age: 60)], nextBefore: "f"))
        XCTAssertEqual(ProjectActivity.rows(page, limit: 12).count, 1)
        XCTAssertTrue(ProjectActivity.hasMore(page, limit: 12))
        XCTAssertEqual(ProjectActivity.kindsWithMore(page), [.files])
    }

    // MARK: Days

    func testDaysGroupRunsOfTheSameCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let dayStart = calendar.startOfDay(for: Self.now)
        let sinceMidnight = Self.now.timeIntervalSince(dayStart)
        let events: [ProjectActivityEvent] = [
            .milestone(Self.milestone(1, age: 60)),
            .milestone(Self.milestone(2, age: sinceMidnight - 1)),
            .milestone(Self.milestone(3, age: sinceMidnight + 1)),
            .milestone(Self.milestone(4, age: sinceMidnight + 3_600)),
        ]
        let days = ProjectActivity.days(events, calendar: calendar)
        XCTAssertEqual(days.map { $0.events.count }, [2, 2])
        XCTAssertEqual(days.first?.start, dayStart)
        XCTAssertEqual(days.last?.start, calendar.date(byAdding: .day, value: -1, to: dayStart))
    }
}
