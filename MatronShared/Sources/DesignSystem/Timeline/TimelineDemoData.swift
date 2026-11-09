#if DEBUG
import SwiftUI
import CoreGraphics
import MatronModels

/// Made-up weeks, stories and lists for previews and snapshot tests, with
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
        lede: "The docs site got search and is on course for Wednesday. Themes gained sepia and high contrast, and "
            + "offline mode went into beta. **Three things are waiting on you.**",
        stories: [
            TimelineStory(project: docs, sentence: "Search is live on staging, and pages now load in under a second.",
                          next: "a rehearsal on Monday, then launch on Wednesday.",
                          needsYou: [item(11, "Approve the getting-started copy")], media: image("docs", "docs-search.png")),
            TimelineStory(project: themes, sentence: "All fifteen themes now come in sepia and high contrast.",
                          next: "the filled icon set, then accent colours.", media: image("themes", "theme-grid.png")),
            TimelineStory(project: offline, sentence: "You can now read everything with no signal. It’s in the beta build.",
                          next: "editing offline, and syncing it back safely.",
                          needsYou: [item(12, "Retry limits for uploads on slow networks"), item(13, "Cache size caps"),
                                     item(14, "Eviction order"), item(15, "Attachment policy")],
                          media: TimelineMedia(blobID: "offline-video", contentType: "video/mp4", name: "offline-reading.mp4")),
            TimelineStory(project: cropper, sentence: "Smart crop now handles rounded corners.",
                          next: "nothing, unless you want changes.",
                          needsYou: [item(16, "Approve it, or ask for more")], media: image("cropper", "rounded-corners.png")),
        ],
        also: [project(20, "Release notes"), project(21, "Crash reporting"), project(22, "Settings search"),
               project(23, "Font picker"), project(24, "Keyboard shortcuts")])

    public static let lastWeek = week(
        "2026-10-26", final: true,
        lede: "Themes and the image cropper both made big steps, and the docs site got much faster. "
            + "Billing export started, then stopped.",
        stories: [
            TimelineStory(project: themes, sentence: "Sepia variants rendered for the first eight themes.",
                          next: "high contrast for all fifteen.", media: image("themes", "sepia.png")),
            TimelineStory(project: cropper, sentence: "It passed the full sample set for the first time.",
                          next: "rounded corners.", media: image("cropper", "samples.png")),
            TimelineStory(project: docs, sentence: "Pages got faster: 2.1 s down to 0.8 s.",
                          next: "search.", media: image("chart", "load-times.png")),
            TimelineStory(project: billing, sentence: "The CSV export works for one account type.",
                          next: "the other two account types. *It went quiet after this.*",
                          media: image("billing", "export.png")),
        ],
        also: [project(21, "Crash reporting"), project(25, "Onboarding emails")])

    /// A new user's first week: nothing has moved.
    public static let emptyWeek = week("2026-11-02", final: false, lede: nil, stories: [], also: [])

    /// A story with no picture or video that week.
    public static let noMediaStory = TimelineStory(
        project: audit, sentence: "The report was written and two fixes went in.",
        next: "the rest of the fixes, planned for the next release.")

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

    public static let finished: [FinishedProject] = [
        ("Push notifications pilot", 2), ("Sign in with a passkey", 4), ("Dark mode for the web app", 9),
        ("Faster app launch", 13), ("Export to PDF", 21), ("New onboarding screens", 30),
        ("Shared links", 44), ("Usage meter", 61),
    ].enumerated().map { index, row in
        FinishedProject(project: project(40 + index, row.0), finishedAt: daysAgo(row.1))
    }

    // MARK: Pictures

    /// The pictures the stories name, by blob id, drawn in code.
    public static var images: [String: Image] {
        var images: [String: Image] = [:]
        for (id, draw) in [("docs", drawDocs), ("themes", drawThemes), ("cropper", drawCropper),
                           ("chart", drawChart), ("billing", drawBilling)] as [(String, (CGContext, CGSize) -> Void)] {
            if let cgImage = picture(draw) { images[id] = Image(decorative: cgImage, scale: 2) }
        }
        return images
    }

    private static let pictureSize = CGSize(width: 960, height: 400)

    private static func picture(_ draw: (CGContext, CGSize) -> Void) -> CGImage? {
        let size = pictureSize
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

    private static func week(_ key: String, final: Bool, lede: String?, stories: [TimelineStory],
                             also: [TimelineProjectRef]) -> TimelineWeek {
        let bounds = monday(key)
        return TimelineWeek(week: key, start: bounds.start, end: bounds.end, final: final, lede: lede,
                            stories: stories, also: also)
    }

    private static func project(_ num: Int, _ title: String) -> TimelineProjectRef {
        TimelineProjectRef(id: "pj_demo_\(num)", num: num, title: title)
    }

    private static func item(_ num: Int, _ title: String) -> TimelineItemRef {
        TimelineItemRef(id: "it_demo_\(num)", num: num, title: title)
    }

    private static func image(_ blobID: String, _ name: String) -> TimelineMedia {
        TimelineMedia(blobID: blobID, contentType: "image/png", name: name)
    }

    private static func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400 - 3_600)
    }
}
#endif
