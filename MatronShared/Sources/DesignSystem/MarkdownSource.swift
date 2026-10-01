import Foundation

/// Pre-parse fixes applied to every chat body before either renderer
/// (`MarkdownText` on iOS, `MarkdownAttributed` on Mac) sees it.
enum MarkdownSource {
    /// A container block left open by an earlier line. A block quote needs
    /// its `>` marker on every line (fenced code has no lazy continuation);
    /// a list item continues on lines indented to its content offset, or
    /// blank ones.
    private enum Container {
        case quote
        case item(offset: Int)
    }

    /// A line shaped like a CommonMark link reference definition —
    /// `[label]: destination` — is consumed by the parser and renders as
    /// nothing. Chat bodies are prose: nobody writes reference definitions
    /// in a message, but the bridge's voice-note mirror
    /// ("[Voice note transcription]: Hello.") and plenty of ordinary text
    /// ("[TODO]: fix it") take exactly that shape, and vanished into an
    /// empty bubble. Escaping the opening bracket turns the line back into
    /// text. Fenced and indented code are left alone — a definition there
    /// is content.
    static func escapingReferenceDefinitions(_ source: String) -> String {
        guard source.contains("]:") else { return source }
        return rewritingProseLines(source) { rawLine, line, rest in
            guard isReferenceDefinition(rest) else { return nil }
            let cut = index(in: rawLine, atColumn: line.distance(from: line.startIndex, to: rest.startIndex))
            return rawLine[..<cut] + "\\" + rawLine[cut...]
        }
    }

    /// Both pre-parse fixes, in the order the renderers need them.
    static func prepared(_ source: String) -> String {
        linkingBareItemURLs(escapingReferenceDefinitions(source))
    }

    /// A bare `matron://item/<n>` in prose is plain text to both parsers:
    /// CommonMark only autolinks a URL written inside angle brackets, and
    /// the GFM extension only autolinks `http(s)`/`www.`. Agents often write
    /// the item link bare ("the steps are on #5685 (matron://item/5685)"),
    /// and the reader could not tap it. Wrapping it in `<…>` makes it a
    /// CommonMark autolink, which then resolves in-app like any
    /// `[#12](matron://item/12)` link (`MatronItemLink`).
    ///
    /// Left alone: fenced and indented code, inline code spans, a URL that
    /// is already a link's destination or autolink (after `](` or `<`), and
    /// anything inside an unclosed `[` on the line (link text — an autolink
    /// there would break the outer link). Only the canonical form is
    /// touched: lowercase, ASCII digits, not followed by more URL
    /// characters. `matron://convo/…` is deliberately not linked: the
    /// conversation pills read links off the raw body, and a bare one is
    /// documented as not a link (`ConversationLinkRefs`).
    static func linkingBareItemURLs(_ source: String) -> String {
        guard source.contains(itemURLPrefix) else { return source }
        return rewritingProseLines(source) { rawLine, _, _ in
            guard rawLine.contains(itemURLPrefix) else { return nil }
            return linkingItemURLs(inLine: rawLine)
        }
    }

    private static let itemURLPrefix = "matron://item/"

    /// One prose line's bare item URLs wrapped in `<…>`, or `nil` when
    /// nothing changed.
    private static func linkingItemURLs(inLine line: Substring) -> String? {
        let chars = Array(line)
        let prefix = Array(itemURLPrefix)
        var out = ""
        var changed = false
        var bracketDepth = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                out.append(c); out.append(chars[i + 1]); i += 2
                continue
            }
            if c == "`" {
                // An inline code span: a backtick run closed by a run of the
                // same length later on the line is copied verbatim. An
                // unmatched run is literal backticks.
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                if let close = closingBacktickRun(chars, from: i + run, length: run) {
                    out.append(contentsOf: chars[i..<(close + run)]); i = close + run
                } else {
                    out.append(contentsOf: chars[i..<(i + run)]); i += run
                }
                continue
            }
            if c == "[" { bracketDepth += 1 }
            if c == "]", bracketDepth > 0 { bracketDepth -= 1 }
            if c == "m", bracketDepth == 0, chars[i...].starts(with: prefix) {
                var end = i + prefix.count
                while end < chars.count, chars[end].isASCII, chars[end].isNumber { end += 1 }
                let digits = end - (i + prefix.count)
                let before = i > 0 ? chars[i - 1] : " "
                let twoBefore = i > 1 ? chars[i - 2] : " "
                let after: Character = end < chars.count ? chars[end] : " "
                let isDestination = before == "<" || (before == "(" && twoBefore == "]")
                let continuesURL = after.isLetter || after.isNumber || "/?#%_-=&@~".contains(after)
                if digits > 0, !isDestination, !continuesURL, !(before.isLetter || before.isNumber || before == "/"),
                   let number = Int(String(chars[(i + prefix.count)..<end])), number > 0 {
                    out.append("<"); out.append(contentsOf: chars[i..<end]); out.append(">")
                    changed = true
                    i = end
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return changed ? out : nil
    }

    private static func closingBacktickRun(_ chars: [Character], from start: Int, length: Int) -> Int? {
        var j = start
        while j < chars.count {
            guard chars[j] == "`" else { j += 1; continue }
            var run = 0
            while j + run < chars.count, chars[j + run] == "`" { run += 1 }
            if run == length { return j }
            j += run
        }
        return nil
    }

    /// Walks `source` line by line, tracking block quotes, list items and
    /// fenced/indented code, and calls `rewrite` for every line that is
    /// NOT code, with the raw line, its tab-expanded form, and what is left
    /// of the expanded line past its container markers. `rewrite` returns
    /// the replacement line, or `nil` to keep it. Returns `source` itself
    /// when no line changed.
    private static func rewritingProseLines(
        _ source: String,
        _ rewrite: (_ rawLine: Substring, _ line: Substring, _ rest: Substring) -> String?
    ) -> String {
        var open: [Container] = []
        // The open fence: its character and run length, and how many of
        // `open` it lives inside. It closes on a run of the same character
        // at least as long, with nothing after it, on a line that continues
        // every one of those containers; if any of them ends, the fence
        // ends with it. Indentation is always measured past the innermost
        // container's content start, so "four columns make indented code"
        // means four past a list item's offset, not four from the margin.
        var fence: (char: Character, length: Int, depth: Int)?
        var changed = false
        var out: [String] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            // Every column rule below runs on a tab-expanded copy of the
            // line; the original is what gets emitted.
            let line = expandingTabs(rawLine)
            let (matched, remainder) = continuation(of: open, on: line)
            var rest = remainder
            if let active = fence {
                if matched == active.depth {
                    let ws = rest.prefix(while: isSpace)
                    if columns(ws) <= 3, let run = fenceRun(rest[ws.endIndex...]),
                       run.char == active.char, run.length >= active.length, run.rest.isEmpty {
                        fence = nil
                    }
                    out.append(String(rawLine))
                    continue
                }
                fence = nil // a container the fence lived in ended on this line
            }
            open.removeSubrange(matched...)
            openContainers(on: &rest, into: &open)
            let ws = rest.prefix(while: isSpace)
            if columns(ws) >= 4 {
                out.append(String(rawLine)) // indented code
                continue
            }
            rest = rest[ws.endIndex...]
            if let run = fenceRun(rest) {
                fence = (run.char, run.length, open.count)
                out.append(String(rawLine))
            } else if let replaced = rewrite(rawLine, line, rest) {
                out.append(replaced)
                changed = true
            } else {
                out.append(String(rawLine))
            }
        }
        return changed ? out.joined(separator: "\n") : source
    }

    private static func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    /// Columns of leading whitespace on a tab-expanded line.
    private static func columns(_ whitespace: Substring) -> Int {
        whitespace.count
    }

    /// The line with each tab replaced by the spaces that carry it to the
    /// next multiple of four columns, so a tab is one to four columns
    /// depending on where it sits. Lines without tabs are returned as is.
    private static func expandingTabs(_ line: Substring) -> Substring {
        guard line.contains("\t") else { return line }
        var expanded = ""
        var column = 0
        for character in line {
            if character == "\t" {
                let width = 4 - column % 4
                expanded += String(repeating: " ", count: width)
                column += width
            } else {
                expanded.append(character)
                column += 1
            }
        }
        return Substring(expanded)
    }

    /// The index in the original line that sits at `column` of its
    /// tab-expanded form. The escape goes in front of a `[`, which always
    /// starts a column, so the walk lands exactly on it.
    private static func index(in line: Substring, atColumn column: Int) -> Substring.Index {
        var cursor = line.startIndex
        var reached = 0
        while reached < column, cursor < line.endIndex {
            reached += line[cursor] == "\t" ? 4 - reached % 4 : 1
            cursor = line.index(after: cursor)
        }
        return cursor
    }

    /// How many of the open containers this line continues, and what is
    /// left of the line once their markers and indentation are consumed.
    private static func continuation(of open: [Container], on line: Substring) -> (matched: Int, rest: Substring) {
        var rest = line
        for (index, container) in open.enumerated() {
            let ws = rest.prefix(while: isSpace)
            switch container {
            case .quote:
                let after = rest[ws.endIndex...]
                guard columns(ws) <= 3, after.first == ">" else { return (index, rest) }
                rest = after.dropFirst()
                if let pad = rest.first, isSpace(pad) { rest = rest.dropFirst() }
            case .item(let offset):
                if ws.endIndex == rest.endIndex {
                    rest = rest[ws.endIndex...] // a blank line stays inside the item
                    continue
                }
                guard columns(ws) >= offset else { return (index, rest) }
                rest = rest.dropFirst(offset)
            }
        }
        return (open.count, rest)
    }

    /// Opens the containers a line starts: block-quote markers (`>` plus one
    /// optional space or tab) and list markers (`-`, `*`, `+`, or up to nine digits
    /// with `.` or `)`, followed by whitespace or the end of the line), each
    /// behind at most three columns of the previous container's content.
    private static func openContainers(on rest: inout Substring, into open: inout [Container]) {
        while true {
            let gap = rest.prefix(while: isSpace)
            guard columns(gap) <= 3 else { return }
            let after = rest[gap.endIndex...]
            if after.first == ">" {
                open.append(.quote)
                rest = after.dropFirst()
                if let pad = rest.first, isSpace(pad) { rest = rest.dropFirst() }
                continue
            }
            guard let markerEnd = listMarkerEnd(after) else { return }
            let padding = after[markerEnd...].prefix(while: isSpace)
            guard !padding.isEmpty || markerEnd == after.endIndex else { return }
            let width = columns(gap) + after.distance(from: after.startIndex, to: markerEnd)
            // One to four columns of padding belong to the marker. Five or
            // more — or nothing but whitespace — count as one, and the rest
            // of the line is indented code inside the item.
            if (1...4).contains(columns(padding)), padding.endIndex < after.endIndex {
                open.append(.item(offset: width + columns(padding)))
                rest = after[padding.endIndex...]
            } else {
                open.append(.item(offset: width + 1))
                rest = padding.isEmpty ? after[markerEnd...] : after[after.index(after: markerEnd)...]
            }
        }
    }

    private static func listMarkerEnd(_ line: Substring) -> Substring.Index? {
        guard let first = line.first else { return nil }
        if first == "-" || first == "*" || first == "+" { return line.index(after: line.startIndex) }
        let digits = line.prefix(while: \.isNumber)
        guard (1...9).contains(digits.count), digits.endIndex < line.endIndex,
              line[digits.endIndex] == "." || line[digits.endIndex] == ")" else { return nil }
        return line.index(after: digits.endIndex)
    }

    /// A fence marker at the start of a (whitespace-trimmed) line: three or
    /// more backticks or tildes. `rest` is what follows the run.
    private static func fenceRun(_ line: Substring) -> (char: Character, length: Int, rest: Substring)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let run = line.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        let rest = line[run.endIndex...].drop(while: isSpace)
        return (first, run.count, rest)
    }

    /// `[label]:` with a label (up to the first `]`) that has at least one
    /// non-whitespace character, and at least one more character after the
    /// colon — the parser needs a destination.
    private static func isReferenceDefinition(_ line: Substring) -> Bool {
        guard line.first == "[", let close = line.firstIndex(of: "]") else { return false }
        let label = line[line.index(after: line.startIndex)..<close]
        guard label.contains(where: { !$0.isWhitespace }), !label.contains("[") else { return false }
        let afterClose = line.index(after: close)
        guard afterClose < line.endIndex, line[afterClose] == ":" else { return false }
        let rest = line[line.index(after: afterClose)...].drop(while: isSpace)
        return !rest.isEmpty
    }
}
