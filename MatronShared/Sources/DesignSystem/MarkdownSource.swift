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
        var inFence = false
        var changed = false
        var lines: [Substring] = []
        var out: [String] = []
        source.split(separator: "\n", omittingEmptySubsequences: false).forEach { lines.append($0) }
        for line in lines {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                out.append(String(line))
                continue
            }
            if !inFence, isReferenceDefinition(trimmed) {
                let indent = line.prefix(line.count - trimmed.count)
                out.append(indent + "\\" + trimmed)
                changed = true
            } else {
                out.append(String(line))
            }
        }
        return changed ? out.joined(separator: "\n") : source
    }

    /// `[label]:` with a non-empty label (up to the first `]`) and at least
    /// one more character after the colon — the parser needs a destination.
    private static func isReferenceDefinition(_ line: Substring) -> Bool {
        guard line.first == "[", let close = line.firstIndex(of: "]") else { return false }
        let label = line[line.index(after: line.startIndex)..<close]
        guard !label.isEmpty, !label.contains("["), !label.contains("\n") else { return false }
        let afterClose = line.index(after: close)
        guard afterClose < line.endIndex, line[afterClose] == ":" else { return false }
        let rest = line[line.index(after: afterClose)...].drop(while: { $0 == " " || $0 == "\t" })
        return !rest.isEmpty
    }
}
