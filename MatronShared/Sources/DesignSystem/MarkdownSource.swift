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
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let (matched, remainder) = continuation(of: open, on: line)
            var rest = remainder
            if let active = fence {
                if matched == active.depth {
                    let ws = rest.prefix(while: isSpace)
                    if columns(ws) <= 3, let run = fenceRun(rest[ws.endIndex...]),
                       run.char == active.char, run.length >= active.length, run.rest.isEmpty {
                        fence = nil
                    }
                    out.append(String(line))
                    continue
                }
                fence = nil // a container the fence lived in ended on this line
            }
            open.removeSubrange(matched...)
            openContainers(on: &rest, into: &open)
            let ws = rest.prefix(while: isSpace)
            if columns(ws) >= 4 {
                out.append(String(line)) // indented code
                continue
            }
            rest = rest[ws.endIndex...]
            if let run = fenceRun(rest) {
                fence = (run.char, run.length, open.count)
                out.append(String(line))
            } else if isReferenceDefinition(rest) {
                out.append(line[..<rest.startIndex] + "\\" + rest)
                changed = true
            } else {
                out.append(String(line))
            }
        }
        return changed ? out.joined(separator: "\n") : source
    }

    private static func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    private static func columns(_ whitespace: Substring) -> Int {
        whitespace.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
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
                if rest.first == " " { rest = rest.dropFirst() }
            case .item(let offset):
                if ws.endIndex == rest.endIndex {
                    rest = rest[ws.endIndex...] // a blank line stays inside the item
                    continue
                }
                guard columns(ws) >= offset else { return (index, rest) }
                var consumed = 0
                var cursor = rest.startIndex
                while consumed < offset {
                    consumed += rest[cursor] == "\t" ? 4 : 1
                    cursor = rest.index(after: cursor)
                }
                rest = rest[cursor...]
            }
        }
        return (open.count, rest)
    }

    /// Opens the containers a line starts: block-quote markers (`>` plus one
    /// optional space) and list markers (`-`, `*`, `+`, or up to nine digits
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
                if rest.first == " " { rest = rest.dropFirst() }
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
