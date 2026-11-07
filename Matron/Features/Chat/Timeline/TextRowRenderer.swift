import CoreGraphics
import UIKit
import MatronDesignSystem

/// One measured text row: what the cell draws and the layout it draws it in.
/// Immutable, so `@unchecked Sendable` is sound (NSAttributedString segments
/// are never mutated after rendering).
final class TextRowRender: @unchecked Sendable {
    let content: TextRowContent
    let segments: [MarkdownSegment]
    /// The one selectable string the cell's text view shows.
    let body: TextRowBody
    let layout: TextRowLayout
    let timestampText: String
    let style: TimelineTextStyle

    init(content: TextRowContent, segments: [MarkdownSegment], body: TextRowBody = .empty, layout: TextRowLayout,
         timestampText: String, style: TimelineTextStyle) {
        self.content = content
        self.segments = segments
        self.body = body
        self.layout = layout
        self.timestampText = timestampText
        self.style = style
    }
}

/// A message's text as ONE string, so a selection runs from any paragraph
/// to any other: separate text views per block stopped a drag at the
/// paragraph before a code block or table. Each code block or table stands
/// in the string as one invisible placeholder character on a line exactly
/// as tall as the block; the block's own view is drawn under the text view
/// at that line, and the selection highlight passes over it.
struct TextRowBody: @unchecked Sendable {
    struct Block: Equatable {
        /// The block's index in `TextRowRender.segments`.
        let segmentIndex: Int
        /// The placeholder character's index in `text`.
        let location: Int
        /// What a copied selection carries in the placeholder's place.
        let copyText: String
    }

    let text: NSAttributedString
    let blocks: [Block]

    static let empty = TextRowBody(text: NSAttributedString(), blocks: [])

    /// The block whose placeholder sits at `location`, if any.
    func block(at location: Int) -> Block? { blocks.first { $0.location == location } }

    /// The plain text of `range`, each placeholder replaced by its block's
    /// text — code as written, a table as tab-separated rows.
    func copyText(in range: NSRange) -> String {
        let string = text.string as NSString
        var result = ""
        var cursor = range.location
        for block in blocks where NSLocationInRange(block.location, range) {
            result += string.substring(with: NSRange(location: cursor, length: block.location - cursor))
            result += block.copyText
            cursor = block.location + 1
        }
        result += string.substring(with: NSRange(location: cursor, length: NSMaxRange(range) - cursor))
        return result
    }

    /// The character every placeholder is.
    static let placeholder = "\u{FFFC}"

    /// Draws nothing: the block's own view shows through the text view.
    final class Placeholder: NSTextAttachment {
        private static let clear: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }

        convenience init(width: CGFloat) {
            self.init(data: nil, ofType: nil)
            image = Self.clear
            bounds = CGRect(x: 0, y: 0, width: width, height: 1)
            allowsTextAttachmentView = false
        }
    }

    /// Joins `segments` (block heights given per segment index) into one
    /// string for a text container `width` wide. Prose keeps its own
    /// paragraph styles; a placeholder's line is pinned to its block's
    /// height, with `spacing` clear above and below it.
    static func build(_ segments: [MarkdownSegment], blockHeights: [Int: CGFloat], width: CGFloat,
                      spacing: CGFloat, font: UIFont) -> TextRowBody {
        let text = NSMutableAttributedString()
        var blocks: [Block] = []
        var previousSpacing: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            if text.length > 0 {
                // The separator ends the previous paragraph, so it carries
                // that paragraph's attributes.
                text.append(NSAttributedString(string: "\n",
                                               attributes: text.attributes(at: text.length - 1, effectiveRange: nil)))
            }
            switch segment {
            case .text(let prose):
                text.append(prose)
                let style = prose.length > 0
                    ? prose.attribute(.paragraphStyle, at: prose.length - 1, effectiveRange: nil) as? NSParagraphStyle
                    : nil
                previousSpacing = style?.paragraphSpacing ?? spacing
            case .code(_, let code):
                blocks.append(Block(segmentIndex: index, location: text.length, copyText: code))
                text.append(placeholder(height: blockHeights[index] ?? 0, width: width,
                                        spacingBefore: max(0, spacing - previousSpacing), spacing: spacing, font: font))
                previousSpacing = spacing
            case .table(let table):
                let rows = table.rows.map { $0.map(\.string).joined(separator: "\t") }
                blocks.append(Block(segmentIndex: index, location: text.length,
                                    copyText: rows.joined(separator: "\n")))
                text.append(placeholder(height: blockHeights[index] ?? 0, width: width,
                                        spacingBefore: max(0, spacing - previousSpacing), spacing: spacing, font: font))
                previousSpacing = spacing
            }
        }
        return TextRowBody(text: text, blocks: blocks)
    }

    private static func placeholder(height: CGFloat, width: CGFloat, spacingBefore: CGFloat, spacing: CGFloat,
                                    font: UIFont) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.paragraphSpacing = spacing
        let attachment = Placeholder(width: width)
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes([.font: font, .paragraphStyle: paragraph], range: NSRange(location: 0, length: string.length))
        return string
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
        MarkdownAttributed.rendered(for: content.body, style: style.markdown, cache: !content.isStreaming,
                                    trackerLinks: content.trackerLinks).segments
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
        var body = TextRowBody.empty
        let layout = TextBubbleGeometry.layout(
            rowWidth: width, isOwn: content.isOwn, hasAvatar: content.avatarSender != nil, timestamp: timestamp,
            content: { wrap in
                let measured = measureSegments(segments, wrapWidth: wrap, style: style, hosted: hosted)
                body = measured.body
                return measured.content
            },
            pillsHeight: content.pills.isEmpty ? nil : { rowWidth in hosted(.pills(content), rowWidth) },
            sendStateHeight: (content.isOwn && content.sendState != .sent) ? ceil(font.lineHeight) : nil)
        return TextRowRender(content: content, segments: segments, body: body, layout: layout,
                             timestampText: timestampText, style: style)
    }

    /// Lays the segments out as one `TextRowBody`: prose alone hugs its
    /// text; with a code block or table among it the column is the wrap
    /// width (MarkdownUI's code block fills the bubble width) and each
    /// block's frame is its placeholder's line. A message ending in a code
    /// block or table puts its "last baseline" at that block's bottom edge.
    /// `segmentFrames` holds one frame per segment, content-column
    /// coordinates: a block's view frame, or the band a prose segment's
    /// lines cover.
    private static func measureSegments(_ segments: [MarkdownSegment], wrapWidth: CGFloat, style: TimelineTextStyle,
                                        hosted: (HostedPiece, CGFloat) -> CGFloat)
        -> (content: TextBubbleGeometry.Content, body: TextRowBody) {
        guard segments.contains(where: { if case .text = $0 { false } else { true } }) else {
            // Prose only: one segment (the segmenter merges adjacent prose).
            guard case .text(let text)? = segments.first else {
                return (TextBubbleGeometry.Content(size: .zero, lastBaseline: 0, segmentFrames: []), .empty)
            }
            let measured = TextKitMeasure.hugging(text, width: wrapWidth)
            let frame = CGRect(origin: .zero, size: measured.size)
            return (TextBubbleGeometry.Content(size: measured.size, lastBaseline: measured.lastBaseline,
                                               segmentFrames: [frame]),
                    TextRowBody(text: text, blocks: []))
        }
        var heights: [Int: CGFloat] = [:]
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .text: continue
            case .code(_, let code): heights[index] = CodeBlockMetrics.height(code: code, style: style)
            case .table(let table): heights[index] = hosted(.table(table), wrapWidth)
            }
        }
        let body = TextRowBody.build(segments, blockHeights: heights, width: wrapWidth, spacing: style.segmentSpacing,
                                     font: .systemFont(ofSize: style.markdown.baseFontSize))
        // Each segment's character range in the body: blocks are their
        // placeholder, prose runs up to the separator before the next.
        var ranges: [NSRange] = []
        var location = 0
        for segment in segments {
            let length: Int
            switch segment {
            case .text(let text): length = text.length
            case .code, .table: length = 1
            }
            ranges.append(NSRange(location: location, length: length))
            location += length + 1
        }
        let measured = TextKitMeasure.measure(body.text, width: wrapWidth, locating: ranges)
        var frames: [CGRect] = []
        for (index, rect) in measured.rects.enumerated() {
            if let height = heights[index] {
                frames.append(CGRect(x: 0, y: rect.minY, width: wrapWidth, height: height))
            } else {
                frames.append(CGRect(x: 0, y: rect.minY, width: wrapWidth, height: rect.height))
            }
        }
        let height = max(measured.result.size.height, ceil(frames.last?.maxY ?? 0))
        let lastBaseline = heights[segments.count - 1] != nil ? (frames.last?.maxY ?? 0) : measured.result.lastBaseline
        return (TextBubbleGeometry.Content(size: CGSize(width: wrapWidth, height: height), lastBaseline: lastBaseline,
                                           segmentFrames: frames), body)
    }
}
