import SwiftUI
import MatronModels

/// How a week page lays out its projects: a card each (`TimelineStoryCard`),
/// or a compact row each (`TimelineWeekRow`). Kept per device.
public enum TimelineWeekLayout: String, CaseIterable, Sendable {
    case tiles, list

    /// The `@AppStorage` key the choice is kept under.
    public static let storageKey = "projects.weekLayout"
    public static let `default`: TimelineWeekLayout = .tiles

    /// The choice kept in `defaults`; the default when none (or no known one) is.
    public static func stored(in defaults: UserDefaults) -> TimelineWeekLayout {
        defaults.string(forKey: storageKey).flatMap(TimelineWeekLayout.init(rawValue:)) ?? .default
    }

    public var title: String {
        switch self {
        case .tiles: return "Tiles"
        case .list: return "List"
        }
    }

    var symbol: String {
        switch self {
        case .tiles: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

/// One project's week as a compact row of a week page in list layout: a
/// small square of its picture (cropped to fill; a quiet glyph when it has
/// none, a play mark for a video), the project's name, its sentence in two
/// lines at most, and its marks. The page makes the row a button that
/// opens its project, labelled `TimelineFormat.rowLabel`.
public struct TimelineWeekRow: View {
    let story: TimelineStory
    let image: Image?

    public init(story: TimelineStory, image: Image?) {
        self.story = story; self.image = image
    }

    #if os(macOS)
    static let thumbnailSize: CGFloat = 52
    static let titleFont = Font.system(size: 15, weight: .semibold)
    static let sentenceFont = Font.system(size: 13)
    #else
    static let thumbnailSize: CGFloat = 56
    static let titleFont = Font.body.weight(.semibold)
    static let sentenceFont = Font.subheadline
    #endif
    static let thumbnailRadius: CGFloat = 8

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(story.project.title).font(Self.titleFont).foregroundStyle(Color.primary).lineLimit(1)
                Text(MissionsDashboardFormat.statusPreviewText(TimelineFormat.sentence(story)))
                    .font(Self.sentenceFont).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !story.marks.isEmpty {
                    TimelineMarksLine(marks: story.marks).padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: Self.thumbnailRadius, style: .continuous)
            .fill(Color.secondary.opacity(0.12))
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .overlay {
                if let image, story.media?.isVideo != true {
                    image.resizable().scaledToFill()
                        .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                } else if story.media?.isVideo == true {
                    Image(systemName: "play.fill").font(.system(size: 18)).foregroundStyle(.secondary)
                } else if story.media == nil {
                    Image(systemName: ProjectGlyph.symbol).font(.system(size: 20)).foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.thumbnailRadius, style: .continuous))
    }
}
