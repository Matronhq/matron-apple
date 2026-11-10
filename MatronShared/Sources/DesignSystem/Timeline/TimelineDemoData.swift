#if DEBUG
import SwiftUI
import CoreGraphics
import MatronModels

/// Made-up weeks, cards and lists for previews and snapshot tests, with
/// pictures drawn in code. Nothing here comes from a real account.
public enum TimelineDemoData {
    /// Thursday 5 November 2026, 15:00 in London.
    public static let now = london(2026, 11, 5, hour: 15)

    public static let weeks: [TimelineWeekSummary] = [
        summary("2026-11-02", "Docs site got search; offline mode in beta.", moved: 9),
        summary("2026-10-26", "Themes reached sepia; cropper passed the samples.", moved: 7),
        summary("2026-10-19", "Offline browsing started; docs site design signed off.", moved: 6),
        summary("2026-10-12", "A quiet week: mostly fixes and tidying.", moved: 3),
        summary("2026-10-05", "Push notifications pilot shipped to TestFlight.", moved: 5),
    ]

    // MARK: Projects

    static let docs = project(1, "Docs site launch")
    static let themes = project(2, "Themes")
    static let offline = project(3, "Offline mode")
    static let cropper = project(4, "Image cropper")
    static let billing = project(5, "Billing export")
    static let audit = project(6, "Accessibility audit")
    static let onboarding = project(7, "Onboarding checklist refresh")
    static let mobileSearch = project(8, "Search in the mobile apps")

    // MARK: Weeks

    public static let thisWeek = week(
        "2026-11-02", final: false,
        stories: [
            TimelineStory(project: mobileSearch, sentence: "Search works in both apps now, with recent searches kept on the phone.",
                          media: image("phone", "search-phone.png"), marks: TimelineMarks(forYou: 2)),
            TimelineStory(project: themes, sentence: "All fifteen themes now come in sepia and high contrast.",
                          media: image("strip", "theme-strip.png"), marks: TimelineMarks(forYou: 1, done: 1, next: true)),
            TimelineStory(project: docs, sentence: "Search is live on staging, and pages now load in under a second.",
                          media: image("docs", "docs-search.png"), marks: TimelineMarks(done: 4, next: true)),
            TimelineStory(project: offline, sentence: "You can now read everything with no signal. It’s in the beta build.",
                          media: TimelineMedia(blobID: "offline-video", contentType: "video/mp4", name: "offline-reading.mp4"),
                          marks: TimelineMarks(forYou: 4)),
        ],
        also: [project(20, "Release notes"), project(21, "Crash reporting"), project(22, "Settings search"),
               project(23, "Font picker"), project(24, "Keyboard shortcuts")])

    public static let lastWeek = week(
        "2026-10-26", final: true,
        stories: [
            TimelineStory(project: themes, sentence: "Sepia variants rendered for the first eight themes.",
                          media: image("themes", "sepia.png"), marks: TimelineMarks(done: 2, next: true)),
            TimelineStory(project: cropper, sentence: "It passed the full sample set for the first time.",
                          media: image("cropper", "samples.png"), marks: TimelineMarks(forYou: 1, next: true)),
            TimelineStory(project: docs, sentence: "Pages got faster: 2.1 s down to 0.8 s.",
                          media: image("chart", "load-times.png"), marks: TimelineMarks(done: 3)),
            TimelineStory(project: billing, sentence: "The CSV export works for one account type.",
                          media: image("billing", "export.png"), marks: TimelineMarks()),
        ],
        also: [project(21, "Crash reporting"), project(25, "Onboarding emails")])

    /// A new user's first week: nothing has moved.
    public static let emptyWeek = week("2026-11-02", final: false, stories: [], also: [])

    /// A busy week: ten projects with something to say and five more that
    /// moved. The page shows eight cards; the rest sit behind its foot line.
    public static let crowdedWeek = week(
        "2026-11-02", final: false,
        stories: thisWeek.stories + [
            TimelineStory(project: cropper, sentence: "Smart crop now handles rounded corners.",
                          media: image("cropper", "rounded-corners.png"), marks: TimelineMarks(forYou: 1)),
            noMediaStory,
            TimelineStory(project: billing, sentence: "The CSV export works for one account type.",
                          media: image("billing", "export.png"), marks: TimelineMarks(done: 1)),
            TimelineStory(project: onboarding, sentence: "Copy was drafted for all six steps.",
                          media: image("chart", "steps.png"), marks: TimelineMarks(next: true)),
            TimelineStory(project: project(9, "Push notifications"), sentence: "The pilot went out to the beta group.",
                          marks: TimelineMarks(done: 2)),
            TimelineStory(project: project(10, "Sign in with a passkey"), sentence: "Passkeys work on the web.",
                          marks: TimelineMarks()),
        ],
        also: thisWeek.also)

    /// A card with no picture or video that week.
    public static let noMediaStory = TimelineStory(
        project: audit, sentence: "The report was written and two fixes went in.",
        marks: TimelineMarks(done: 2, next: true))

    /// A card with every mark: items waiting, items done, a next step.
    public static let allMarksStory = TimelineStory(
        project: docs, sentence: "Search is live on staging, and pages now load in under a second.",
        media: image("docs", "docs-search.png"), marks: TimelineMarks(forYou: 2, done: 5, next: true))

    /// A card with nothing to mark: it ends at its sentence.
    public static let noMarksStory = TimelineStory(
        project: billing, sentence: "The CSV export works for one account type.",
        media: image("billing", "export.png"), marks: TimelineMarks())

    // MARK: Lists

    public static let quiet = StalledList(total: 5, rows: [
        StalledProject(project: billing, lastMovedAt: daysAgo(19), weekly: [0, 1, 2, 3, 2, 0, 0, 0],
                       note: "Was moving well three weeks ago: CSV export works for one account type. "
                           + "Nothing since, and no-one is asking anything."),
        StalledProject(project: audit, lastMovedAt: daysAgo(24), weekly: [0, 0, 1, 3, 1, 0, 0, 0],
                       note: "The report was written and two fixes went in. The rest were planned but haven’t started."),
        StalledProject(project: onboarding, lastMovedAt: daysAgo(15), weekly: [0, 0, 0, 1, 2, 1, 0, 0],
                       note: "Copy was drafted and screenshots were next. It stopped when the docs site took over."),
        StalledProject(project: mobileSearch, lastMovedAt: daysAgo(31), weekly: [0, 2, 2, 1, 0, 0, 0, 0]),
    ])

    public static let long = StalledList(total: 7, rows: [
        StalledProject(project: offline, lastMovedAt: daysAgo(1), createdAt: daysAgo(64), weekly: [2, 3, 1, 4, 2, 3, 5, 4]),
        StalledProject(project: themes, lastMovedAt: daysAgo(2), createdAt: daysAgo(40), weekly: [0, 1, 3, 2, 4, 3, 2, 3]),
        StalledProject(project: billing, lastMovedAt: daysAgo(19), createdAt: daysAgo(35), weekly: [0, 1, 2, 3, 2, 0, 0, 0]),
    ])

    /// Every project, the most recently moved first: one page of many.
    public static let allProjects = TimelineProjectList(total: 34, rows: [
        (docs, 0.1), (themes, 0.5), (offline, 1), (mobileSearch, 1), (cropper, 3), (project(20, "Release notes"), 4),
        (project(21, "Crash reporting"), 6), (onboarding, 15), (billing, 19), (audit, 24),
    ].map { TimelineProjectRow(project: $0.0, lastMovedAt: daysAgo($0.1), openMissions: 1) }
        + [TimelineProjectRow(project: project(26, "Printable invoices"))], nextBefore: "demo")

    public static let finished: [FinishedProject] = [
        ("Push notifications pilot", 2), ("Sign in with a passkey", 4), ("Dark mode for the web app", 9),
        ("Faster app launch", 13), ("Export to PDF", 21), ("New onboarding screens", 30),
        ("Shared links", 44), ("Usage meter", 61),
    ].enumerated().map { index, row in
        FinishedProject(project: project(40 + index, row.0), finishedAt: daysAgo(row.1))
    }

    // MARK: A project's page

    /// "Docs site launch" as its page: a picture, where it stands, what is
    /// next, one question waiting, and something behind each of its rows.
    public static let summaryPage = TimelineProjectPage(
        project: docs, isLive: true,
        sentence: "Search is live on staging, pages load in under a second, and the getting-started guide is drafted.",
        next: "A rehearsal on Monday, then the switch-over and launch on Wednesday 11 November.",
        needsYou: [TimelineItemRef(id: "it_demo_11", num: 11, title: "Approve the getting-started copy")],
        media: image("docs", "docs-search.png"), weeks: 6, missionsOpen: 3, missionsDone: 4, files: 7)

    /// A project with only its name to show: no picture, no sentence, no
    /// next step, nothing waiting, and no files.
    public static let summaryPageBare = TimelineProjectPage(
        project: audit, isLive: true, weeks: 2, missionsOpen: 1, missionsDone: 0, files: 0)

    /// Five items wait and the page lists three; its picture is a very
    /// wide strip.
    public static let summaryPageManyWaiting = TimelineProjectPage(
        project: themes, isLive: true,
        sentence: "All fifteen themes now come in sepia and high contrast.",
        next: "Once you pick the default, the themes go out in the next build.",
        needsYou: [TimelineItemRef(id: "it_demo_51", num: 51, title: "Pick the default theme"),
                   TimelineItemRef(id: "it_demo_52", num: 52, title: "Approve the high-contrast palette"),
                   TimelineItemRef(id: "it_demo_53", num: 53, title: "Should sepia follow the system’s night mode?")],
        needsYouTotal: 5, media: image("strip", "theme-strip.png"), weeks: 9, missionsOpen: 2, missionsDone: 11, files: 24)

    /// Three weeks of "Docs site launch": this week with its card and more
    /// milestones than it lists, last week with a sentence and no picture,
    /// and an older week the project moved in without a card.
    public static let history: [TimelineHistoryWeek] = [
        historyWeek("2026-11-02", sentence: "Search is live on staging, and pages now load in under a second.",
                    media: image("docs", "docs-search.png"),
                    milestones: [(61, "Search page live on staging", day(11, 4, 11)),
                                 (60, "Pages load in 0.8 s, down from 2.1 s", day(11, 3, 16)),
                                 (59, "Launch checklist written", day(11, 2, 10))],
                    more: 4),
        historyWeek("2026-10-26", sentence: "The getting-started guide was drafted and the themes page filmed.",
                    milestones: [(52, "Getting-started guide drafted", day(10, 30, 12)),
                                 (51, "Themes walkthrough recorded", day(10, 29, 14))]),
        historyWeek("2026-10-19",
                    milestones: [(44, "Docs colour palette chosen", day(10, 21, 9))]),
    ]

    private static func historyWeek(_ key: String, sentence: String? = nil, media: TimelineMedia? = nil,
                                    milestones: [(num: Int, title: String, at: Date)], more: Int = 0) -> TimelineHistoryWeek {
        let bounds = monday(key)
        return TimelineHistoryWeek(
            week: key, start: bounds.start, end: bounds.end, sentence: sentence, media: media,
            milestones: milestones.map {
                ProjectMilestone(milestone: Milestone(id: "ms_demo_\($0.num)", missionID: "mi_demo_1", num: $0.num,
                                                      kind: .progress, title: $0.title, convoID: "c_demo_1",
                                                      seq: Int64($0.num), createdAt: $0.at),
                                 missionNum: 71)
            },
            moreMilestones: more)
    }

    private static func mission(_ num: Int, _ title: String, status: String? = nil, closed summary: String? = nil,
                                closedDaysAgo: Double? = nil) -> Mission {
        Mission(id: "mi_demo_\(num)", num: num, state: closedDaysAgo == nil ? .open : .closed, title: title,
                closeSummary: summary, originConvoID: "c_demo_\(num)", createdAt: daysAgo(30), updatedAt: daysAgo(1),
                closedAt: closedDaysAgo.map(daysAgo), status: status, projectID: docs.id, projectNum: docs.num)
    }

    // MARK: A project's story

    /// "Docs site launch" in full: a status, three tasks coming up, one
    /// question waiting, open and finished missions, and pictures, a video
    /// and a document over three weeks.
    public static let docsProjectPage: ProjectPageModel = {
        let tasks = [task(31, "A rehearsal on Monday at 07:00"), task(32, "The CDN switch-over"), task(33, "Launch"),
                     task(34, "Write the launch post")]
        let palette = task(35, "Pick the docs colour palette", kind: .decision)
        let waiting = [task(11, "Approve the getting-started copy", kind: .question)]
        let files = [
            file("docs", "docs-search.png", day(11, 3, 11), caption: "Search page live on staging"),
            file("chart", "load-times.png", day(11, 2, 16), caption: "Pages load in 0.8 s, down from 2.1 s"),
            file("handbook", "launch-checklist.pdf", day(11, 2, 10), type: "application/pdf"),
            file("docs", "docs-guide.png", day(10, 30, 12), caption: "Getting-started guide drafted"),
            file("themes-video", "docs-themes.mp4", day(10, 29, 14), type: "video/mp4"),
            file("themes", "palette.png", day(10, 21, 9), source: .item(num: palette.num)),
            file("not-loaded-yet", "IMG_0412.png", day(10, 20, 17)),
        ]
        let open = [
            mission(71, "Search on the docs site", status: "Live on staging; the index rebuilds on every publish."),
            mission(72, "Getting-started guide", status: "Drafted. The copy waits on your approval."),
            mission(73, "Launch day"),
        ]
        let closed = [
            mission(64, "Faster pages", closed: "Pages load in 0.8 s, down from 2.1 s.", closedDaysAgo: 3),
            mission(58, "Docs colour palette", closed: "The palette was chosen and applied.", closedDaysAgo: 14),
            mission(55, "Move the old pages across", closedDaysAgo: 20),
        ]
        return ProjectPageModel(
            project: Project(id: docs.id, num: docs.num, title: docs.title,
                             body: "Ship a new docs site with search.",
                             status: "A new docs site with search, live on Wednesday 11 November. It’s on track: "
                                 + "search works, pages are fast, and the getting-started guide is drafted."),
            missions: open.map { MissionRowModel(mission: $0, activity: .idle, lastActivity: daysAgo(1)) },
            closedMissions: closed,
            needsYou: waiting, openItems: waiting + tasks + [palette],
            files: ProjectFeedPage(total: files.count, rows: files), hasFeed: true)
    }()

    /// A project with nothing to show beyond words: no status or goal (the
    /// newest milestone speaks for it), nothing coming up or waiting, and
    /// only a document among its files.
    public static let quietProjectPage: ProjectPageModel = {
        let milestones = [
            Milestone(id: "ms_demo_2", missionID: "mi_demo_6", num: 2, kind: .progress,
                      title: "The report was written and two fixes went in.", convoID: "c_demo_6", seq: 2,
                      createdAt: day(10, 22, 10)),
            Milestone(id: "ms_demo_1", missionID: "mi_demo_6", num: 1, kind: .progress,
                      title: "Audit started.", convoID: "c_demo_6", seq: 1, createdAt: day(10, 12, 10)),
        ]
        return ProjectPageModel(
            project: Project(id: audit.id, num: audit.num, title: audit.title),
            openItems: [task(41, "Should we cover the web app too?", kind: .question)],
            recentMilestones: milestones,
            files: ProjectFeedPage(total: 1, rows: [file("report", "audit-report.pdf", day(10, 22, 9),
                                                         type: "application/pdf")]),
            hasFeed: true)
    }()

    private static func task(_ num: Int, _ title: String, kind: ItemKind = .task) -> TrackerItem {
        TrackerItem(id: "it_demo_\(num)", num: num, kind: kind, title: title, originConvoID: "c_demo",
                    createdAt: daysAgo(3), updatedAt: daysAgo(3))
    }

    private static func file(_ blobID: String, _ name: String?, _ postedAt: Date, type: String = "image/png",
                             caption: String? = nil, source: ProjectFileSource? = nil) -> ProjectFile {
        ProjectFile(blobID: blobID, name: name, contentType: type, caption: caption,
                    source: source ?? .chat(convoID: "c_demo_1", seq: Int64(postedAt.timeIntervalSince1970)),
                    postedAt: postedAt)
    }

    private static func day(_ month: Int, _ day: Int, _ hour: Int) -> Date {
        london(2026, month, day, hour: hour)
    }

    // MARK: Pictures

    /// The pictures the stories name, by blob id, drawn in code; with
    /// them a very wide strip and a tall phone shot.
    public static var images: [String: Image] {
        var images: [String: Image] = [:]
        for (id, size, draw) in pictures {
            if let cgImage = picture(size, draw) { images[id] = Image(decorative: cgImage, scale: 2) }
        }
        return images
    }

    /// Each picture's size in pixels, by blob id.
    public static var sizes: [String: CGSize] {
        Dictionary(uniqueKeysWithValues: pictures.map { ($0.id, $0.size) })
    }

    private static let pictureSize = CGSize(width: 960, height: 400)

    private static var pictures: [(id: String, size: CGSize, draw: (CGContext, CGSize) -> Void)] {
        [("docs", pictureSize, drawDocs), ("themes", pictureSize, drawThemes), ("cropper", pictureSize, drawCropper),
         ("chart", pictureSize, drawChart), ("billing", pictureSize, drawBilling),
         ("strip", CGSize(width: 2_000, height: 300), drawStrip), ("phone", CGSize(width: 600, height: 1_300), drawPhone)]
    }

    private static func picture(_ size: CGSize, _ draw: (CGContext, CGSize) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Draw top-down, as a page reads.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        draw(context, size)
        return context.makeImage()
    }

    private static func rgb(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func fill(_ context: CGContext, _ rect: CGRect, _ hex: UInt32, radius: CGFloat = 0) {
        context.setFillColor(rgb(hex))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    private static func gradient(_ context: CGContext, _ colors: [UInt32], from: CGPoint, to: CGPoint) {
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(rgb) as CFArray,
                                  locations: nil)!
        context.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// A web page: dark header, grey side panel, lines of text.
    private static func drawDocs(_ context: CGContext, _ size: CGSize) {
        fill(context, CGRect(origin: .zero, size: size), 0xFFFFFF)
        fill(context, CGRect(x: 0, y: 0, width: size.width, height: 52), 0x1F2937)
        fill(context, CGRect(x: 0, y: 52, width: 230, height: size.height - 52), 0xF3F4F6)
        for (row, width) in [560, 500, 440, 380, 320].enumerated() {
            fill(context, CGRect(x: 290, y: 100 + CGFloat(row) * 44, width: CGFloat(width), height: 16), 0xD1D5DB, radius: 4)
        }
    }

    /// Twelve theme swatches.
    private static func drawThemes(_ context: CGContext, _ size: CGSize) {
        fill(context, CGRect(origin: .zero, size: size), 0xF3F4F6)
        let colors: [UInt32] = [0x1F2937, 0xF9FAFB, 0xFDE68A, 0x93C5FD, 0x111827, 0xE5E7EB, 0xFCA5A5, 0x86EFAC,
                                0x312E81, 0xFEF3C7, 0xA78BFA, 0x5EEAD4]
        let gap: CGFloat = 10
        let width = (size.width - 5 * gap) / 4, height = (size.height - 4 * gap) / 3
        for (index, color) in colors.enumerated() {
            let x = gap + CGFloat(index % 4) * (width + gap), y = gap + CGFloat(index / 4) * (height + gap)
            fill(context, CGRect(x: x, y: y, width: width, height: height), color, radius: 8)
        }
    }

    /// A photo with its crop marked.
    private static func drawCropper(_ context: CGContext, _ size: CGSize) {
        gradient(context, [0x4F7396, 0x9C8A5A, 0x8B4A2E], from: .zero, to: CGPoint(x: size.width, y: size.height))
        let crop = CGRect(x: size.width * 0.2, y: size.height * 0.15, width: size.width * 0.6, height: size.height * 0.7)
        context.saveGState()
        context.clip(to: crop)
        gradient(context, [0xA9C1C4, 0xF0C374, 0xD98D52], from: crop.origin, to: CGPoint(x: crop.maxX, y: crop.maxY))
        context.restoreGState()
        context.setStrokeColor(rgb(0xFFFFFF))
        context.setLineWidth(4)
        context.stroke(crop)
    }

    /// Page load times falling, as a bar chart.
    private static func drawChart(_ context: CGContext, _ size: CGSize) {
        fill(context, CGRect(origin: .zero, size: size), 0xFFFFFF)
        for (index, height) in [70, 100, 92, 140, 170, 200].enumerated() {
            let x = 120 + CGFloat(index) * 130
            fill(context, CGRect(x: x, y: size.height - 80 - CGFloat(height), width: 84, height: CGFloat(height)), 0x2F7CF6)
        }
    }

    /// A spreadsheet export on a dark desk.
    private static func drawBilling(_ context: CGContext, _ size: CGSize) {
        fill(context, CGRect(origin: .zero, size: size), 0x141414)
        let page = CGRect(x: size.width / 2 - 200, y: 24, width: 400, height: size.height - 48)
        fill(context, page, 0xFFFFFF, radius: 14)
        fill(context, CGRect(x: page.minX + 24, y: page.minY + 30, width: page.width - 48, height: 36), 0xFDEBC8, radius: 6)
        for row in 0..<6 {
            fill(context, CGRect(x: page.minX + 32, y: page.minY + 100 + CGFloat(row) * 38, width: page.width - 64, height: 14),
                 0xE5E7EB, radius: 4)
        }
    }

    /// A very wide strip: a toolbar of coloured tabs end to end.
    private static func drawStrip(_ context: CGContext, _ size: CGSize) {
        fill(context, CGRect(origin: .zero, size: size), 0x1F2937)
        let colors: [UInt32] = [0x2F7CF6, 0xF0C374, 0x86EFAC, 0xFCA5A5, 0xA78BFA, 0x5EEAD4, 0xFDE68A, 0x93C5FD]
        let gap: CGFloat = 24
        let width = (size.width - CGFloat(colors.count + 1) * gap) / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            let x = gap + CGFloat(index) * (width + gap)
            fill(context, CGRect(x: x, y: 40, width: width, height: size.height - 80), color, radius: 18)
            fill(context, CGRect(x: x + 28, y: size.height / 2 - 10, width: width - 56, height: 20), 0xFFFFFF, radius: 6)
        }
    }

    /// A tall phone shot: a coloured header over a list of rows.
    private static func drawPhone(_ context: CGContext, _ size: CGSize) {
        fill(context, CGRect(origin: .zero, size: size), 0xFFFFFF)
        gradient(context, [0x312E81, 0x2F7CF6], from: .zero, to: CGPoint(x: size.width, y: 0))
        fill(context, CGRect(x: 0, y: 260, width: size.width, height: size.height - 260), 0xFFFFFF)
        fill(context, CGRect(x: 48, y: 150, width: 300, height: 40), 0xFFFFFF, radius: 10)
        for row in 0..<7 {
            let y = 320 + CGFloat(row) * 136
            fill(context, CGRect(x: 48, y: y, width: 88, height: 88), row % 2 == 0 ? 0xFDE68A : 0x86EFAC, radius: 20)
            fill(context, CGRect(x: 168, y: y + 12, width: 340, height: 24), 0x1F2937, radius: 6)
            fill(context, CGRect(x: 168, y: y + 54, width: 240, height: 18), 0xD1D5DB, radius: 6)
        }
    }

    // MARK: Builders

    private static let londonCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private static func london(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        londonCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func monday(_ key: String) -> (start: Date, end: Date) {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        let start = london(parts[0], parts[1], parts[2])
        return (start, londonCalendar.date(byAdding: .day, value: 7, to: start)!)
    }

    private static func summary(_ key: String, _ sentence: String, moved: Int) -> TimelineWeekSummary {
        let bounds = monday(key)
        return TimelineWeekSummary(week: key, start: bounds.start, end: bounds.end, sentence: sentence, moved: moved)
    }

    private static func week(_ key: String, final: Bool, stories: [TimelineStory],
                             also: [TimelineProjectRef]) -> TimelineWeek {
        let bounds = monday(key)
        return TimelineWeek(week: key, start: bounds.start, end: bounds.end, final: final,
                            stories: stories, also: also)
    }

    private static func project(_ num: Int, _ title: String) -> TimelineProjectRef {
        TimelineProjectRef(id: "pj_demo_\(num)", num: num, title: title)
    }

    private static func image(_ blobID: String, _ name: String) -> TimelineMedia {
        TimelineMedia(blobID: blobID, contentType: "image/png", name: name)
    }

    private static func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400 - 3_600)
    }
}
#endif
