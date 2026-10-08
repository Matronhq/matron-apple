import Foundation

/// Markdown attachment preview (shared spec "markdown preview"): which
/// attachments open in the in-app reader instead of downloading, and the
/// one rewrite their text gets before it reaches the app's markdown
/// renderer, so a previewed file can never make the app fetch anything.
public enum MarkdownPreview {
    /// Past this the attachment keeps today's download/open behaviour.
    public static let maxBytes: Int64 = 2 * 1024 * 1024

    static let markdownMimes: Set<String> = ["text/markdown", "text/x-markdown"]
    /// Types a sender's upload falls back to when it doesn't know better;
    /// with one of these the file name decides.
    static let genericMimes: Set<String> = ["", "text/plain", "application/octet-stream"]
    static let extensions = ["md", "markdown", "mdown"]
    /// Link schemes that open outside the app, the way chat links do.
    /// Everything else (relative paths, `#anchor`, `file:`, `matron:` …) is
    /// inert in a previewed file.
    static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    /// Whether an attachment opens in the markdown preview: a markdown
    /// MIME type, or a markdown file name with a generic (or no) MIME type,
    /// and no more than `maxBytes`. An unknown size (`nil`) passes — the
    /// preview checks the bytes it fetches instead.
    public static func isPreviewable(mime: String?, name: String?, size: Int64?) -> Bool {
        if let size, size > maxBytes { return false }
        let type = essence(of: mime)
        if markdownMimes.contains(type) { return true }
        guard genericMimes.contains(type), let name else { return false }
        return hasMarkdownExtension(name)
    }

    /// `name` ends in `.md`, `.markdown` or `.mdown`, in any case.
    public static func hasMarkdownExtension(_ name: String) -> Bool {
        let lower = name.lowercased()
        return extensions.contains { lower.hasSuffix("." + $0) }
    }

    /// `text/markdown; charset=utf-8` → `text/markdown`.
    static func essence(of mime: String?) -> String {
        guard let mime else { return "" }
        let type = mime.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return type.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Whether a link destination opens externally (http, https, mailto).
    public static func opensExternally(_ destination: String) -> Bool {
        guard let scheme = scheme(of: destination.trimmingCharacters(in: .whitespaces)) else { return false }
        return externalSchemes.contains(scheme)
    }

    /// The URL scheme `destination` starts with, lowercased, or `nil` for a
    /// relative reference.
    static func scheme(of destination: String) -> String? {
        guard let colon = destination.firstIndex(of: ":") else { return nil }
        let scheme = destination[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) })
        else { return nil }
        return scheme.lowercased()
    }

    /// `markdown` made safe to render in the preview, outside code — fenced
    /// and indented code blocks and inline code spans stay verbatim:
    /// - every image, inline `![alt](dest)` or reference `![alt][ref]`,
    ///   becomes its alt text (an inline one with no alt becomes its
    ///   destination as plain text) — so no renderer ever loads a remote or
    ///   relative image;
    /// - a link whose destination doesn't open externally (`./other.md`,
    ///   `#anchor`, `file:`, `matron:` …) becomes its text, including one
    ///   whose text wraps onto the next line of its paragraph;
    /// - a link reference definition with such a destination
    ///   (`[ref]: ./other.md`) is escaped to plain text, so `[text][ref]`
    ///   stays text too (the renderers' own pre-parse step escapes every
    ///   definition anyway, so reference links never resolve there);
    /// - an autolink with such a scheme (`<file:///etc/hosts>`) is escaped
    ///   to plain text;
    /// - a bare `matron://item/<n>`, which that pre-parse step would turn
    ///   into an in-app link, is written `matron\://item/<n>` — the same
    ///   text once rendered, never a link.
    /// Inline http(s) and mailto links are left as they are.
    ///
    /// The result is then parsed with Foundation's CommonMark parser as a
    /// check: if anything still reads as an image or as a link that doesn't
    /// open externally (a construct the rewrite above doesn't model), every
    /// `[` and `<` outside code is escaped instead — the file loses its
    /// links, but nothing in it can load or open.
    public static func sanitized(_ markdown: String) -> String {
        guard markdown.contains("[") || markdown.contains("<") || markdown.contains("matron://item/")
        else { return markdown }
        let scalars = Array(markdown.unicodeScalars)
        let rewritten = rewrite(scalars, mode: .links)
        guard hasUnsafeInline(rewritten) else { return rewritten }
        let escaped = rewrite(scalars, mode: .escapeOutsideCode)
        guard hasUnsafeInline(escaped) else { return escaped }
        // The block scan disagreed with the parser about what is code:
        // escape everywhere, code included.
        return rewrite(scalars, mode: .escapeEverywhere)
    }

    enum RewriteMode {
        /// Rewrite images and inert links, keep the rest.
        case links
        /// Escape every `[` and `<` outside code.
        case escapeOutsideCode
        /// Escape every `[` and `<`, code included.
        case escapeEverywhere
    }

    /// Whether `markdown`, parsed as CommonMark, still contains an image or
    /// a link that doesn't open externally. Unparseable text counts as
    /// unsafe.
    static func hasUnsafeInline(_ markdown: String) -> Bool {
        guard markdown.contains("[") || markdown.contains("<") else { return false }
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return true }
        for run in parsed.runs {
            if run.imageURL != nil { return true }
            if let link = run.link, !externalSchemes.contains(link.scheme?.lowercased() ?? "") { return true }
        }
        return false
    }

    static func rewrite(_ scalars: [Unicode.Scalar], mode: RewriteMode) -> String {
        if mode == .escapeEverywhere {
            var out = String.UnicodeScalarView()
            InlineSanitizer(s: scalars, spans: []).escape(0..<scalars.count, into: &out)
            return String(out)
        }
        var out = String.UnicodeScalarView()
        var fence: InlineAttachmentScanner.Fence?
        // Inside a list, a line indented four columns is the item's own
        // content, not an indented code block.
        var inList = false
        var inIndentedCode = false
        // An indented code block can't interrupt a paragraph: it needs the
        // start of the file, a blank line or the end of a block before it.
        var canStartIndentedCode = true
        // The open paragraph: its lines are rewritten together, so a link
        // whose text wraps onto the next line is still seen whole.
        var group: (start: Int, end: Int, next: Int)?
        var groupSpans: [Range<Int>] = []

        func flush() {
            guard let g = group else { return }
            let sanitizer = InlineSanitizer(s: scalars, spans: groupSpans)
            if mode == .links {
                sanitizer.rewrite(g.start..<g.end, into: &out)
            } else {
                sanitizer.escape(g.start..<g.end, into: &out)
            }
            out.append(contentsOf: scalars[g.end..<g.next])
            group = nil
            groupSpans = []
        }

        var lineStart = 0
        while lineStart < scalars.count {
            var lineEnd = lineStart
            while lineEnd < scalars.count, scalars[lineEnd] != "\n" { lineEnd += 1 }
            let next = min(lineEnd + 1, scalars.count)
            defer { lineStart = next }
            var first = lineStart
            var indent = 0
            while first < lineEnd, scalars[first] == " " || scalars[first] == "\t" {
                indent += scalars[first] == "\t" ? 4 - indent % 4 : 1
                first += 1
            }
            let isBlank = scalars[first..<lineEnd].allSatisfy { $0 == "\r" }

            if let open = fence {
                out.append(contentsOf: scalars[lineStart..<next])
                if let marker = InlineAttachmentScanner.fenceMarker(scalars, from: lineStart, to: lineEnd),
                   marker.closes(open) {
                    fence = nil
                    canStartIndentedCode = true
                }
                continue
            }
            if isBlank {
                flush()
                out.append(contentsOf: scalars[lineStart..<next])
                canStartIndentedCode = true
                continue
            }
            if indent >= 4, !inList, group == nil, inIndentedCode || canStartIndentedCode {
                inIndentedCode = true
                out.append(contentsOf: scalars[lineStart..<next])
                continue
            }
            inIndentedCode = false
            if indent < 4 || inList,
               let marker = InlineAttachmentScanner.fenceMarker(scalars, from: lineStart, to: lineEnd) {
                flush()
                fence = marker
                out.append(contentsOf: scalars[lineStart..<next])
                continue
            }
            canStartIndentedCode = false
            if indent < 4 || inList, isListItem(scalars, from: first, to: lineEnd) {
                inList = true
            } else if indent == 0, group == nil {
                // A new unindented block after a blank line ends the list.
                inList = false
            }
            if mode == .links, group == nil, indent < 4,
               let destination = referenceDefinitionDestination(scalars, from: first, to: lineEnd) {
                if !opensExternally(destination) {
                    // `\[ref]: ./other.md` — plain text, and `[text][ref]`
                    // finds no definition.
                    out.append(contentsOf: scalars[lineStart..<first])
                    out.append("\\")
                    let spans = InlineAttachmentScanner.codeSpans(scalars, from: first, to: lineEnd)
                    InlineSanitizer(s: scalars, spans: spans).rewrite(first..<lineEnd, into: &out)
                    out.append(contentsOf: scalars[lineEnd..<next])
                } else {
                    out.append(contentsOf: scalars[lineStart..<next])
                }
                continue
            }
            groupSpans += InlineAttachmentScanner.codeSpans(scalars, from: lineStart, to: lineEnd)
            group = (group?.start ?? lineStart, lineEnd, next)
        }
        flush()
        return String(out)
    }

    /// A list item's marker at `i`: `-`, `*` or `+`, or up to nine digits
    /// and `.` or `)`, then a space, a tab or the end of the line.
    static func isListItem(_ s: [Unicode.Scalar], from i: Int, to end: Int) -> Bool {
        guard i < end else { return false }
        var j = i
        if s[j] == "-" || s[j] == "*" || s[j] == "+" {
            j += 1
        } else {
            while j < end, j - i < 9, (0x30...0x39).contains(s[j].value) { j += 1 }
            guard j > i, j < end, s[j] == "." || s[j] == ")" else { return false }
            j += 1
        }
        return j == end || s[j] == " " || s[j] == "\t" || s[j] == "\r"
    }

    /// The destination of a one-line link reference definition at `i`,
    /// `[label]: destination "optional title"`, or `nil` if the line isn't
    /// one.
    static func referenceDefinitionDestination(_ s: [Unicode.Scalar], from i: Int, to end: Int) -> String? {
        guard i < end, s[i] == "[" else { return nil }
        var j = i + 1
        while j < end, s[j] != "]" {
            if s[j] == "[" { return nil }
            if s[j] == "\\" { j += 1 }
            j += 1
        }
        guard j < end, j > i + 1, j + 1 < end, s[j + 1] == ":" else { return nil }
        var k = j + 2
        while k < end, s[k] == " " || s[k] == "\t" { k += 1 }
        guard k < end else { return nil }
        var destStart = k
        var destEnd: Int
        if s[k] == "<" {
            destStart = k + 1
            destEnd = destStart
            while destEnd < end, s[destEnd] != ">" { destEnd += 1 }
        } else {
            destEnd = k
            while destEnd < end, s[destEnd] != " ", s[destEnd] != "\t", s[destEnd] != "\r" { destEnd += 1 }
        }
        return String(String.UnicodeScalarView(s[destStart..<destEnd]))
    }

    /// The raw text cut into runs of whole lines, so the Source view can
    /// lay a long file out lazily instead of as one enormous `Text`.
    public static func sourceChunks(_ text: String, linesPerChunk: Int = 200) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > linesPerChunk else { return [text] }
        return stride(from: 0, to: lines.count, by: linesPerChunk).map {
            lines[$0..<min($0 + linesPerChunk, lines.count)].joined(separator: "\n")
        }
    }
}

/// One paragraph's inline rewrite for `MarkdownPreview.sanitized`.
private struct InlineSanitizer {
    let s: [Unicode.Scalar]
    /// Inline code spans, by where they start.
    private let spans: [Int: Range<Int>]

    init(s: [Unicode.Scalar], spans: [Range<Int>]) {
        self.s = s
        self.spans = Dictionary(spans.map { ($0.lowerBound, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func span(startingAt i: Int) -> Range<Int>? {
        spans[i]
    }

    /// Copies `range` with a backslash before every `[` and `<` outside
    /// code spans, so nothing in it parses as a link, an image or an
    /// autolink. Existing escapes are copied as pairs, so an escaped
    /// backslash never ends up escaping the new one.
    func escape(_ range: Range<Int>, into out: inout String.UnicodeScalarView) {
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            if let span = span(startingAt: i), span.upperBound <= end {
                out.append(contentsOf: s[span])
                i = span.upperBound
                continue
            }
            let c = s[i]
            if c == "\\", i + 1 < end {
                out.append(c)
                out.append(s[i + 1])
                i += 2
                continue
            }
            if c == "[" || c == "<" { out.append("\\") }
            if neutralisesItemURL(at: i, end: end, into: &out) {
                i += Self.itemScheme.count
                continue
            }
            out.append(c)
            i += 1
        }
    }

    /// `matron://item/` as the renderers' own pre-parse step looks for it
    /// (`MarkdownSource.linkingBareItemURLs` wraps a bare one in `<…>`,
    /// making it an in-app link).
    private static let itemURLPrefix = Array("matron://item/".unicodeScalars)
    private static let itemScheme = Array("matron".unicodeScalars)

    /// At a bare `matron://item/` in prose, writes `matron\:` — the same
    /// text once rendered, but no longer the prefix that pre-parse step
    /// turns into a link — and returns `true`.
    private func neutralisesItemURL(at i: Int, end: Int, into out: inout String.UnicodeScalarView) -> Bool {
        let prefix = Self.itemURLPrefix
        guard s[i] == "m", i + prefix.count <= end, Array(s[i..<(i + prefix.count)]) == prefix else { return false }
        out.append(contentsOf: Self.itemScheme)
        out.append("\\")
        return true
    }

    func rewrite(_ range: Range<Int>, into out: inout String.UnicodeScalarView) {
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            if let span = span(startingAt: i), span.upperBound <= end {
                out.append(contentsOf: s[span])
                i = span.upperBound
                continue
            }
            let c = s[i]
            if c == "\\", i + 1 < end {
                out.append(c)
                out.append(s[i + 1])
                i += 2
                continue
            }
            if c == "!", i + 1 < end, s[i + 1] == "[", let link = matchLink(openingAt: i + 1, end: end) {
                var alt = String.UnicodeScalarView()
                rewrite(link.text, into: &alt)
                if String(alt).trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append(contentsOf: link.destination
                        .replacingOccurrences(of: "matron://item/", with: "matron\\://item/").unicodeScalars)
                } else {
                    out.append(contentsOf: alt)
                }
                i = link.after
                continue
            }
            if c == "!", i + 1 < end, s[i + 1] == "[", let close = matchBracket(openingAt: i + 1, end: end) {
                // A reference image, `![alt][ref]`, `![alt][]` or `![alt]`:
                // its alt text, and the label goes with it.
                rewrite((i + 2)..<close, into: &out)
                var after = close + 1
                if after < end, s[after] == "[", let label = matchBracket(openingAt: after, end: end) {
                    after = label + 1
                }
                i = after
                continue
            }
            if c == "[", let link = matchLink(openingAt: i, end: end) {
                var text = String.UnicodeScalarView()
                rewrite(link.text, into: &text)
                if MarkdownPreview.opensExternally(link.destination) {
                    out.append("[")
                    out.append(contentsOf: text)
                    // `](destination "title")`, verbatim.
                    out.append(contentsOf: s[link.text.upperBound..<link.after])
                } else {
                    out.append(contentsOf: text)
                }
                i = link.after
                continue
            }
            if c == "<", let scheme = autolinkScheme(at: i, end: end),
               !MarkdownPreview.externalSchemes.contains(scheme) {
                out.append("\\")
                out.append(c)
                i += 1
                continue
            }
            if neutralisesItemURL(at: i, end: end, into: &out) {
                i += Self.itemScheme.count
                continue
            }
            out.append(c)
            i += 1
        }
    }

    /// An inline link or image body starting at the `[` at `b`:
    /// `[text](destination "optional title")`, within the line.
    private func matchLink(openingAt b: Int, end: Int) -> (text: Range<Int>, destination: String, after: Int)? {
        guard let close = matchBracket(openingAt: b, end: end), close + 1 < end, s[close + 1] == "(" else { return nil }
        var k = close + 2
        skipSpace(&k, end: end)
        let destStart: Int
        let destEnd: Int
        if k < end, s[k] == "<" {
            var m = k + 1
            while m < end, s[m] != ">", s[m] != "<", s[m] != "\n" {
                if s[m] == "\\" { m += 1 }
                m += 1
            }
            guard m < end, s[m] == ">" else { return nil }
            destStart = k + 1
            destEnd = m
            k = m + 1
        } else {
            var parens = 0
            var m = k
            while m < end {
                let c = s[m]
                if c == "\\", m + 1 < end {
                    m += 2
                    continue
                }
                if isSpace(c) { break }
                if c == "(" {
                    parens += 1
                } else if c == ")" {
                    if parens == 0 { break }
                    parens -= 1
                }
                m += 1
            }
            destStart = k
            destEnd = m
            k = m
        }
        skipSpace(&k, end: end)
        if k < end, s[k] == "\"" || s[k] == "'" || s[k] == "(" {
            let closer: Unicode.Scalar = s[k] == "(" ? ")" : s[k]
            var m = k + 1
            while m < end, s[m] != closer {
                if s[m] == "\\" { m += 1 }
                m += 1
            }
            guard m < end else { return nil }
            k = m + 1
            skipSpace(&k, end: end)
        }
        guard k < end, s[k] == ")" else { return nil }
        let destination = String(String.UnicodeScalarView(s[destStart..<destEnd]))
        return ((b + 1)..<close, destination, k + 1)
    }

    /// Spaces, tabs and line breaks — a paragraph's lines are rewritten
    /// together, so a destination or title may sit on the next line.
    private func isSpace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r"
    }

    private func skipSpace(_ k: inout Int, end: Int) {
        while k < end, isSpace(s[k]) { k += 1 }
    }

    /// The `]` matching the `[` at `b`: nested brackets balance; escapes
    /// and code spans never close it.
    private func matchBracket(openingAt b: Int, end: Int) -> Int? {
        var depth = 0
        var j = b
        var close: Int?
        while j < end {
            if let span = span(startingAt: j) {
                j = span.upperBound
                continue
            }
            let c = s[j]
            if c == "\\" {
                j += 2
                continue
            }
            if c == "[" {
                depth += 1
            } else if c == "]" {
                depth -= 1
                if depth == 0 {
                    close = j
                    break
                }
            }
            j += 1
        }
        return close
    }

    /// The scheme of a CommonMark URI autolink `<scheme:…>` at `i`.
    private func autolinkScheme(at i: Int, end: Int) -> String? {
        var j = i + 1
        guard j < end, isASCIILetter(s[j]) else { return nil }
        let schemeStart = j
        while j < end, isSchemeScalar(s[j]) { j += 1 }
        let length = j - schemeStart
        guard length >= 2, length <= 32, j < end, s[j] == ":" else { return nil }
        var k = j + 1
        while k < end, s[k] != ">" {
            let v = s[k].value
            if s[k] == "<" || s[k] == " " || v < 0x20 || v == 0x7F { return nil }
            k += 1
        }
        guard k < end else { return nil }
        return String(String.UnicodeScalarView(s[schemeStart..<j])).lowercased()
    }

    private func isASCIILetter(_ c: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(c.value) || (0x61...0x7A).contains(c.value)
    }

    private func isSchemeScalar(_ c: Unicode.Scalar) -> Bool {
        isASCIILetter(c) || (0x30...0x39).contains(c.value) || c == "+" || c == "." || c == "-"
    }
}

/// What the preview asked to show: one attachment, by its media URL.
public struct MarkdownPreviewRequest: Equatable, Hashable, Identifiable, Sendable {
    /// `GET /media/:blob_ref` on the user's journal — fetched with the
    /// app's authenticated media path, never a plain URL load.
    public let mediaURL: URL
    public let blobRef: String
    /// The file name shown in the header and used for Share and Save.
    public let name: String
    /// The attachment's declared size, when it has one.
    public let size: Int64?

    public var id: String { mediaURL.absoluteString }

    public init(mediaURL: URL, name: String, size: Int64?, blobRef: String? = nil) {
        let ref = blobRef ?? mediaURL.lastPathComponent
        self.mediaURL = mediaURL
        self.blobRef = ref
        self.name = name.isEmpty ? ref : name
        self.size = size
    }
}

/// A fetched markdown file: its text (decoded as UTF-8, invalid bytes
/// replaced), the sanitised source the renderer gets, and the raw text in
/// chunks for the Source view. Built once per fetch, off the main thread.
public struct MarkdownPreviewDocument: Equatable, Sendable {
    public let text: String
    public let rendered: String
    public let sourceChunks: [String]

    public init(text: String) {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        self.text = text
        self.rendered = MarkdownPreview.sanitized(text)
        self.sourceChunks = MarkdownPreview.sourceChunks(text)
    }

    public init(data: Data) {
        self.init(text: String(decoding: data, as: UTF8.self))
    }

    public static func == (a: MarkdownPreviewDocument, b: MarkdownPreviewDocument) -> Bool {
        a.text == b.text
    }
}

/// Why a preview could not show its file.
public enum MarkdownPreviewFailure: Equatable, Sendable {
    /// The fetched bytes were over `MarkdownPreview.maxBytes`.
    case tooLarge
    /// The blob is gone for good (the journal's media reaper).
    case expired
    /// Anything else — offline, a server error. Worth a retry.
    case unavailable
}

public enum MarkdownPreviewPhase: Equatable, Sendable {
    case idle
    case loading
    case loaded(MarkdownPreviewDocument)
    case failed(MarkdownPreviewFailure)
}

public extension TrackerAttachment {
    /// Opens in the markdown preview rather than downloading. A size of 0
    /// is an attachment that never said, so it counts as unknown.
    var isPreviewableMarkdown: Bool {
        MarkdownPreview.isPreviewable(mime: mime, name: name, size: size > 0 ? size : nil)
    }
}
