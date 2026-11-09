import SwiftUI
import MatronModels

/// One story on a week page: its picture or video (no media area when
/// there is none), the project's name, one sentence on what was done,
/// "Next: …", and a red "Needs you: …" line only when something waits.
/// The page makes the card open its project; the needs-you line opens its
/// item.
public struct TimelineStoryCard: View {
    let story: TimelineStory
    let image: Image?
    let onOpenItem: ((String) -> Void)?

    public init(story: TimelineStory, image: Image?, onOpenItem: ((String) -> Void)? = nil) {
        self.story = story; self.image = image; self.onOpenItem = onOpenItem
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
                TimelineMediaView(media: media, image: image)
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
            if let next = story.next {
                Text(MissionsDashboardFormat.statusPreviewText("Next: \(next)"))
                    .font(Self.noteFont).foregroundStyle(.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            needsYou
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var needsYou: some View {
        if let line = TimelineFormat.needsYou(story), let first = story.needsYou.first {
            Button { onOpenItem?(first.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle().fill(Color.red).frame(width: 9, height: 9)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(TimelineFormat.needsYouPrefix + line)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Self.noteFont.weight(.semibold))
                .foregroundStyle(Color.red)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityIdentifier("timeline.story.\(story.project.num).needsYou")
        }
    }
}
