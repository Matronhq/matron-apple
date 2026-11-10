import SwiftUI
import MatronModels

/// A card's marks, in one line: a red dot and "2 for you", "✓ 5 done",
/// "→ Next"; only those that apply, and nothing at all when none does.
/// Counts and a word, never an item's title.
public struct TimelineMarksLine: View {
    let marks: TimelineMarks

    public init(marks: TimelineMarks) { self.marks = marks }

    #if os(macOS)
    private static let dotSize: CGFloat = 9
    private static let spacing: CGFloat = 16
    #else
    private static let dotSize: CGFloat = 10
    private static let spacing: CGFloat = 14
    #endif

    public var body: some View {
        if let label = TimelineFormat.marksLabel(marks) {
            HStack(alignment: .firstTextBaseline, spacing: Self.spacing) {
                if marks.forYou > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(Color.red).frame(width: Self.dotSize, height: Self.dotSize)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        Text(TimelineFormat.forYouMark(marks.forYou))
                    }
                    .foregroundStyle(Color.red)
                }
                if marks.done > 0 {
                    Text(TimelineFormat.doneMark(marks.done)).foregroundStyle(Color.green)
                }
                if marks.next {
                    Text(TimelineFormat.nextMark).foregroundStyle(.secondary)
                }
            }
            .font(TimelineStoryCard.noteFont)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier("timeline.marks")
        }
    }
}
