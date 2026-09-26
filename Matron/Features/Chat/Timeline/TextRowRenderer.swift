import CoreGraphics
import MatronDesignSystem

/// Every frame of one laid-out text row (cell coordinates unless noted).
struct TextRowLayout: Equatable {
    var rowHeight: CGFloat
    var bubbleFrame: CGRect
    /// Bubble coordinates.
    var segmentFrames: [CGRect]
    /// Bubble coordinates.
    var timestampFrame: CGRect
    var avatarFrame: CGRect?
    var pillsFrame: CGRect?
    var sendStateFrame: CGRect?

    /// Test/fake convenience: a row of `height` with no content frames.
    static func fixed(height: CGFloat) -> TextRowLayout {
        TextRowLayout(rowHeight: height, bubbleFrame: .zero, segmentFrames: [], timestampFrame: .zero,
                      avatarFrame: nil, pillsFrame: nil, sendStateFrame: nil)
    }
}

/// One measured text row: what the cell draws and the layout it draws it in.
/// Immutable, so `@unchecked Sendable` is sound (NSAttributedString segments
/// are never mutated after rendering).
final class TextRowRender: @unchecked Sendable {
    let content: TextRowContent
    let segments: [MarkdownSegment]
    let layout: TextRowLayout
    let timestampText: String
    let style: TimelineTextStyle

    init(content: TextRowContent, segments: [MarkdownSegment], layout: TextRowLayout,
         timestampText: String, style: TimelineTextStyle) {
        self.content = content
        self.segments = segments
        self.layout = layout
        self.timestampText = timestampText
        self.style = style
    }
}
