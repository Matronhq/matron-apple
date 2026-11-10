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

    /// The card's sentence, and the lines the lists and the sidebar say.
    func testStoryLines() {
        XCTAssertEqual(TimelineFormat.sentence(D.noMediaStory), D.noMediaStory.sentence)
        XCTAssertEqual(TimelineFormat.sentence(TimelineStory(project: D.noMediaStory.project)), "Moved this week.")
        XCTAssertEqual(TimelineFormat.nothingMoved, "Nothing moved this week.")
        XCTAssertEqual(TimelineFormat.quietLede, "These were moving, then stopped without being finished.")
        XCTAssertEqual(TimelineFormat.longLede, "These have been open for three weeks or more.")
        XCTAssertEqual(TimelineFormat.earlierWeeks, "Earlier weeks")
        XCTAssertEqual(TimelineFormat.allProjects, "All projects")
        XCTAssertEqual(TimelineFormat.nothingFinished, "Nothing finished yet.")
    }

    /// Counts and a word, in a fixed order, only those that apply.
    func testMarksStrings() {
        XCTAssertEqual(TimelineFormat.forYouMark(1), "1 for you")
        XCTAssertEqual(TimelineFormat.forYouMark(4), "4 for you")
        XCTAssertEqual(TimelineFormat.doneMark(1), "✓ 1 done")
        XCTAssertEqual(TimelineFormat.doneMark(5), "✓ 5 done")
        XCTAssertEqual(TimelineFormat.nextMark, "→ Next")
        XCTAssertEqual(TimelineFormat.marksLabel(TimelineMarks(forYou: 2, done: 5, next: true)),
                       "2 waiting for you, 5 done, has a next step")
        XCTAssertEqual(TimelineFormat.marksLabel(TimelineMarks(forYou: 1)), "1 waiting for you")
        XCTAssertEqual(TimelineFormat.marksLabel(TimelineMarks(done: 1, next: true)), "1 done, has a next step")
        XCTAssertEqual(TimelineFormat.marksLabel(TimelineMarks(next: true)), "has a next step")
        XCTAssertNil(TimelineFormat.marksLabel(TimelineMarks()))
    }

    func testAlsoMovedLine() {
        XCTAssertNil(TimelineFormat.alsoMoved(0))
        XCTAssertEqual(TimelineFormat.alsoMoved(1), "Also moved: 1 project")
        XCTAssertEqual(TimelineFormat.alsoMoved(7), "Also moved: 7 projects")
    }

    /// Eight cards at most; the stories beyond them join the projects
    /// behind the foot line, ahead of the journal's own.
    func testCardsStopAtEight() {
        XCTAssertEqual(TimelineFormat.cards(D.thisWeek).count, D.thisWeek.stories.count)
        XCTAssertEqual(TimelineFormat.alsoMovedProjects(D.thisWeek), D.thisWeek.also)
        XCTAssertEqual(D.crowdedWeek.stories.count, 10)
        XCTAssertEqual(TimelineFormat.cards(D.crowdedWeek), Array(D.crowdedWeek.stories.prefix(8)))
        XCTAssertEqual(TimelineFormat.alsoMovedProjects(D.crowdedWeek),
                       D.crowdedWeek.stories.suffix(2).map { $0.project } + D.crowdedWeek.also)
        XCTAssertEqual(TimelineFormat.alsoMovedProjects(D.crowdedWeek).count, 7)
        XCTAssertTrue(TimelineFormat.alsoMovedProjects(D.emptyWeek).isEmpty)
    }

    func testLastMoved() {
        func ago(_ s: TimeInterval) -> Date { D.now.addingTimeInterval(-s) }
        XCTAssertEqual(TimelineFormat.lastMoved(ago(19 * 86_400 + 600), now: D.now), "Last moved 19 days ago")
        XCTAssertEqual(TimelineFormat.lastMoved(ago(86_400 + 60), now: D.now), "Last moved yesterday")
        XCTAssertEqual(TimelineFormat.lastMoved(ago(3 * 3_600), now: D.now), "Last moved 3h ago")
        XCTAssertEqual(TimelineFormat.lastMoved(ago(10), now: D.now), "Last moved just now")
        XCTAssertNil(TimelineFormat.lastMoved(nil, now: D.now))
        XCTAssertEqual(TimelineFormat.moved(ago(3 * 86_400 + 600), now: D.now), "Moved 3 days ago")
        XCTAssertEqual(TimelineFormat.moved(ago(86_400 + 60), now: D.now), "Moved yesterday")
        XCTAssertEqual(TimelineFormat.moved(ago(3 * 3_600), now: D.now), "Moved 3h ago")
        XCTAssertNil(TimelineFormat.moved(nil, now: D.now))
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

    /// Whole only past the limits: a picture at a limit still fills.
    func testMediaFit() {
        func fit(_ width: CGFloat, _ height: CGFloat) -> TimelineMediaFit {
            TimelineMediaFit.of(pixelSize: CGSize(width: width, height: height))
        }
        XCTAssertEqual(fit(240, 100), .fill)
        XCTAssertEqual(fit(360, 100), .fill)
        XCTAssertEqual(fit(361, 100), .whole)
        XCTAssertEqual(fit(133, 100), .fill)
        XCTAssertEqual(fit(132, 100), .whole)
        XCTAssertEqual(fit(2_000, 300), .whole)
        XCTAssertEqual(fit(600, 1_300), .whole)
        XCTAssertEqual(TimelineMediaFit.of(pixelSize: nil), .fill)
        XCTAssertEqual(fit(0, 0), .fill, "no size to go by")
        XCTAssertEqual(fit(100, 0), .fill)
    }

    func testDemoPicturesHaveTheirSizes() {
        XCTAssertEqual(Set(D.sizes.keys), Set(D.images.keys))
        XCTAssertEqual(D.sizes["strip"], CGSize(width: 2_000, height: 300))
        XCTAssertEqual(D.sizes["phone"], CGSize(width: 600, height: 1_300))
        XCTAssertEqual(TimelineMediaFit.of(pixelSize: D.sizes["docs"]), .fill)
    }

    // MARK: Project page

    /// The page's headings and its three rows, each with its count.
    func testProjectPageLines() {
        XCTAssertEqual(TimelineFormat.nextHeading, "Next")
        XCTAssertEqual(TimelineFormat.needsYouHeading, "Needs you")
        XCTAssertEqual(TimelineFormat.doneHeading, "Done")
        XCTAssertEqual(ProjectSection.allCases.map(TimelineFormat.sectionTitle),
                       ["This week and before", "Missions", "Files"])
        XCTAssertEqual(ProjectSection.allCases.map { TimelineFormat.sectionCount($0, page: D.summaryPage) },
                       ["6 weeks", "3 open, 4 done", "7"])
        XCTAssertEqual(TimelineFormat.weeksCount(1), "1 week")
        XCTAssertEqual(TimelineFormat.weeksCount(0), "0 weeks")
        XCTAssertEqual(TimelineFormat.missionsCount(open: 0, done: 12), "0 open, 12 done")
    }

    /// A row with nothing behind it can't be opened.
    func testProjectSectionWithNothingBehindIt() {
        let empty = TimelineProjectPage(project: D.summaryPage.project)
        XCTAssertEqual(ProjectSection.allCases.map { TimelineFormat.sectionIsEmpty($0, page: empty) }, [true, true, true])
        XCTAssertEqual(ProjectSection.allCases.map { TimelineFormat.sectionIsEmpty($0, page: D.summaryPage) },
                       [false, false, false])
        let finished = TimelineProjectPage(project: D.summaryPage.project, missionsDone: 2)
        XCTAssertFalse(TimelineFormat.sectionIsEmpty(.missions, page: finished), "done missions are still missions")
        XCTAssertEqual(ProjectSection.allCases.map { TimelineFormat.sectionIsEmpty($0, page: D.summaryPageBare) },
                       [false, false, true])
    }

    /// "and 2 more" under the items shown; nothing when they are all there.
    func testWaitingBeyondTheRowsShown() {
        XCTAssertNil(TimelineFormat.moreWaiting(D.summaryPage))
        XCTAssertEqual(D.summaryPageManyWaiting.needsYou.count, 3)
        XCTAssertEqual(TimelineFormat.moreWaiting(D.summaryPageManyWaiting), "and 2 more")
        let short = TimelineProjectPage(project: D.summaryPage.project, needsYou: D.summaryPage.needsYou, needsYouTotal: 0)
        XCTAssertNil(TimelineFormat.moreWaiting(short), "a total below the rows sent")
    }

    /// "and 2 more" opens in place once every waiting item is known: the
    /// rows the page lists stay where they are, the rest follow, and the
    /// row itself goes. Until they are known it can't be opened.
    func testAllWaitingOpensInPlace() {
        let page = D.summaryPageManyWaiting, all = D.summaryAllWaiting
        let unknown = TimelineFormat.waitingList(page, all: nil, expanded: false)
        XCTAssertEqual(unknown.rows, page.needsYou)
        XCTAssertEqual(unknown.more, "and 2 more")
        XCTAssertFalse(unknown.canExpand, "the rest are not loaded yet")
        XCTAssertEqual(TimelineFormat.waitingList(page, all: nil, expanded: true), unknown, "nothing to open onto")

        let closed = TimelineFormat.waitingList(page, all: all, expanded: false)
        XCTAssertEqual(closed.rows, page.needsYou, "the page as it was")
        XCTAssertEqual(closed.more, "and 2 more")
        XCTAssertTrue(closed.canExpand)

        let open = TimelineFormat.waitingList(page, all: all, expanded: true)
        XCTAssertEqual(open.rows.map(\.num), [51, 52, 53, 54, 55])
        XCTAssertNil(open.more)
        XCTAssertFalse(open.canExpand)

        // The full list in another order, and without one the page lists:
        // the page's rows keep their places and none is lost.
        let shuffled = [all[4], all[1], all[3]]
        XCTAssertEqual(TimelineFormat.waitingList(page, all: shuffled, expanded: true).rows.map(\.num), [51, 52, 53, 55, 54])

        // A full list with nothing the page doesn't show opens onto nothing.
        let same = TimelineFormat.waitingList(page, all: page.needsYou, expanded: true)
        XCTAssertEqual(same.rows, page.needsYou)
        XCTAssertEqual(same.more, "and 2 more")
        XCTAssertFalse(same.canExpand)

        // Everything listed: no row, opened or not.
        let whole = TimelineFormat.waitingList(D.summaryPage, all: D.summaryPage.needsYou, expanded: false)
        XCTAssertEqual(whole.rows, D.summaryPage.needsYou)
        XCTAssertNil(whole.more)
        XCTAssertFalse(whole.canExpand)
    }

    /// The week being lived is this week, the one before it last week,
    /// any other its dates.
    func testHistoryWeekTitles() {
        XCTAssertEqual(D.history.map { TimelineFormat.historyWeekTitle($0, now: D.now) },
                       ["This week", "Last week", "19 – 25 Oct"])
        XCTAssertNil(TimelineFormat.moreMilestones(0))
        XCTAssertEqual(TimelineFormat.moreMilestones(1), "1 more")
        XCTAssertEqual(TimelineFormat.moreMilestones(4), "4 more")
    }

    func testFileColumnsFollowThePageWidth() {
        XCTAssertEqual(ProjectFilesGridView.columnCount(pageWidth: 390), 2)
        XCTAssertEqual(ProjectFilesGridView.columnCount(pageWidth: 699), 2)
        XCTAssertEqual(ProjectFilesGridView.columnCount(pageWidth: 700), 3)
        XCTAssertEqual(ProjectFilesGridView.columnCount(pageWidth: 1_280), 3)
    }

    func testWeekday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9))!
        XCTAssertEqual(TimelineFormat.weekday(tuesday, calendar: calendar), "Tuesday")
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
        TimelineSidebarView(weeks: D.weeks, projectsCount: D.allProjects.total, quietCount: D.quiet.total,
                            longCount: D.long.total, finishedCount: 289, selection: .constant(place), onLoadEarlier: {})
    }

    private func weekPage(_ week: TimelineWeek) -> TimelineWeekView<EmptyView> {
        TimelineWeekView(week: week, now: D.now, images: Self.images, sizes: D.sizes, onOpenProject: { _ in })
    }

    /// A card at a Mac column's width and at the iPhone page's.
    private func assertCard(_ story: TimelineStory, named name: String, file: StaticString = #file,
                            testName: String = #function, line: UInt = #line) {
        func card() -> TimelineStoryCard {
            TimelineStoryCard(story: story, image: story.media.flatMap { Self.images[$0.blobID] },
                              pixelSize: story.media.flatMap { D.sizes[$0.blobID] })
        }
        assertVariants(of: card().frame(width: 448), named: "\(name)-mac", file: file, testName: testName, line: line)
        assertVariants(of: card().frame(width: 358), named: "\(name)-phone", file: file, testName: testName, line: line)
    }

    func testWeekWithStories() {
        assertVariants(of: macWindow(.week(D.thisWeek.week)) { weekPage(D.thisWeek) }, named: "timeline-week-mac")
        assertVariants(of: phone(weekPage(D.thisWeek)), named: "timeline-week-phone")
        // A past week: "Last week", its dates, and its cards.
        assertVariants(of: macWindow(.week(D.lastWeek.week)) { weekPage(D.lastWeek) }, named: "timeline-lastweek-mac")
    }

    /// Nothing moved: the title, the dates and one calm line.
    func testWeekEmpty() {
        assertVariants(of: macWindow(.week(D.emptyWeek.week)) { weekPage(D.emptyWeek) }, named: "timeline-week-empty-mac")
        assertVariants(of: phone(weekPage(D.emptyWeek)), named: "timeline-week-empty-phone")
    }

    /// Ten stories: eight cards, and the other two counted with the five
    /// projects behind "Also moved: 7 projects". Tall enough to show the foot.
    func testWeekMoreThanEightCards() {
        assertVariants(of: weekPage(D.crowdedWeek).frame(width: 980, height: 1_500), named: "timeline-week-crowded-mac")
        assertVariants(of: weekPage(D.crowdedWeek).frame(width: 390, height: 2_900), named: "timeline-week-crowded-phone")
    }

    /// Waiting on you, done and a next step: all three marks, in that order.
    func testCardAllMarks() {
        assertCard(D.allMarksStory, named: "timeline-card-marks")
    }

    /// Where the three marks do not fit on a line (large text, a narrow
    /// card) they stack, none cut short.
    func testMarksStackWhereTheLineDoesNotFit() {
        assertVariants(of: TimelineMarksLine(marks: D.allMarksStory.marks).padding(12)
                        .frame(width: 150, alignment: .leading),
                       named: "timeline-marks-narrow")
    }

    /// Nothing to mark: the card ends at its sentence, with no empty line.
    func testCardNoMarks() {
        assertCard(D.noMarksStory, named: "timeline-card-nomarks")
    }

    /// No picture that week: no media area at all, not a grey box.
    func testCardNoMedia() {
        assertCard(D.noMediaStory, named: "timeline-card-nomedia")
    }

    /// A video has no poster frame yet: a dark panel with ▶ and its name.
    func testCardVideo() {
        assertCard(D.thisWeek.stories.first { $0.media?.isVideo == true }!, named: "timeline-card-video")
    }

    /// The media area at a Mac card's width, with the window showing round
    /// it: a picture alone draws the same in light and dark.
    private func mediaView(_ blobID: String) -> some View {
        TimelineMediaView(media: TimelineMedia(blobID: blobID, contentType: "image/png", name: "\(blobID).png"),
                          image: Self.images[blobID], pixelSize: D.sizes[blobID])
            .frame(width: 448)
            .padding(16)
    }

    /// A very wide picture: all of it, on a blurred, darkened copy of itself.
    func testMediaWideShownWhole() {
        assertVariants(of: mediaView("strip"), named: "timeline-media-wide")
    }

    /// A tall phone shot: all of it, centred on its own blur.
    func testMediaTallShownWhole() {
        assertVariants(of: mediaView("phone"), named: "timeline-media-tall")
    }

    /// A picture near the area's own shape fills it, cropped.
    func testMediaNormalFills() {
        assertVariants(of: mediaView("docs"), named: "timeline-media-normal")
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

    /// Every project, the most recently moved first, with when it moved.
    func testAllProjects() {
        func page() -> AllProjectsListView {
            AllProjectsListView(list: D.allProjects, now: D.now, onOpenProject: { _ in }, onLoadMore: {})
        }
        assertVariants(of: macWindow(.projects) { page() }, named: "timeline-projects-mac")
        assertVariants(of: phone(page()), named: "timeline-projects-phone")
    }

    func testFinished() {
        func page() -> FinishedListView {
            FinishedListView(rows: D.finished, now: D.now, onOpenProject: { _ in }, onLoadMore: {})
        }
        assertVariants(of: macWindow(.finished) { page() }, named: "timeline-finished-mac")
        assertVariants(of: phone(page()), named: "timeline-finished-phone")
    }

    /// Nothing finished yet: one calm line under the title, no rows.
    func testFinishedEmpty() {
        assertVariants(of: phone(FinishedListView(rows: [], now: D.now, onOpenProject: { _ in }, onLoadMore: nil)),
                       named: "timeline-finished-empty-phone")
    }

    // MARK: Project page

    private func summary(_ page: TimelineProjectPage, allWaiting: [TimelineItemRef]? = nil,
                         showsAllWaiting: Bool = false) -> some View {
        ProjectSummaryView(page: page, image: page.media.flatMap { Self.images[$0.blobID] },
                           pixelSize: page.media.flatMap { D.sizes[$0.blobID] },
                           allWaiting: allWaiting, showsAllWaiting: showsAllWaiting,
                           onOpenItem: { _ in }, onOpenSection: { _ in }) {
            ProjectActionsMenu(isOpen: page.isOpen, isLoaded: true, unfiled: D.docsProjectPage.closedMissions,
                               mergeTargets: [],
                               onAddMission: { _ in }, onAsk: {}, onRename: {}, onMerge: { _ in }, onClose: {})
        }
    }

    private func assertPage(_ page: () -> some View, named name: String, file: StaticString = #file,
                            testName: String = #function, line: UInt = #line) {
        assertVariants(of: page().frame(width: 1_280, height: 800), named: "\(name)-mac", file: file, testName: testName,
                       line: line)
        assertVariants(of: phone(page()), named: "\(name)-phone", file: file, testName: testName, line: line)
    }

    /// The picture, the name, where it stands, what is next, what waits on
    /// you, then the three rows that open the detail.
    func testProjectSummary() {
        assertPage({ summary(D.summaryPage) }, named: "project-summary")
    }

    /// Nothing but the name and the rows: no picture area, no sentence, no
    /// "Next", no "Needs you"; a row with nothing behind it is dimmed.
    func testProjectSummaryBare() {
        assertPage({ summary(D.summaryPageBare) }, named: "project-summary-bare")
    }

    /// More waiting than the page lists: "and 2 more" under the rows, which
    /// opens downwards. Its very wide picture is shown whole.
    func testProjectSummaryManyWaiting() {
        assertPage({ summary(D.summaryPageManyWaiting, allWaiting: D.summaryAllWaiting) },
                   named: "project-summary-waiting")
    }

    /// Before the rest are known "and 2 more" only counts them: no mark
    /// says it opens.
    func testProjectSummaryManyWaitingNotLoaded() {
        assertPage({ summary(D.summaryPageManyWaiting) }, named: "project-summary-waiting-unloaded")
    }

    /// "and 2 more" opened: every waiting item, and no row counting more.
    func testProjectSummaryAllWaiting() {
        assertPage({ summary(D.summaryPageManyWaiting, allWaiting: D.summaryAllWaiting, showsAllWaiting: true) },
                   named: "project-summary-waiting-all")
    }

    /// Week by week: the card's sentence and picture when there was one,
    /// then that week's milestones, one line each.
    func testProjectHistory() {
        assertPage({
            ProjectHistoryView(weeks: D.history, now: D.now, images: Self.images, sizes: D.sizes, hasMore: true,
                               onOpenMilestone: { _ in }, onLoadMore: {})
        }, named: "project-history")
    }

    /// Open missions by name and status, then the finished ones under "Done".
    func testProjectMissions() {
        assertPage({
            ProjectMissionsListView(open: D.docsProjectPage.missions, closed: D.docsProjectPage.closedMissions,
                                    now: D.now, onOpenMission: { _ in })
        }, named: "project-missions")
    }

    /// Pictures, a video and a document: three to a row, two on a phone.
    func testProjectFiles() {
        assertPage({
            ProjectFilesGridView(files: D.docsProjectPage.files.rows, images: Self.images, now: D.now, hasMore: false,
                                 onOpenFile: { _ in }, onLoadMore: {})
        }, named: "project-files")
    }
}
