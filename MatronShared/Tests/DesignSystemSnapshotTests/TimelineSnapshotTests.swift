import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

/// The Projects weekly timeline on demo data: the Mac window (the list
/// column beside the page, 1280 × 800) and the iPhone page (390 × 844).
final class TimelineSnapshotTests: XCTestCase {
    typealias D = TimelineDemoData

    // MARK: Pure

    func testWeekRanges() {
        XCTAssertEqual(TimelineFormat.shortRange("2026-11-02"), "2 – 8 Nov")
        XCTAssertEqual(TimelineFormat.shortRange("2026-10-26"), "26 Oct – 1 Nov")
        XCTAssertEqual(TimelineFormat.shortRange("2026-12-28"), "28 Dec – 3 Jan")
        XCTAssertEqual(TimelineFormat.longRange("2026-10-26"), "26 October – 1 November")
        XCTAssertNil(TimelineFormat.shortRange("not a week"))
    }

    func testSidebarTitlesFollowTheNewestFirstOrder() {
        XCTAssertEqual(TimelineFormat.sidebarTitle(index: 0, week: "2026-11-02"), "This week")
        XCTAssertEqual(TimelineFormat.sidebarTitle(index: 1, week: "2026-10-26"), "Last week")
        XCTAssertEqual(TimelineFormat.sidebarTitle(index: 2, week: "2026-10-19"), "19 – 25 Oct")
    }

    func testPageTitles() {
        XCTAssertEqual(TimelineFormat.pageTitle(D.thisWeek, now: D.now), "This week")
        XCTAssertEqual(TimelineFormat.pageTitle(D.lastWeek, now: D.now), "Last week")
        let older = TimelineWeek(week: "2026-10-19", start: D.weeks[2].start, end: D.weeks[2].end, final: true)
        XCTAssertEqual(TimelineFormat.pageTitle(older, now: D.now), "19 – 25 October")
        XCTAssertEqual(TimelineFormat.pageDates(D.thisWeek, now: D.now), "2 – 8 November")
        XCTAssertNil(TimelineFormat.pageDates(older, now: D.now), "the title already says the dates")
    }

    func testLedes() {
        XCTAssertEqual(TimelineFormat.lede(D.thisWeek, sentence: "Sidebar line."), D.thisWeek.lede)
        let noLede = TimelineWeek(week: "2026-10-19", start: D.now, end: D.now, final: true,
                                  stories: [D.noMediaStory])
        XCTAssertEqual(TimelineFormat.lede(noLede, sentence: "Sidebar line."), "Sidebar line.")
        XCTAssertNil(TimelineFormat.lede(noLede, sentence: nil))
        XCTAssertEqual(TimelineFormat.lede(D.emptyWeek, sentence: "A quiet week."), "Nothing moved this week.")
        XCTAssertEqual(TimelineFormat.quietLede, "These were moving, then stopped without being finished.")
        XCTAssertEqual(TimelineFormat.longLede, "These have been open for three weeks or more.")
    }

    func testStoryLines() {
        XCTAssertEqual(TimelineFormat.sentence(D.noMediaStory), D.noMediaStory.sentence)
        XCTAssertEqual(TimelineFormat.sentence(TimelineStory(project: D.noMediaStory.project)), "Moved this week.")
        XCTAssertNil(TimelineFormat.needsYou(D.noMediaStory))
        let one = TimelineStory(project: D.noMediaStory.project,
                                needsYou: [TimelineItemRef(id: "it_a", num: 1, title: "Approve the copy")])
        XCTAssertEqual(TimelineFormat.needsYou(one), "Approve the copy")
        let three = TimelineStory(project: D.noMediaStory.project, needsYou: [
            TimelineItemRef(id: "it_a", num: 1, title: "Approve the copy"),
            TimelineItemRef(id: "it_b", num: 2, title: "B"), TimelineItemRef(id: "it_c", num: 3, title: "C"),
        ])
        XCTAssertEqual(TimelineFormat.needsYou(three), "Approve the copy, and 2 more")
        XCTAssertEqual(TimelineFormat.needsYouPrefix, "Needs you: ")
        XCTAssertEqual(TimelineFormat.alsoLine(1), "Also this week: 1 smaller job ›")
        XCTAssertEqual(TimelineFormat.alsoLine(6), "Also this week: 6 smaller jobs ›")
    }

    func testLastMoved() {
        func ago(_ s: TimeInterval) -> Date { D.now.addingTimeInterval(-s) }
        XCTAssertEqual(TimelineFormat.lastMoved(ago(19 * 86_400 + 600), now: D.now), "Last moved 19 days ago")
        XCTAssertEqual(TimelineFormat.lastMoved(ago(86_400 + 60), now: D.now), "Last moved yesterday")
        XCTAssertEqual(TimelineFormat.lastMoved(ago(3 * 3_600), now: D.now), "Last moved 3h ago")
        XCTAssertEqual(TimelineFormat.lastMoved(ago(10), now: D.now), "Last moved just now")
        XCTAssertNil(TimelineFormat.lastMoved(nil, now: D.now))
        XCTAssertEqual(TimelineFormat.askAction, "Ask the Coordinator what to do with it")
    }

    /// Eight weeks in, the newest seven drawn; a short series is padded
    /// with quiet weeks at the old end.
    func testChartBars() {
        XCTAssertEqual(TimelineFormat.chartBars([9, 1, 2, 3, 2, 0, 0, 0]), [1, 2, 3, 2, 0, 0, 0])
        XCTAssertEqual(TimelineFormat.chartBars([4, 5]), [0, 0, 0, 0, 0, 4, 5])
        XCTAssertEqual(TimelineFormat.chartBars([]), [0, 0, 0, 0, 0, 0, 0])
    }

    func testCardColumnsFollowThePageWidth() {
        XCTAssertEqual(TimelineWeekView<EmptyView>.columnCount(pageWidth: 390), 1)
        XCTAssertEqual(TimelineWeekView<EmptyView>.columnCount(pageWidth: 699), 1)
        XCTAssertEqual(TimelineWeekView<EmptyView>.columnCount(pageWidth: 700), 2)
        XCTAssertEqual(TimelineWeekView<EmptyView>.columnCount(pageWidth: 1_400), 2)
    }

    // MARK: Snapshots

    private static let images = D.images

    /// The Mac window less its nav column: the list column, then the page.
    private func macWindow(_ place: TimelinePlace, @ViewBuilder page: () -> some View) -> some View {
        HStack(spacing: 0) {
            sidebar(place).frame(width: 300).background(Color.primary.opacity(0.025))
            Divider()
            page()
        }
        .frame(width: 1_280, height: 800)
    }

    private func phone(_ page: some View) -> some View {
        page.frame(width: 390, height: 844)
    }

    private func sidebar(_ place: TimelinePlace) -> TimelineSidebarView {
        TimelineSidebarView(weeks: D.weeks, quietCount: D.quiet.total, longCount: D.long.total, finishedCount: 289,
                            selection: .constant(place), onLoadEarlier: {})
    }

    private func weekPage(_ week: TimelineWeek, sentence: String? = nil) -> TimelineWeekView<EmptyView> {
        TimelineWeekView(week: week, sentence: sentence, now: D.now, images: Self.images,
                         onOpenProject: { _ in }, onOpenItem: { _ in })
    }

    func testWeekWithStories() {
        assertVariants(of: macWindow(.week(D.thisWeek.week)) { weekPage(D.thisWeek) }, named: "timeline-week-mac")
        assertVariants(of: phone(weekPage(D.thisWeek)), named: "timeline-week-phone")
        // A past week, as `v4-lastweek.png`.
        assertVariants(of: macWindow(.week(D.lastWeek.week)) { weekPage(D.lastWeek) }, named: "timeline-lastweek-mac")
    }

    func testWeekEmpty() {
        let sentence = D.weeks[0].sentence
        assertVariants(of: macWindow(.week(D.emptyWeek.week)) { weekPage(D.emptyWeek, sentence: sentence) },
                       named: "timeline-week-empty-mac")
        assertVariants(of: phone(weekPage(D.emptyWeek, sentence: sentence)), named: "timeline-week-empty-phone")
    }

    /// No picture that week: no media area at all, not a grey box.
    func testStoryCardNoMedia() {
        assertVariants(of: TimelineStoryCard(story: D.noMediaStory, image: nil).frame(width: 448),
                       named: "timeline-card-nomedia-mac")
        assertVariants(of: TimelineStoryCard(story: D.noMediaStory, image: nil).frame(width: 358),
                       named: "timeline-card-nomedia-phone")
    }

    /// A video has no poster frame yet: a dark panel with ▶ and its name.
    func testStoryCardVideo() {
        let story = D.thisWeek.stories.first { $0.media?.isVideo == true }!
        assertVariants(of: TimelineStoryCard(story: story, image: nil).frame(width: 448),
                       named: "timeline-card-video-mac")
        assertVariants(of: TimelineStoryCard(story: story, image: nil).frame(width: 358),
                       named: "timeline-card-video-phone")
    }

    func testSidebar() {
        assertVariants(of: sidebar(.week(D.weeks[0].week)).frame(width: 300, height: 800), named: "timeline-sidebar-mac")
        assertVariants(of: sidebar(.quiet).frame(width: 390, height: 844), named: "timeline-sidebar-phone")
    }

    func testWentQuiet() {
        func page() -> StalledListView {
            StalledListView(title: "Went quiet", lede: TimelineFormat.quietLede, list: D.quiet, now: D.now,
                            onOpenProject: { _ in }, onAsk: { _ in })
        }
        assertVariants(of: macWindow(.quiet) { page() }, named: "timeline-quiet-mac")
        assertVariants(of: phone(page()), named: "timeline-quiet-phone")
    }

    func testFinished() {
        func page() -> FinishedListView {
            FinishedListView(rows: D.finished, now: D.now, onOpenProject: { _ in }, onLoadMore: {})
        }
        assertVariants(of: macWindow(.finished) { page() }, named: "timeline-finished-mac")
        assertVariants(of: phone(page()), named: "timeline-finished-phone")
    }
}
