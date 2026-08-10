#if os(macOS)
import AppKit

/// Rebuilds markdown source from a range of a `MarkdownAttributed`-rendered
/// string, driven by the `MarkdownRunSemantics` annotations laid down at build
/// time. Pure and deterministic: (attributed string, range) → markdown.
///
/// Best-effort by design: a partial selection inside a styled run wraps the
/// fragment; nesting/indentation flattened by rendering stays flat. The
/// full-selection case is handled upstream by `MessageCopyTextView`, which
/// copies the original source verbatim instead of calling this.
enum MarkdownReconstruction {

    static func markdown(from attributed: NSAttributedString, in range: NSRange) -> String {
        var blocks: [Block] = []

        attributed.enumerateAttribute(MarkdownAttributed.semanticsKey, in: range) { value, subrange, _ in
            let text = (attributed.string as NSString).substring(with: subrange)
            guard let semantics = value as? MarkdownRunSemantics else {
                // Unannotated text (parse-failure fallback) passes through
                // verbatim as its own pseudo-block.
                if blocks.last?.identity == Block.verbatimIdentity {
                    blocks[blocks.count - 1].segments.append(Segment(text: text, inline: [], link: nil))
                } else {
                    blocks.append(Block(
                        kind: .paragraph,
                        identity: Block.verbatimIdentity,
                        segments: [Segment(text: text, inline: [], link: nil)]
                    ))
                }
                return
            }
            let segment = Segment(text: text, inline: semantics.inline, link: semantics.link)
            if blocks.last?.identity == semantics.blockIdentity {
                blocks[blocks.count - 1].segments.append(segment)
            } else {
                blocks.append(Block(kind: semantics.block, identity: semantics.blockIdentity, segments: [segment]))
            }
        }

        var output = ""
        var previous: Block?
        for block in blocks {
            if let previous {
                output += separator(from: previous, to: block)
            }
            output += render(block)
            previous = block
        }
        return output
    }

    // MARK: - Model

    private struct Segment {
        let text: String
        let inline: MarkdownInlineFlags
        let link: URL?
    }

    private struct Block {
        /// Identity for coalescing unannotated pass-through text.
        static let verbatimIdentity = Int.min
        let kind: BlockKind
        let identity: Int
        var segments: [Segment]
    }

    // MARK: - Block rendering

    /// Consecutive list items are separated by a single newline (a blank line
    /// would split the markdown list); everything else gets a blank line.
    /// Verbatim pass-through blocks keep the newlines they carried, so they
    /// join with nothing.
    private static func separator(from previous: Block, to next: Block) -> String {
        if previous.identity == Block.verbatimIdentity || next.identity == Block.verbatimIdentity {
            return ""
        }
        if case .listItem = previous.kind, case .listItem = next.kind { return "\n" }
        return "\n\n"
    }

    private static func render(_ block: Block) -> String {
        if block.identity == Block.verbatimIdentity {
            return block.segments.map(\.text).joined()
        }

        // Code blocks reproduce their text verbatim inside fences — inline
        // flags never apply there (the mono font is block presentation).
        if case .codeBlock(let language) = block.kind {
            let body = trimTrailingNewlines(block.segments.map(\.text).joined())
            return "```\(language ?? "")\n\(body)\n```"
        }

        var text = trimTrailingNewlines(inlineMarkdown(block.segments))

        switch block.kind {
        case .header(let level):
            text = String(repeating: "#", count: level) + " " + text
        case .blockQuote:
            text = text
                .components(separatedBy: "\n")
                .map { "> " + $0 }
                .joined(separator: "\n")
        case .listItem:
            // The rendered marker is part of the text ("• " / "N. ").
            // Translate the bullet; ordered markers are already markdown. A
            // partial selection that missed the marker stays markerless.
            if text.hasPrefix("\u{2022} ") {
                text = "- " + text.dropFirst(2)
            }
        case .paragraph, .codeBlock:
            break
        }
        return text
    }

    private static func trimTrailingNewlines(_ text: String) -> String {
        var text = text
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    // MARK: - Inline rendering

    /// Delimiter emission order: outermost first. Closing happens in reverse.
    private static let delimiterOrder: [(flag: MarkdownInlineFlags, delimiter: String)] = [
        (.bold, "**"),
        (.italic, "*"),
        (.strikethrough, "~~"),
        (.code, "`"),
    ]

    /// Streams segments through an open-delimiter stack so nested styles emit
    /// properly nested markdown (`**bold *both* bold**`) instead of broken
    /// adjacent pairs (`**bold ***both*** bold**`). Whitespace at style edges
    /// is shifted outside the delimiters — `** bold**` doesn't parse.
    private static func inlineMarkdown(_ segments: [Segment]) -> String {
        var output = ""
        var open: [MarkdownInlineFlags] = []

        func close(downTo keep: Int) {
            while open.count > keep {
                let flag = open.removeLast()
                let delimiter = delimiterOrder.first { $0.flag == flag }!.delimiter
                // Shift trailing spaces/tabs outside the closing delimiter.
                var trailing = ""
                while let last = output.last, last == " " || last == "\t" {
                    trailing = String(output.removeLast()) + trailing
                }
                output += delimiter + trailing
            }
        }

        for segment in segments {
            if let link = segment.link {
                // A link renders as its own unit; close everything first so
                // the bracket never splits an emphasis span.
                close(downTo: 0)
                output += "[\(segment.text)](\(link.absoluteString))"
                continue
            }

            let target = delimiterOrder.map(\.flag).filter { segment.inline.contains($0) }
            let common = zip(open, target).prefix { $0 == $1 }.count
            close(downTo: common)

            var text = segment.text
            for flag in target.dropFirst(open.count) {
                // Shift leading whitespace outside the opening delimiter.
                while let first = text.first, first == " " || first == "\t" {
                    output += String(text.removeFirst())
                }
                output += delimiterOrder.first { $0.flag == flag }!.delimiter
                open.append(flag)
            }
            output += text
        }
        close(downTo: 0)
        return output
    }
}
#endif
