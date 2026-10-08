import Foundation

/// Inline attachments in tracker bodies (shared spec "inline images"): an
/// item body or a comment body may place one of its OWN attachments in the
/// text with `![caption](attachment:<blob_ref>)`. The journal only sends
/// these raw refs to a client that asks for them
/// (`X-Matron-Item-Inline: attachments`); older apps get the caption text.
///
/// The grammar every client agrees on is
/// `!\[([^\]\n]*)\]\(attachment:([A-Za-z0-9_-]{1,128})\)`, matched outside
/// fenced code blocks and inline code spans.

/// One piece of a body split around its inline attachments, in reading order.
public enum InlineSegment: Equatable, Sendable {
    /// Markdown for the client's existing renderer, trimmed of blank lines
    /// at its edges and never empty or whitespace-only.
    case text(String)
    /// An attachment shown in place.
    case attachment(TrackerAttachment)
}

/// A body split by `splitInlineAttachments(body:attachments:)`.
public struct InlineAttachmentSplit: Equatable, Sendable {
    /// Text and attachment segments in reading order.
    public var segments: [InlineSegment]
    /// The attachments no ref placed, in their original order — drawn after
    /// the segments, as every attachment was before inline refs existed.
    public var trailing: [TrackerAttachment]

    public init(segments: [InlineSegment], trailing: [TrackerAttachment]) {
        self.segments = segments
        self.trailing = trailing
    }

    /// How many text segments there are — one selectable text view each.
    public var textSegmentCount: Int {
        segments.reduce(0) { count, segment in
            if case .text = segment { return count + 1 }
            return count
        }
    }
}

/// Splits `body` around its inline attachment refs.
///
/// A ref resolves only when its blob is in `attachments` (the body's OWN
/// attachments) and no earlier ref in the same body already placed it. A ref
/// that does not resolve becomes its caption text (nothing when the caption
/// is empty) and is never fetched. Refs inside fenced code blocks and inline
/// code spans are literal text.
public func splitInlineAttachments(body: String, attachments: [TrackerAttachment]) -> InlineAttachmentSplit {
    // Most bodies have no refs: skip the scan (the Mac thread splits every
    // card on each update to keep its selection order).
    guard body.contains("](attachment:") else {
        let text = InlineAttachmentScanner.trimmed(body, followsAttachment: false)
        return InlineAttachmentSplit(segments: text.map { [.text($0)] } ?? [], trailing: attachments)
    }
    var byRef: [String: TrackerAttachment] = [:]
    for attachment in attachments where byRef[attachment.blobRef] == nil {
        byRef[attachment.blobRef] = attachment
    }
    var used = Set<String>()
    var segments: [InlineSegment] = []
    var buffer = String.UnicodeScalarView()
    var bufferFollowsAttachment = false

    func flush() {
        if let text = InlineAttachmentScanner.trimmed(String(buffer), followsAttachment: bufferFollowsAttachment) {
            segments.append(.text(text))
        }
        buffer = String.UnicodeScalarView()
    }

    InlineAttachmentScanner.scan(body) { piece in
        switch piece {
        case .literal(let scalars):
            buffer.append(contentsOf: scalars)
        case .ref(let caption, let blobRef):
            if let attachment = byRef[blobRef], !used.contains(blobRef) {
                used.insert(blobRef)
                flush()
                segments.append(.attachment(attachment))
                bufferFollowsAttachment = true
            } else {
                buffer.append(contentsOf: caption.unicodeScalars)
            }
        }
    }
    flush()
    return InlineAttachmentSplit(segments: segments, trailing: attachments.filter { !used.contains($0.blobRef) })
}

/// `body` with every inline attachment ref (outside code) replaced by its
/// caption, or `(image)` when the caption is empty — what the journal sends
/// an app that does not ask for raw refs. For one-line previews and other
/// surfaces that show a body without its attachments.
public func inlineAttachmentPlainText(_ body: String) -> String {
    guard body.contains("](attachment:") else { return body }
    var out = String.UnicodeScalarView()
    InlineAttachmentScanner.scan(body) { piece in
        switch piece {
        case .literal(let scalars):
            out.append(contentsOf: scalars)
        case .ref(let caption, _):
            out.append(contentsOf: (caption.isEmpty ? "(image)" : caption).unicodeScalars)
        }
    }
    return String(out)
}

enum InlineAttachmentScanner {
    enum Piece {
        case literal(ArraySlice<Unicode.Scalar>)
        case ref(caption: String, blobRef: String)
    }

    static let maxRefLength = 128

    /// Walks `body` in order, reporting literal text and every ref outside
    /// fenced code blocks and inline code spans. Works on unicode scalars
    /// so `\r\n` and combining marks never hide a `\n` or a bracket.
    static func scan(_ body: String, _ emit: (Piece) -> Void) {
        let scalars = Array(body.unicodeScalars)
        var fence: Fence?
        var lineStart = 0
        while lineStart < scalars.count {
            var lineEnd = lineStart
            while lineEnd < scalars.count, scalars[lineEnd] != "\n" { lineEnd += 1 }
            // Include the newline itself in the line's literal text.
            let next = min(lineEnd + 1, scalars.count)
            let marker = fenceMarker(scalars, from: lineStart, to: lineEnd)
            if let open = fence {
                emit(.literal(scalars[lineStart..<next]))
                if let marker, marker.closes(open) { fence = nil }
            } else if let marker {
                fence = marker
                emit(.literal(scalars[lineStart..<next]))
            } else {
                scanLine(scalars, from: lineStart, to: lineEnd, emit)
                if lineEnd < scalars.count { emit(.literal(scalars[lineEnd..<next])) }
            }
            lineStart = next
        }
    }

    /// A fence line: its character, how many of it, and whether anything
    /// but whitespace follows the run (an info string).
    struct Fence {
        let char: Unicode.Scalar
        let length: Int
        let hasTrailingText: Bool

        /// CommonMark's closing fence: the same character, at least as
        /// long as the opener, nothing after it.
        func closes(_ open: Fence) -> Bool {
            char == open.char && length >= open.length && !hasTrailingText
        }
    }

    /// The fence on this line, if it opens or closes one: optional leading
    /// spaces or tabs, then three or more of "`" or "~".
    static func fenceMarker(_ s: [Unicode.Scalar], from start: Int, to end: Int) -> Fence? {
        var i = start
        while i < end, s[i] == " " || s[i] == "\t" { i += 1 }
        guard i < end, s[i] == "`" || s[i] == "~" else { return nil }
        let c = s[i]
        var runEnd = i
        while runEnd < end, s[runEnd] == c { runEnd += 1 }
        guard runEnd - i >= 3 else { return nil }
        let trailing = s[runEnd..<end].contains { !($0 == " " || $0 == "\t" || $0 == "\r") }
        return Fence(char: c, length: runEnd - i, hasTrailingText: trailing)
    }

    /// One line outside a fence: inline code spans are copied verbatim,
    /// refs are reported, everything else is literal.
    ///
    /// A ref is code only when a span covers its start, or opens inside it
    /// and runs past its end (spec addendum). A span wholly inside the
    /// caption — `![run `make`](attachment:aa11)` — does not hide it.
    private static func scanLine(_ s: [Unicode.Scalar], from start: Int, to end: Int, _ emit: (Piece) -> Void) {
        let spans = codeSpans(s, from: start, to: end)
        var nextSpan = 0
        var literalStart = start
        var i = start
        while i < end {
            while nextSpan < spans.count, spans[nextSpan].upperBound <= i { nextSpan += 1 }
            if nextSpan < spans.count, spans[nextSpan].lowerBound == i {
                // Inside a code span: literal through its closing run.
                i = spans[nextSpan].upperBound
                continue
            }
            if s[i] == "!", let match = matchRef(s, at: i, end: end),
               !spans[nextSpan...].contains(where: { $0.lowerBound > i && $0.lowerBound < match.after && $0.upperBound > match.after }) {
                if literalStart < i { emit(.literal(s[literalStart..<i])) }
                emit(.ref(caption: match.caption, blobRef: match.blobRef))
                i = match.after
                literalStart = match.after
                continue
            }
            i += 1
        }
        if literalStart < end { emit(.literal(s[literalStart..<end])) }
    }

    /// The line's inline code spans, left to right, each from its opening
    /// run to just past its closing run: a run of n backticks opens a span
    /// that the next run of exactly n closes; with no closer on the line
    /// the run is literal.
    static func codeSpans(_ s: [Unicode.Scalar], from start: Int, to end: Int) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var i = start
        while i < end {
            guard s[i] == "`" else { i += 1; continue }
            var runEnd = i
            while runEnd < end, s[runEnd] == "`" { runEnd += 1 }
            let n = runEnd - i
            var j = runEnd
            var closer: Int?
            while j < end {
                if s[j] == "`" {
                    var k = j
                    while k < end, s[k] == "`" { k += 1 }
                    if k - j == n { closer = k; break }
                    j = k
                } else {
                    j += 1
                }
            }
            if let closer {
                spans.append(i..<closer)
                i = closer
            } else {
                i = runEnd
            }
        }
        return spans
    }

    /// `![caption](attachment:ref)` starting at `i`, within the line.
    private static func matchRef(_ s: [Unicode.Scalar], at i: Int, end: Int) -> (caption: String, blobRef: String, after: Int)? {
        guard i + 1 < end, s[i + 1] == "[" else { return nil }
        var j = i + 2
        while j < end, s[j] != "]" { j += 1 }
        guard j < end else { return nil }
        let caption = String(String.UnicodeScalarView(s[(i + 2)..<j]))
        let prefix = Array("](attachment:".unicodeScalars)
        guard j + prefix.count <= end, Array(s[j..<(j + prefix.count)]) == prefix else { return nil }
        let refStart = j + prefix.count
        var k = refStart
        while k < end, isRefScalar(s[k]) { k += 1 }
        let length = k - refStart
        guard length >= 1, length <= maxRefLength, k < end, s[k] == ")" else { return nil }
        return (caption, String(String.UnicodeScalarView(s[refStart..<k])), k + 1)
    }

    private static func isRefScalar(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x5F, 0x2D: return true
        default: return false
        }
    }

    /// A text segment's final form, or `nil` to drop it: blank lines at
    /// both edges removed and trailing spaces cut. When the text carries on
    /// the line of an attachment placed just before it, that line's
    /// leading spaces go too — they were the gap after the ref. A line that
    /// starts the body keeps its indentation.
    static func trimmed(_ text: String, followsAttachment: Bool) -> String? {
        // Split on scalars: a `Character`-level split would see `\r\n` as
        // one grapheme and miss the `\n` in it.
        var lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        if followsAttachment, let first = lines.first {
            lines[0] = String(first.drop(while: { $0 == " " || $0 == "\t" }))
        }
        let isBlank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        while let first = lines.first, isBlank(first) { lines.removeFirst() }
        while let last = lines.last, isBlank(last) { lines.removeLast() }
        guard let last = lines.last else { return nil }
        var end = last.endIndex
        while end > last.startIndex, last[last.index(before: end)].isWhitespace { end = last.index(before: end) }
        lines[lines.count - 1] = String(last[..<end])
        return lines.joined(separator: "\n")
    }
}
