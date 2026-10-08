import Foundation

/// What the user typed, parsed once into the pieces every query path needs.
///
/// The rule the search UI promises ("matches words that
/// aren't what you typed"): a message matches when it contains EVERY typed
/// word, as typed. Only the word still being typed (the last one, when the
/// text does not end in a space) also matches as the start of a longer word,
/// so results don't blink out mid-word. Messages containing the words as one
/// exact phrase rank above messages that merely contain them all.
///
/// The index is tokenized `porter unicode61`, so FTS alone matches stems
/// ("running" finds "run", "crisis" finds "crises"). Changing the tokenizer
/// means rebuilding an index of several hundred MB at open, so the stem-only
/// matches are filtered out at query time instead: each plain word must also
/// appear literally in the body (`literalPatterns`, a `LIKE` over the rows
/// FTS already narrowed to).
public struct SearchQuery: Equatable, Sendable {
    /// The typed words, in order, minus any with nothing a tokenizer keeps
    /// (a bare `++` or an emoji).
    public let terms: [String]
    /// The last word is still being typed, so it also matches as a prefix.
    public let lastTermIsPrefix: Bool

    /// Fewer characters than this and message search is skipped: one letter
    /// matches most of the index (the letter "t" hit 480,754 of 692,425
    /// messages in one real index) and none of those results mean anything.
    public static let minimumSearchableLength = 2

    public init?(_ text: String) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let kept = words.filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        guard !kept.isEmpty else { return nil }
        terms = kept
        // A dropped trailing word (punctuation only) still means the word
        // before it is finished.
        lastTermIsPrefix = !(text.last?.isWhitespace ?? true) && words.last == kept.last
    }

    /// Whether there is enough here to run a message search.
    public var isSearchable: Bool {
        terms.reduce(0) { $0 + $1.count } >= Self.minimumSearchableLength
    }

    /// FTS5 `MATCH` for "contains every word": each word double-quoted (so
    /// nothing typed is read as FTS syntax) and implicitly ANDed, the last
    /// one prefix-matched while it is still being typed.
    public var allTermsMatch: String {
        var parts = terms.map(Self.quoted)
        if lastTermIsPrefix { parts[parts.count - 1] += "*" }
        return parts.joined(separator: " ")
    }

    /// FTS5 `MATCH` for the top tier: the words as one phrase, whole words
    /// only.
    public var exactMatch: String {
        Self.quoted(terms.joined(separator: " "))
    }

    /// Whether the exact tier can differ from the all-terms tier. A single
    /// finished word is its own exact match.
    public var hasDistinctExactTier: Bool {
        terms.count > 1 || lastTermIsPrefix
    }

    /// `LIKE` patterns (escape character `\`) a body must satisfy to count as
    /// containing the words literally, one per plain word. Words with
    /// anything but ASCII letters and digits are left to FTS alone: `LIKE`
    /// folds case only for ASCII, and punctuation differs between what is
    /// typed and what is stored (a straight vs a curly apostrophe).
    public var literalPatterns: [String] {
        terms.filter(Self.isPlain).map { "%\(Self.likeEscaped($0))%" }
    }

    /// `LIKE` pattern for the exact tier — the whole phrase, literally — or
    /// `nil` when a word isn't plain (see `literalPatterns`).
    public var exactLiteralPattern: String? {
        guard terms.allSatisfy(Self.isPlain) else { return nil }
        return "%\(terms.map(Self.likeEscaped).joined(separator: " "))%"
    }

    private static func quoted(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func isPlain(_ term: String) -> Bool {
        term.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    private static func likeEscaped(_ term: String) -> String {
        term.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

/// Builds the preview line for a search hit from the message body: a window
/// around the first place the query appears, with the typed words wrapped in
/// `<mark>…</mark>` (the markup `SearchResultRow` renders).
///
/// Done here rather than with FTS5's `snippet()` so the highlight is what
/// was typed — `snippet()` marks whatever the stemmer matched — and so the
/// preview opens on the phrase when the message has it.
public enum SearchSnippet {
    /// Characters of context kept before the first match.
    static let leadingContext = 40
    /// Total characters of body shown.
    static let windowLength = 160

    public static func make(body: String, query: SearchQuery) -> String {
        // One line: a preview row has no use for the message's line breaks.
        // And no markup of its own — a message that quotes `<mark>` (this
        // code being discussed in a chat) must not be read as a highlight.
        let flat = body.replacingOccurrences(of: "<mark>", with: "")
            .replacingOccurrences(of: "</mark>", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let whole = flat[...]
        let needles = needles(for: query)
        let phrase = Needle(text: query.terms.joined(separator: " "), wholeWord: !query.lastTermIsPrefix)
        let anchor = first(phrase, in: whole, from: whole.startIndex)?.lowerBound
            ?? needles.compactMap { occurrences(of: $0, in: whole).first?.lowerBound }.min()

        var start = flat.startIndex
        if let anchor, flat.distance(from: flat.startIndex, to: anchor) > leadingContext {
            start = flat.index(anchor, offsetBy: -leadingContext)
            // Open on a whole word.
            if let space = flat[start..<anchor].firstIndex(of: " ") { start = flat.index(after: space) }
        }
        let end = flat.index(start, offsetBy: windowLength, limitedBy: flat.endIndex) ?? flat.endIndex
        let window = flat[start..<end]

        var result = start > flat.startIndex ? "…" : ""
        var cursor = window.startIndex
        for range in highlightRanges(in: window, needles: needles) {
            result += window[cursor..<range.lowerBound]
            result += "<mark>\(window[range])</mark>"
            cursor = range.upperBound
        }
        result += window[cursor...]
        if end < flat.endIndex { result += "…" }
        return result
    }

    /// One typed word as the preview looks for it. A finished word is
    /// looked for as a whole word; the word still being typed also as the
    /// start of a longer one — the same rule the query matches by.
    private struct Needle {
        let text: String
        let wholeWord: Bool
    }

    private static func needles(for query: SearchQuery) -> [Needle] {
        query.terms.enumerated().map { index, term in
            Needle(text: term, wholeWord: !(query.lastTermIsPrefix && index == query.terms.count - 1))
        }
    }

    /// Where `needle` appears in `text`. A finished word that appears only
    /// inside a longer one ("time" matched through "times") falls back to
    /// those word starts, so the row still shows why it matched.
    private static func occurrences(of needle: Needle, in text: Substring) -> [Range<String.Index>] {
        func all(_ needle: Needle) -> [Range<String.Index>] {
            var found: [Range<String.Index>] = []
            var from = text.startIndex
            while let range = first(needle, in: text, from: from) {
                found.append(range)
                from = range.upperBound
            }
            return found
        }
        let strict = all(needle)
        guard strict.isEmpty, needle.wholeWord else { return strict }
        return all(Needle(text: needle.text, wholeWord: false))
    }

    /// Every occurrence of every typed word in `text`, merged where they
    /// overlap or sit side by side, in order.
    private static func highlightRanges(in text: Substring, needles: [Needle]) -> [Range<String.Index>] {
        let ranges = needles.flatMap { occurrences(of: $0, in: text) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            // Words separated only by a space read as one highlight, so a
            // phrase is marked as the phrase.
            if let last = merged.last,
               range.lowerBound <= last.upperBound
                || text[last.upperBound..<range.lowerBound].allSatisfy(\.isWhitespace) {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The first place `needle` appears in `text` at the start of a word
    /// (and, for a whole-word needle, ending one), ignoring case. Mid-word
    /// occurrences are skipped ("time" inside "sometimes"): the index
    /// matches words and word prefixes, never infixes, so that is not
    /// where the hit is.
    private static func first(_ needle: Needle, in text: Substring,
                              from: String.Index) -> Range<String.Index>? {
        func isWordCharacter(_ character: Character) -> Bool { character.isLetter || character.isNumber }
        var searchFrom = from
        while searchFrom < text.endIndex,
              let range = text[searchFrom...].range(of: needle.text, options: .caseInsensitive) {
            let startsWord = range.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: range.lowerBound)])
            let endsWord = range.upperBound == text.endIndex || !isWordCharacter(text[range.upperBound])
            if startsWord && (endsWord || !needle.wholeWord) { return range }
            searchFrom = text.index(after: range.lowerBound)
        }
        return nil
    }
}
