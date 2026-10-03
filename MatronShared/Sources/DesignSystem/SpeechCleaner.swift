import Foundation

/// Markdown → words worth saying out loud (voice mode, spec 2026-10-03 §3,
/// "The cleaner"). Deterministic, no model: the same parse both renderers
/// use (`MarkdownSource.prepared` + Foundation's full Markdown syntax, read
/// through `BlockKind`), so what the cleaner leaves out of speech is exactly
/// what a later stage can put on screen (§8).
///
/// Dropped: code blocks, diffs, tables, images and URLs. A table, a code
/// block and a diff each leave one short sentence saying it is in the chat.
/// Kept: link text, heading and list-item text (without their markers).
/// `[#12](matron://item/12)` reads "item twelve".
///
/// Foundation only: no UIKit, no SwiftUI, so every platform's voice engine
/// can call it.
public enum SpeechCleaner {
    /// One block of a message, as speech.
    public struct Block: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case heading, prose, notice }
        public let kind: Kind
        public let text: String
    }

    public static let tableNotice = "There's a table in the chat."
    public static let codeNotice = "There's code in the chat."
    public static let diffNotice = "There's a diff in the chat."

    /// About a minute of speech at 150 words a minute.
    public static let wordsPerSection = 150
    /// The contract's cap on a level-1 line (`spoken`, 400 characters).
    public static let shortLimit = 400

    // MARK: Whole message

    /// The whole message as one speakable string.
    public static func speakable(_ markdown: String) -> String {
        blocks(markdown).map(\.text).joined(separator: " ")
    }

    /// Level 1 when the bridge sent no `spoken` line: the first two
    /// sentences and, when the message ends with a question that those two
    /// did not already include, that question.
    public static func fallbackShort(_ markdown: String) -> String {
        let all = blocks(markdown).filter { $0.kind != .heading }.map(\.text).joined(separator: " ")
        let parts = sentences(all)
        guard !parts.isEmpty else { return "" }
        var picked = Array(parts.prefix(2))
        if parts.count > 2, let last = parts.last, last.hasSuffix("?") { picked.append(last) }
        return clipped(picked.joined(separator: " "), to: shortLimit)
    }

    /// Level 3: the message itself, about a minute at a time. A heading
    /// starts a new section; paragraphs fill a section up to
    /// `wordsPerSection`; a paragraph longer than that is cut at sentences.
    public static func sections(_ markdown: String, wordsPerSection limit: Int = wordsPerSection) -> [String] {
        var out: [String] = []
        var current: [String] = []
        var count = 0
        func flush() {
            if !current.isEmpty { out.append(current.joined(separator: " ")) }
            current = []
            count = 0
        }
        for block in blocks(markdown) {
            if block.kind == .heading { flush() }
            for piece in pieces(of: block.text, limit: limit) {
                let words = wordCount(piece)
                if count > 0, count + words > limit { flush() }
                current.append(piece)
                count += words
            }
        }
        flush()
        return out
    }

    // MARK: Blocks

    /// The message block by block, in order, with everything unsayable
    /// removed. Consecutive table cells are one notice; so is each code
    /// block.
    public static func blocks(_ markdown: String) -> [Block] {
        let source = MarkdownSource.prepared(markdown)
        guard let attributed = try? AttributedString(
            markdown: source,
            options: .init(allowsExtendedAttributes: true, interpretedSyntax: .full,
                           failurePolicy: .returnPartiallyParsedIfPossible)
        ) else {
            let plain = tidy(strippingURLs(markdown))
            return plain.isEmpty ? [] : [Block(kind: .prose, text: plain)]
        }

        var out: [Block] = []
        var openIntent: PresentationIntent?
        var openKind: BlockKind?
        var openText = ""
        var started = false
        var lastWasTable = false

        func close() {
            guard started, let kind = openKind else { return }
            switch kind {
            case .tableCell:
                if !lastWasTable { out.append(Block(kind: .notice, text: tableNotice)) }
                lastWasTable = true
            case .codeBlock(let language):
                out.append(Block(kind: .notice, text: language?.lowercased() == "diff" ? diffNotice : codeNotice))
                lastWasTable = false
            case .header:
                let text = sentence(tidy(strippingURLs(openText)))
                if !text.isEmpty { out.append(Block(kind: .heading, text: text)) }
                lastWasTable = false
            case .paragraph, .blockQuote, .listItem:
                let text = sentence(tidy(strippingURLs(openText)))
                if !text.isEmpty { out.append(Block(kind: .prose, text: text)) }
                lastWasTable = false
            }
        }

        for run in attributed.runs {
            let intent = run.presentationIntent
            if !started || intent != openIntent {
                close()
                openIntent = intent
                openKind = BlockKind(intent)
                openText = ""
                started = true
            }
            if run.imageURL != nil { continue }
            let text = String(attributed[run.range].characters)
            if let link = run.link {
                if let number = MatronItemLink.itemNumber(from: link) {
                    openText += "item \(spelled(number))"
                } else if !looksLikeURL(text) {
                    openText += text
                }
                continue
            }
            openText += text
        }
        close()
        return out
    }

    // MARK: Pieces

    /// `text` whole when it fits `limit` words, else cut at sentence ends
    /// into runs that do.
    private static func pieces(of text: String, limit: Int) -> [String] {
        guard wordCount(text) > limit else { return [text] }
        var out: [String] = []
        var current: [String] = []
        var count = 0
        for part in sentences(text) {
            let words = wordCount(part)
            if count > 0, count + words > limit {
                out.append(current.joined(separator: " "))
                current = []
                count = 0
            }
            current.append(part)
            count += words
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { part, _, _, _ in
            let trimmed = (part ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(trimmed) }
        }
        return out
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }

    /// Cuts at the last sentence end that fits, else at the last word.
    private static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        var kept = ""
        for part in sentences(text) {
            let next = kept.isEmpty ? part : kept + " " + part
            if next.count > limit { break }
            kept = next
        }
        if !kept.isEmpty { return kept }
        let cut = String(text.prefix(limit))
        guard let space = cut.lastIndex(of: " ") else { return cut }
        return String(cut[..<space])
    }

    // MARK: Text

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(?:[a-z][a-z0-9+.-]*://|www\.)[^\s<>()]+"#, options: [.caseInsensitive])

    /// A link whose text is its own address (an autolink): nothing to say.
    private static func looksLikeURL(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = urlPattern.firstMatch(in: text, range: range) else { return false }
        return match.range == range
    }

    /// Bare addresses the parser left as text.
    private static func strippingURLs(_ text: String) -> String {
        urlPattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// One line, single spaces, and no space left stranded before the
    /// punctuation a removed link or image sat next to.
    private static func tidy(_ text: String) -> String {
        var collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for mark in [".", ",", ";", ":", "!", "?", ")"] {
            collapsed = collapsed.replacingOccurrences(of: " \(mark)", with: mark)
        }
        collapsed = collapsed.replacingOccurrences(of: "( ", with: "(")
        collapsed = collapsed.replacingOccurrences(of: "()", with: "")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    /// Ends the block like a sentence so blocks joined by a space do not
    /// run together ("Next steps Ship it" → "Next steps. Ship it.").
    private static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        if ".!?".contains(last) { return text }
        if last == ":" { return String(text.dropLast()) + "." }
        return text + "."
    }

    private static let speller: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_GB")
        return formatter
    }()

    /// 12 → "twelve".
    public static func spelled(_ number: Int) -> String {
        speller.string(from: NSNumber(value: number)) ?? String(number)
    }
}
