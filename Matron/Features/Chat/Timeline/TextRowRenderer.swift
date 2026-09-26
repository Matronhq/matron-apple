import CoreGraphics
import MatronDesignSystem

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
