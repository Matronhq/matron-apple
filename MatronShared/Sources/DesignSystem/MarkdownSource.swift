import Foundation

/// Pre-parse fixes applied to every chat body before either renderer
/// (`MarkdownText` on iOS, `MarkdownAttributed` on Mac) sees it.
enum MarkdownSource {
    /// A line shaped like a CommonMark link reference definition —
    /// `[label]: destination` — is consumed by the parser and renders as
    /// nothing. Chat bodies are prose: nobody writes reference definitions
    /// in a message, but the bridge's voice-note mirror
    /// ("[Voice note transcription]: Hello.") and plenty of ordinary text
    /// ("[TODO]: fix it") take exactly that shape, and vanished into an
    /// empty bubble. Escaping the opening bracket turns the line back into
    /// text. Fenced code is left alone — a definition there is content.
    static func escapingReferenceDefinitions(_ source: String) -> String {
        guard source.contains("]:") else { return source }
        // The open fence: its character, run length, and the block-quote
        // markers it lives under. A fence closes on a run of the SAME
        // character at least as long, with nothing after it, at the SAME
        // container level; leaving its container (a line with a shorter or
        // different marker prefix) ends the container and the fence with it;
        // a deeper-nested line inside it is content.
        var fence: (char: Character, length: Int, markers: String)?
        var changed = false
        var out: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let indent = line[line.startIndex..<trimmed.startIndex]
            // Four columns of indentation make an indented code block, where
            // a definition-shaped line is content — and so is a fence marker.
            if columns(indent) >= 4 {
                out.append(String(line))
                continue
            }
            // Block-quote and list markers are containers: what follows them
            // is still a paragraph line (or a fence) to the parser, subject
            // to the same up-to-three-spaces rule inside the container.
            var (prefix, rest) = containerPrefix(trimmed)
            // Only block-quote markers scope a fence: a list item's
            // continuation lines carry indentation, not the marker, and
            // are still inside the item.
            let markers = prefix.filter { $0 == ">" }
            let inner = rest.prefix(while: { $0 == " " || $0 == "\t" })
            if columns(inner) >= 4 {
                out.append(String(line))
                continue
            }
            prefix += inner
            rest = rest[inner.endIndex...]
            if let open = fence, !markers.hasPrefix(open.markers) {
                fence = nil // the fence's container ended on this line
            }
            if let run = fenceRun(rest) {
                if let open = fence {
                    if markers == open.markers, run.char == open.char, run.length >= open.length, run.rest.isEmpty {
                        fence = nil
                    }
                } else {
                    fence = (run.char, run.length, markers)
                }
                out.append(String(line))
                continue
            }
            if fence == nil, isReferenceDefinition(rest) {
                out.append(indent + prefix + "\\" + rest)
                changed = true
            } else {
                out.append(String(line))
            }
        }
        return changed ? out.joined(separator: "\n") : source
    }

    private static func columns(_ whitespace: Substring) -> Int {
        whitespace.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    /// A fence marker at the start of a (whitespace-trimmed) line: three or
    /// more backticks or tildes. `rest` is what follows the run.
    private static func fenceRun(_ line: Substring) -> (char: Character, length: Int, rest: Substring)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let run = line.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        let rest = line[run.endIndex...].drop(while: { $0 == " " || $0 == "\t" })
        return (first, run.count, rest)
    }

    /// Peels any run of block-quote markers (`>` plus one optional space)
    /// and list markers (`-`, `*`, `+`, or up to nine digits with `.` or
    /// `)`, each followed by at least one space) off the front of a line.
    private static func containerPrefix(_ line: Substring) -> (prefix: String, rest: Substring) {
        var rest = line
        var prefix = ""
        while true {
            // Up to three spaces may precede a nested marker; more is
            // indented code, which the caller's inner-indent rule handles.
            let gap = rest.prefix(while: { $0 == " " })
            if !gap.isEmpty {
                let after = rest[gap.endIndex...]
                let startsMarker = after.first == ">" || after.first == "-" || after.first == "*"
                    || after.first == "+" || (after.first?.isNumber ?? false)
                guard gap.count <= 3, startsMarker else { return (prefix, rest) }
                let (nested, nestedRest) = containerPrefix(after)
                guard !nested.isEmpty else { return (prefix, rest) }
                return (prefix + gap + nested, nestedRest)
            }
            if rest.first == ">" {
                var end = rest.index(after: rest.startIndex)
                if end < rest.endIndex, rest[end] == " " { end = rest.index(after: end) }
                prefix += rest[rest.startIndex..<end]
                rest = rest[end...]
                continue
            }
            var markerEnd: Substring.Index?
            if let first = rest.first, first == "-" || first == "*" || first == "+" {
                markerEnd = rest.index(after: rest.startIndex)
            } else {
                let digits = rest.prefix(while: \.isNumber)
                if (1...9).contains(digits.count), digits.endIndex < rest.endIndex,
                   rest[digits.endIndex] == "." || rest[digits.endIndex] == ")" {
                    markerEnd = rest.index(after: digits.endIndex)
                }
            }
            if let markerEnd, markerEnd < rest.endIndex, rest[markerEnd] == " " {
                let afterSpace = rest.index(after: markerEnd)
                prefix += rest[rest.startIndex..<afterSpace]
                rest = rest[afterSpace...]
                continue
            }
            return (prefix, rest)
        }
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
        let rest = line[line.index(after: afterClose)...].drop(while: { $0 == " " || $0 == "\t" })
        return !rest.isEmpty
    }
}
