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
        XCTAssertEqual(TimelineFormat.alsoLine(1), "Also this week: 1 smaller job")
        XCTAssertEqual(TimelineFormat.alsoLine(6), "Also this week: 6 smaller jobs")
        XCTAssertEqual(TimelineFormat.earlierWeeks, "Earlier weeks")
        XCTAssertEqual(TimelineFormat.nothingFinished, "Nothing finished yet.")
    }

    /// A first title that ends a sentence starts a new one for the rest.
    func testNeedsYouAfterAQuestion() {
        func story(_ titles: String...) -> TimelineStory {
            TimelineStory(project: D.noMediaStory.project, needsYou: titles.enumerated().map {
                TimelineItemRef(id: "it_\($0.offset)", num: $0.offset, title: $0.element)
            })
        }
        XCTAssertEqual(TimelineFormat.needsYou(story("Which retry policy for uploads?", "B")),
                       "Which retry policy for uploads? And 1 more")
        XCTAssertEqual(TimelineFormat.needsYou(story("Ship it now!", "B", "C")), "Ship it now! And 2 more")
        XCTAssertEqual(TimelineFormat.needsYou(story("Approve the copy.", "B")), "Approve the copy. And 1 more")
        XCTAssertEqual(TimelineFormat.needsYou(story("Approve the copy", "B")), "Approve the copy, and 1 more")
        XCTAssertEqual(TimelineFormat.needsYou(story("Which retry policy for uploads?")), "Which retry policy for uploads?")
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

    // MARK: Project story

    private static func file(_ name: String?, _ type: String, at date: Date, item: Int? = nil) -> ProjectFile {
        ProjectFile(blobID: name ?? "blob", name: name, contentType: type,
                    source: item.map { .item(num: $0) } ?? .chat(convoID: "c_demo", seq: 1), postedAt: date)
    }

    private static func task(_ num: Int, _ title: String, kind: ItemKind = .task, state: ItemState = .open) -> TrackerItem {
        TrackerItem(id: "it_\(num)", num: num, kind: kind, state: state, title: title, originConvoID: "c_demo")
    }

    /// The Coordinator's status, else the goal, else the newest milestone.
    /// Only the goal is held to a few lines: it can run to pages.
    func testStorySentence() {
        let milestone = { (title: String, hours: Double) in
            Milestone(id: "ms_\(title)", missionID: "mi_demo", num: 1, kind: .progress, title: title,
                      convoID: "c_demo", seq: 1, createdAt: D.now.addingTimeInterval(-hours * 3_600))
        }
        var page = ProjectPageModel(project: Project(id: "pj", num: 1, title: "Docs", body: "The goal.",
                                                     status: "Where it stands."))
        XCTAssertEqual(TimelineFormat.storySentence(page), .init(text: "Where it stands.", lineLimit: nil))
        page.project = Project(id: "pj", num: 1, title: "Docs", body: "The goal.", status: "  ")
        XCTAssertEqual(TimelineFormat.storySentence(page), .init(text: "The goal.", lineLimit: 3))
        page.project = Project(id: "pj", num: 1, title: "Docs")
        XCTAssertNil(TimelineFormat.storySentence(page))
        page.recentMilestones = [milestone("Older", 5), milestone("Newest", 1)]
        XCTAssertEqual(TimelineFormat.storySentence(page), .init(text: "Newest", lineLimit: nil))
    }

    /// A goal written as a document: its first paragraph, without the
    /// heading, list and quote marks that start its lines.
    func testStorySentenceFromAGoalIsItsFirstParagraph() {
        func goal(_ body: String) -> String? {
            TimelineFormat.storySentence(ProjectPageModel(project: Project(id: "pj", num: 1, title: "Docs", body: body)))?.text
        }
        XCTAssertEqual(goal("\n# Docs site\nShip a new docs site\nwith **search**.\n\n## Later\nMore."),
                       "Docs site Ship a new docs site with **search**.")
        XCTAssertEqual(goal("- Search\n* Fast pages\n+ A guide\n> Quoted\n1. First\n\nSecond paragraph."),
                       "Search Fast pages A guide Quoted First")
        XCTAssertEqual(goal("#hashtag stays, as does -5 °C and *emphasis*."), "#hashtag stays, as does -5 °C and *emphasis*.")
        XCTAssertNil(goal("#\n- \n"))
    }

    /// The first three open tasks, as one sentence; what already waits on
    /// the user is in the card below, not here.
    func testComingUp() {
        var page = ProjectPageModel(project: Project(id: "pj", num: 1, title: "Docs"))
        XCTAssertNil(TimelineFormat.comingUp(page))
        page.openItems = [Self.task(1, "Launch")]
        XCTAssertEqual(TimelineFormat.comingUp(page), "Launch.")
        page.openItems = [Self.task(1, "A rehearsal on Monday at 07:00"), Self.task(2, "Pick a colour", kind: .question),
                          Self.task(3, "The CDN switch-over."), Self.task(4, "Waits on you"),
                          Self.task(5, "Launch"), Self.task(6, "Write the launch post")]
        page.needsYou = [Self.task(4, "Waits on you")]
        XCTAssertEqual(TimelineFormat.comingUp(page), "A rehearsal on Monday at 07:00, The CDN switch-over, then Launch.",
                       "titles as written, less a closing full stop")
        page.openItems = [Self.task(1, "CDN switch-over"), Self.task(2, "iOS build")]
        XCTAssertEqual(TimelineFormat.comingUp(page), "CDN switch-over, then iOS build.")
        XCTAssertEqual(TimelineFormat.comingUpPrefix, "Coming up:")
    }

    /// The file's caption, else the item it was posted on; never the
    /// file's name, which is rarely words.
    func testGalleryCaption() {
        let items = [Self.task(30, "Pick the docs palette", kind: .decision)]
        func file(_ name: String?, caption: String?, item: Int? = nil) -> ProjectFile {
            ProjectFile(blobID: "blob", name: name, contentType: "image/png", caption: caption,
                        source: item.map { .item(num: $0) } ?? .chat(convoID: "c_demo", seq: 1), postedAt: D.now)
        }
        XCTAssertEqual(TimelineFormat.galleryCaption(file("docs-1.png", caption: " Search page live\non staging "), items: items),
                       "Search page live on staging")
        XCTAssertEqual(TimelineFormat.galleryCaption(file("docs-1.png", caption: "Live", item: 30), items: items), "Live")
        XCTAssertEqual(TimelineFormat.galleryCaption(file("docs-1.png", caption: "  ", item: 30), items: items),
                       "Pick the docs palette")
        XCTAssertNil(TimelineFormat.galleryCaption(file("docs-1.png", caption: nil), items: items))
        XCTAssertNil(TimelineFormat.galleryCaption(file("docs-1.png", caption: nil, item: 99), items: items))
        XCTAssertNil(TimelineFormat.galleryCaption(file(nil, caption: nil), items: items))
    }

    /// Images and videos only, grouped by Monday-based week, newest first:
    /// "This week", "Last week", then the dates.
    func testGalleryWeeks() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.firstWeekday = 2
        func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }
        let files = [
            Self.file("monday.png", "image/png", at: at(11, 2, 0, 30)),
            Self.file("notes.pdf", "application/pdf", at: at(11, 3, 9)),
            Self.file("sunday.mp4", "video/mp4", at: at(11, 1, 23)),
            Self.file("older.jpg", "image/jpeg", at: at(10, 21, 12)),
            Self.file("thursday.png", "image/png", at: at(11, 5, 9)),
            ProjectFile(blobID: "undated", name: "undated.png", contentType: "image/png", source: .chat(convoID: "c", seq: 2),
                        postedAt: nil),
        ]
        let weeks = ProjectGallery.weeks(files, now: D.now, calendar: calendar)
        XCTAssertEqual(weeks.map(\.title), ["This week", "Last week", "19 – 25 Oct"])
        XCTAssertEqual(weeks.map { $0.files.map(\.name) }, [["thursday.png", "monday.png"], ["sunday.mp4"], ["older.jpg"]])
        XCTAssertTrue(ProjectGallery.weeks([files[1]], now: D.now, calendar: calendar).isEmpty)
        XCTAssertEqual(TimelineFormat.weekday(at(11, 3, 9), calendar: calendar), "Tuesday")
    }

    /// The dates are the Gregorian ones whatever the device's calendar;
    /// only the weeks are grouped in it.
    func testGalleryWeekTitleOnANonGregorianCalendar() {
        for identifier in [Calendar.Identifier.buddhist, .islamicUmmAlQura] {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = TimeZone(identifier: "Europe/London")!
            calendar.firstWeekday = 2
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: D.now)!.start
            let older = calendar.date(byAdding: .day, value: -14, to: thisWeek)!
            XCTAssertEqual(TimelineFormat.galleryWeekTitle(weekStart: older, thisWeekStart: thisWeek, calendar: calendar),
                           "19 – 25 Oct", "\(identifier)")
        }
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
        // A past week: "Last week", its dates, and its cards.
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

    /// Nothing finished yet: one calm line under the title, no rows.
    func testFinishedEmpty() {
        assertVariants(of: phone(FinishedListView(rows: [], now: D.now, onOpenProject: { _ in }, onLoadMore: nil)),
                       named: "timeline-finished-empty-phone")
    }

    private func storyPage(_ page: ProjectPageModel) -> some View {
        ProjectStoryView(page: page, now: D.now, images: Self.images, onOpenItem: { _ in }, onOpenFile: { _ in },
                         onAllDetails: {}) {
            Button("Rename…") {}
        }
    }

    /// The sentence, "Coming up", what waits on you, and the pictures and
    /// videos by week under their captions and days.
    func testProjectStory() {
        assertVariants(of: storyPage(D.docsProjectPage).frame(width: 1_280, height: 800), named: "project-story-mac")
        assertVariants(of: phone(storyPage(D.docsProjectPage)), named: "project-story-phone")
    }

    /// Nothing to show beyond the words: no gallery, no "Coming up", no
    /// waiting card; the newest milestone stands in for a status.
    func testProjectStoryNoMedia() {
        assertVariants(of: storyPage(D.quietProjectPage).frame(width: 1_280, height: 800), named: "project-story-nomedia-mac")
        assertVariants(of: phone(storyPage(D.quietProjectPage)), named: "project-story-nomedia-phone")
    }
}
