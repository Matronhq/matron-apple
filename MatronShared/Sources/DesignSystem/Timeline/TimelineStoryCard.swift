import SwiftUI
import MatronModels

/// One project's week on a week page: its picture or video (no media area
/// when there is none), the project's name, one sentence on what was done,
/// and its marks (`TimelineMarksLine`), when it has any. The page makes
/// the whole card open its project.
public struct TimelineStoryCard: View {
    let story: TimelineStory
    let image: Image?
    let pixelSize: CGSize?

    /// `pixelSize` is the picture's own size, when the host knows it.
    public init(story: TimelineStory, image: Image?, pixelSize: CGSize? = nil) {
        self.story = story; self.image = image; self.pixelSize = pixelSize
    }

    // The Mac names its sizes: its text styles run ~3 pt smaller than iOS's.
    #if os(macOS)
    static let titleFont = Font.system(size: 18, weight: .semibold)
    static let sentenceFont = Font.system(size: 15)
    static let noteFont = Font.system(size: 14)
    private static let padding = EdgeInsets(top: 16, leading: 20, bottom: 20, trailing: 20)
    #else
    static let titleFont = Font.title3.weight(.semibold)
    static let sentenceFont = Font.body
    static let noteFont = Font.subheadline
    private static let padding = EdgeInsets(top: 14, leading: 16, bottom: 18, trailing: 16)
    #endif
    /// `DashboardCardChrome`'s.
    static let cornerRadius: CGFloat = 12

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let media = story.media {
                TimelineMediaView(media: media, image: image, pixelSize: pixelSize)
            }
            words.padding(Self.padding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .modifier(DashboardCardChrome(fill: 0))
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .accessibilityIdentifier("timeline.story.\(story.project.num)")
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(story.project.title).font(Self.titleFont).lineLimit(2)
            Text(MissionsDashboardFormat.statusPreviewText(TimelineFormat.sentence(story)))
                .font(Self.sentenceFont).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if !story.marks.isEmpty {
                TimelineMarksLine(marks: story.marks).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
