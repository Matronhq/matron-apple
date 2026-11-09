import SwiftUI
import MatronModels

/// A project told as a story: its name, one sentence on where it stands,
/// what is coming up, what waits on the user, and its pictures and videos
/// by week. No counts, chips or toolbars: the one control is "···", which
/// holds the host's `menu` and "All details" (the full project page). A
/// pure leaf: hosts pass the page, the loaded pictures by blob id and the
/// openers; a tile opens through `onOpenFile`, which plays a video.
public struct ProjectStoryView<MenuContent: View>: View {
    let page: ProjectPageModel
    let now: Date
    let images: [String: Image]
    let onOpenItem: (String) -> Void
    let onOpenFile: (ProjectFile) -> Void
    let onAllDetails: () -> Void
    let menu: MenuContent

    public init(page: ProjectPageModel, now: Date, images: [String: Image],
                onOpenItem: @escaping (String) -> Void, onOpenFile: @escaping (ProjectFile) -> Void,
                onAllDetails: @escaping () -> Void, @ViewBuilder menu: () -> MenuContent) {
        self.page = page; self.now = now; self.images = images
        self.onOpenItem = onOpenItem; self.onOpenFile = onOpenFile; self.onAllDetails = onAllDetails
        self.menu = menu()
    }

    private typealias M = ProjectStoryMetrics

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                titleRow
                VStack(alignment: .leading, spacing: TimelinePage.sectionSpacing) {
                    words
                    waiting
                    gallery
                }
                .frame(maxWidth: M.readableWidth, alignment: .leading)
            }
            .padding(TimelinePage.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("projects.story")
    }

    // MARK: Words

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(page.project.title).font(TimelinePage.titleFont)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            menu
            Button(TimelineFormat.allDetails, action: onAllDetails)
                .accessibilityIdentifier("projects.story.allDetails")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 24)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        #if os(macOS)
        .menuIndicator(.hidden)
        #endif
        .fixedSize()
        .accessibilityLabel("More")
        .accessibilityIdentifier("projects.story.more")
    }

    @ViewBuilder private var words: some View {
        let sentence = TimelineFormat.storySentence(page)
        let comingUp = TimelineFormat.comingUp(page)
        if sentence != nil || comingUp != nil {
            VStack(alignment: .leading, spacing: 14) {
                if let sentence {
                    Text(MissionsDashboardFormat.statusPreviewText(sentence))
                        .font(M.sentenceFont).lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let comingUp {
                    (Text(TimelineFormat.comingUpPrefix).bold() + Text(verbatim: " " + comingUp))
                        .font(M.comingUpFont).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("projects.story.comingUp")
                }
            }
        }
    }

    // MARK: Waiting on you

    @ViewBuilder private var waiting: some View {
        if !page.needsYou.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(ProjectFeedFormat.waitingHeading)
                    .font(M.waitingHeadingFont).foregroundStyle(Color.red)
                    .accessibilityAddTraits(.isHeader)
                ForEach(page.needsYou) { item in waitingRow(item) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.red.opacity(0.28)))
            .accessibilityIdentifier("projects.story.waiting")
        }
    }

    private func waitingRow(_ item: TrackerItem) -> some View {
        Button { onOpenItem(item.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: ItemGlyph.symbol(item.kind)).foregroundStyle(Color.red)
                Text(ProjectsFormat.oneLine(item.title)).foregroundStyle(Color.primary).lineLimit(2)
                Spacer(minLength: 8)
                Text(TimelineFormat.openItem).foregroundStyle(Color.accentColor)
            }
            .font(M.rowFont)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("projects.story.waiting.\(item.id)")
    }

    // MARK: Gallery

    @ViewBuilder private var gallery: some View {
        let weeks = ProjectGallery.weeks(page.files.rows, now: now)
        if !weeks.isEmpty {
            let items = page.needsYou + page.openItems
            VStack(alignment: .leading, spacing: 28) {
                ForEach(weeks) { week in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(week.title)
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .accessibilityAddTraits(.isHeader)
                        tiles(week.files, items: items)
                    }
                }
            }
            .accessibilityIdentifier("projects.story.gallery")
        }
    }

    /// Two to a row; tiles in a row share the taller one's height.
    private func tiles(_ files: [ProjectFile], items: [TrackerItem]) -> some View {
        let rows = stride(from: 0, to: files.count, by: 2).map { Array(files[$0..<min($0 + 2, files.count)]) }
        return VStack(alignment: .leading, spacing: 24) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: TimelinePage.cardSpacing) {
                    ForEach(rows[index]) { file in tile(file, items: items) }
                    if rows[index].count < 2 { Color.clear.frame(maxWidth: .infinity) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tile(_ file: ProjectFile, items: [TrackerItem]) -> some View {
        let caption = TimelineFormat.galleryCaption(file, items: items)
        let shape = RoundedRectangle(cornerRadius: M.tileCorner, style: .continuous)
        return Button { onOpenFile(file) } label: {
            VStack(alignment: .leading, spacing: 4) {
                TimelineMediaView(media: ProjectGallery.media(file), image: images[file.blobID],
                                  aspectRatio: M.tileAspectRatio)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.10)))
                    .padding(.bottom, 6)
                if let caption {
                    Text(caption).font(M.captionFont).foregroundStyle(Color.primary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if let postedAt = file.postedAt {
                    Text(TimelineFormat.weekday(postedAt)).font(M.dayFont).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("projects.story.file.\(file.id)")
    }
}

public extension ProjectStoryView where MenuContent == EmptyView {
    init(page: ProjectPageModel, now: Date, images: [String: Image],
         onOpenItem: @escaping (String) -> Void, onOpenFile: @escaping (ProjectFile) -> Void,
         onAllDetails: @escaping () -> Void) {
        self.init(page: page, now: now, images: images, onOpenItem: onOpenItem, onOpenFile: onOpenFile,
                  onAllDetails: onAllDetails) { EmptyView() }
    }
}

/// One week of a project's gallery: its heading and its pictures and
/// videos, newest first.
public struct ProjectGalleryWeek: Identifiable, Equatable {
    /// The week's Monday.
    public let start: Date
    public let title: String
    public let files: [ProjectFile]
    public var id: Date { start }
}

/// A project page's pictures and videos, by week.
public enum ProjectGallery {
    /// Weeks start on Monday, in the user's zone. Display grouping only.
    public static var mondayCalendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    public static func isMedia(_ file: ProjectFile) -> Bool {
        let type = file.contentType?.lowercased() ?? ""
        return type.hasPrefix("image/") || type.hasPrefix("video/")
    }

    /// The images and videos among `files`, newest first, one group per
    /// week. A file with no posting time has no week, so it is left out.
    public static func weeks(_ files: [ProjectFile], now: Date,
                             calendar: Calendar = mondayCalendar) -> [ProjectGalleryWeek] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        let dated = files.filter(isMedia).compactMap { file in file.postedAt.map { (file, $0) } }
            .sorted { $0.1 > $1.1 }
        var weeks: [ProjectGalleryWeek] = []
        for (file, postedAt) in dated {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: postedAt)?.start else { continue }
            if let last = weeks.last, last.start == start {
                weeks[weeks.count - 1] = ProjectGalleryWeek(start: start, title: last.title, files: last.files + [file])
            } else {
                weeks.append(ProjectGalleryWeek(
                    start: start, title: TimelineFormat.galleryWeekTitle(weekStart: start, thisWeekStart: thisWeek,
                                                                         calendar: calendar),
                    files: [file]))
            }
        }
        return weeks
    }

    /// The file as the timeline's media: a video gets the dark ▶ panel.
    static func media(_ file: ProjectFile) -> TimelineMedia {
        TimelineMedia(blobID: file.blobID, contentType: file.contentType ?? "", name: file.name ?? "")
    }
}

/// The story page's sizes. The Mac names its own: its text styles run
/// ~3 pt smaller than iOS's.
enum ProjectStoryMetrics {
    #if os(macOS)
    static let sentenceFont = Font.system(size: 20)
    static let comingUpFont = Font.system(size: 16)
    static let waitingHeadingFont = Font.system(size: 17, weight: .semibold)
    static let rowFont = Font.system(size: 14)
    static let captionFont = Font.system(size: 14)
    static let dayFont = Font.system(size: 12)
    #else
    static let sentenceFont = Font.title3
    static let comingUpFont = Font.body
    static let waitingHeadingFont = Font.headline
    static let rowFont = Font.body
    static let captionFont = Font.subheadline
    static let dayFont = Font.caption
    #endif
    /// The words and gallery stop growing here, so lines stay readable on
    /// a wide window.
    static let readableWidth: CGFloat = 900
    /// Width over height of a gallery tile.
    static let tileAspectRatio: CGFloat = 1.7
    static let tileCorner: CGFloat = 10
}
