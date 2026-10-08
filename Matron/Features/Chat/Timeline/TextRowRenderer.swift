import CoreGraphics
import UIKit
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

/// A SwiftUI piece inside a text row that only a hosting controller can
/// measure — so a row containing one is measured on the main thread.
enum HostedPiece {
    case pills(TextRowContent)
    case table(MarkdownTable)
}

/// Geometry of `CodeBlockSegmentView` — mirrors `CodeBlock` (language label
/// + copy button, 4pt gap, monospaced callout in a horizontally scrolling
/// box with 8pt padding). Code never wraps, so height is width-independent.
enum CodeBlockMetrics {
    static let headerSpacing: CGFloat = 4
    static let codePadding: CGFloat = 8
    static let unboundedWidth: CGFloat = 100_000

    static func headerHeight(style: TimelineTextStyle) -> CGFloat {
        ceil(max(style.codeHeaderFont.lineHeight, style.copyIconFont.lineHeight))
    }

    static func attributed(_ code: String, style: TimelineTextStyle) -> NSAttributedString {
        NSAttributedString(string: code, attributes: [.font: style.codeFont, .foregroundColor: UIColor.label])
    }

    static func codeSize(_ code: String, style: TimelineTextStyle) -> CGSize {
        TextKitMeasure.measure(attributed(code, style: style), width: unboundedWidth).size
    }

    static func height(code: String, style: TimelineTextStyle) -> CGFloat {
        headerHeight(style: style) + headerSpacing + codeSize(code, style: style).height + 2 * codePadding
    }
}

/// Renders and lays out one text row: markdown → segments → measured
/// content column → `TextBubbleGeometry`. Thread-safe except for `hosted`,
/// which the caller supplies (main thread) or refuses (`backgroundRender`).
enum TextRowRenderer {
    static func segments(for content: TextRowContent, style: TimelineTextStyle) -> [MarkdownSegment] {
        MarkdownAttributed.rendered(for: content.body, style: style.markdown, cache: !content.isStreaming).segments
    }

    static func needsHosting(_ content: TextRowContent, segments: [MarkdownSegment]) -> Bool {
        !content.pills.isEmpty || segments.contains(where: \.isTable)
    }

    /// Off-main precompute: nil when the row has pills or a table.
    static func backgroundRender(_ content: TextRowContent, width: CGFloat, style: TimelineTextStyle) -> TextRowRender? {
        let segments = segments(for: content, style: style)
        guard !needsHosting(content, segments: segments) else { return nil }
        return render(content, segments: segments, width: width, style: style) { _, _ in
            preconditionFailure("hosted pieces are measured on the main thread")
        }
    }

    static func render(_ content: TextRowContent, width: CGFloat, style: TimelineTextStyle,
                       hosted: @escaping (HostedPiece, CGFloat) -> CGFloat) -> TextRowRender {
        render(content, segments: segments(for: content, style: style), width: width, style: style, hosted: hosted)
    }

    private static func render(_ content: TextRowContent, segments: [MarkdownSegment], width: CGFloat,
                               style: TimelineTextStyle,
                               hosted: @escaping (HostedPiece, CGFloat) -> CGFloat) -> TextRowRender {
        // `Text(timestamp, format: .dateTime.hour().minute())` in MessageBubble.
        let timestampText = content.timestamp.formatted(.dateTime.hour().minute())
        let font = style.timestampFont
        let timeWidth = TextKitMeasure.measure(
            NSAttributedString(string: timestampText, attributes: [.font: font]), width: 1_000).size.width
        let timestamp = TextBubbleGeometry.Timestamp(size: CGSize(width: timeWidth, height: ceil(font.lineHeight)),
                                                     ascent: font.ascender)
        let layout = TextBubbleGeometry.layout(
            rowWidth: width, isOwn: content.isOwn, hasAvatar: content.avatarSender != nil, timestamp: timestamp,
            content: { wrap in measureSegments(segments, wrapWidth: wrap, style: style, hosted: hosted) },
            pillsHeight: content.pills.isEmpty ? nil : { rowWidth in hosted(.pills(content), rowWidth) },
            sendStateHeight: (content.isOwn && content.sendState != .sent) ? ceil(font.lineHeight) : nil)
        return TextRowRender(content: content, segments: segments, layout: layout,
                             timestampText: timestampText, style: style)
    }

    /// Stacks segments with the style's block gap. Prose hugs; code and
    /// tables are greedy (MarkdownUI's code block fills the bubble width).
    /// A message ending in a code block or table puts its "last baseline"
    /// at that block's bottom edge.
    private static func measureSegments(_ segments: [MarkdownSegment], wrapWidth: CGFloat, style: TimelineTextStyle,
                                        hosted: (HostedPiece, CGFloat) -> CGFloat) -> TextBubbleGeometry.Content {
        var frames: [CGRect] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var lastBaseline: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            if index > 0 { y += style.segmentSpacing }
            switch segment {
            case .text(let text):
                let measured = TextKitMeasure.hugging(text, width: wrapWidth)
                frames.append(CGRect(x: 0, y: y, width: measured.size.width, height: measured.size.height))
                lastBaseline = y + measured.lastBaseline
                y += measured.size.height
                width = max(width, measured.size.width)
            case .code(_, let code):
                let height = CodeBlockMetrics.height(code: code, style: style)
                frames.append(CGRect(x: 0, y: y, width: wrapWidth, height: height))
                y += height
                lastBaseline = y
                width = wrapWidth
            case .table(let table):
                let height = hosted(.table(table), wrapWidth)
                frames.append(CGRect(x: 0, y: y, width: wrapWidth, height: height))
                y += height
                lastBaseline = y
                width = wrapWidth
            }
        }
        return TextBubbleGeometry.Content(size: CGSize(width: width, height: y), lastBaseline: lastBaseline,
                                          segmentFrames: frames)
    }
}
