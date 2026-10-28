import Foundation
import Observation

// The title beside a tracker link.
//
// Agents sometimes link a real number that is not the one they meant, and a
// bare `#412` gives the reader no way to tell. So every tracker link in
// rendered markdown shows what its number really is: a small chip after the
// link with its kind and title, unless the link text already names it.
// When the link text names a different title, says a different number, or
// the number does not exist, the chip is drawn in the error colour so the
// wrong link stands out at a glance. When the journal cannot be asked, the
// link renders as it always did.
//
// The pieces: `TrackerLinkTitleRule` (the matching rule, the same one the
// bridge refuses agents' links with and the web client shows), `TrackerLinkChip`
// (what one link's chip says), `TrackerLinkTitles` (the per-session lookup
// cache a window or shell holds, reached through `TrackerNumberLinks.titles`)
// and `MarkdownAttributed.rendered(for:style:cache:trackerLinks:)`, which
// draws the chips into the rendered text.

// MARK: - Matching rule

/// Whether a title written in a link names its target. Ported line for line
/// from the web client (and the bridge, which refuses agents' links with it);
/// keep them in step.
public enum TrackerLinkTitleRule {
    private static let stopwords: Set<String> = [
        "a", "an", "the", "of", "to", "for", "and", "or", "on", "in", "at", "by", "with", "from",
        "is", "it", "this", "that", "item", "one", "new",
    ]

    /// Words a link label uses without naming anything ("click here", "read more").
    private static let generic: Set<String> = [
        "here", "click", "read", "more", "see", "link", "open", "view", "details", "this", "that", "it",
    ]

    private static let marks = try! NSRegularExpression(pattern: "\\p{M}+")
    private static let separators = try! NSRegularExpression(pattern: "[^\\p{L}\\p{N}]+")

    /// An address in a title is one word, compared whole and as written
    /// (paths are case-sensitive): its pieces (https, the host, the path's
    /// words) would otherwise match any other title that carries an address
    /// on the same site.
    private static let address = try! NSRegularExpression(
        pattern: "[a-z][a-z0-9+.-]*://[^\\s<>\"'\\[\\]]+", options: [.caseInsensitive])

    /// The address as written, without what wraps or follows it: a full
    /// stop, a trailing slash, or a closing parenthesis it did not open
    /// ("(see https://…)"). A trailing "..." becomes "…": cut short.
    /// One character at a time, so "..." is seen even when a parenthesis or
    /// comma follows it ("(…/pull/1...)").
    private static func trimAddress(_ text: String) -> String {
        var t = text
        while let last = t.last {
            if t.hasSuffix("...") {
                t = String(t.dropLast(3)) + "…"
            } else if ".,;:!?/".contains(last) {
                t.removeLast()
            } else if last == ")", t.filter({ $0 == "(" }).count < t.filter({ $0 == ")" }).count {
                t.removeLast()
            } else {
                break
            }
        }
        return t
    }

    private static func plainWords(_ text: String) -> [String] {
        replacing(separators, in: text.lowercased(), with: "\u{0}")
            .split(separator: "\u{0}", omittingEmptySubsequences: true)
            .map(String.init)
    }

    static func tokens(_ text: String) -> [String] {
        let plain = replacing(marks, in: text.decomposedStringWithCompatibilityMapping, with: "")
        let ns = plain as NSString
        var out: [String] = []
        var last = 0
        for match in address.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
            out += plainWords(ns.substring(with: NSRange(location: last, length: match.range.location - last)))
            out.append(trimAddress(ns.substring(with: match.range)))
            last = match.range.location + match.range.length
        }
        return out + plainWords(ns.substring(from: last))
    }

    private static func isAddress(_ t: String) -> Bool { t.contains("://") }

    /// The same address, or one cut short with an ellipsis and the address it
    /// starts: ".../pull/1" is not ".../pull/10", ".../pu…" is.
    private static func sameAddress(_ t: String, _ x: String?) -> Bool {
        guard let x else { return false }
        return t == x || (t.hasSuffix("…") && isAddress(x) && x.hasPrefix(String(t.dropLast())))
    }

    private static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if isAddress(a) || isAddress(b) { return false }
        return min(a.count, b.count) >= 3 && (a.hasPrefix(b) || b.hasPrefix(a))
    }

    /// Does `written` name the record titled `actual`? A prefix (the last
    /// word possibly cut short), an abbreviation, or a paraphrase that keeps
    /// most of the words passes; a title about something else does not, and
    /// neither does one naming an address the record's title does not have.
    public static func titleMatches(_ written: String, _ actual: String) -> Bool {
        let w = tokens(written)
        let a = tokens(actual)
        guard !w.isEmpty, !a.isEmpty else { return false }
        // An address names one thing: every address written must be in the title.
        guard w.allSatisfy({ t in !isAddress(t) || a.contains { sameAddress(t, $0) } }) else { return false }
        func atPosition(_ i: Int) -> Bool {
            let t = w[i]
            return isAddress(t) ? sameAddress(t, a[i]) : t == a[i] || (i == w.count - 1 && a[i].hasPrefix(t))
        }
        if w.count <= a.count, w.indices.allSatisfy(atPosition) { return true }
        // Most of the written words appear in the title (each address already does).
        let content = w.filter { !stopwords.contains($0) }
        let words = content.isEmpty ? w : content
        let hits = words.filter { t in isAddress(t) || a.contains { sameWord(t, $0) } }.count
        return hits >= min(2, words.count) && Double(hits) / Double(words.count) >= 0.6
    }

    /// Does a link's text say which record it means? A number does, an
    /// address does, and so do two or more words beyond the stopwords and
    /// pointing words ("here", "read more").
    static func claims(_ written: Written) -> Bool {
        let words = tokens(written.title)
        return written.num != nil
            || words.contains(where: isAddress)
            || words.filter { !stopwords.contains($0) && !generic.contains($0) }.count >= 2
    }

    /// The number and title written in a link's text.
    public struct Written: Equatable, Sendable {
        public let num: Int?
        public let title: String
        public init(num: Int?, title: String) { self.num = num; self.title = title }
    }

    private static let bareAddress = try! NSRegularExpression(
        pattern: "^[a-z][a-z0-9+.-]*://\\S*$", options: [.caseInsensitive])
    private static let emphasis = try! NSRegularExpression(pattern: "[*_`~]+")
    private static let numbered = try! NSRegularExpression(
        pattern: "^(?:(?:item|mission|milestone|project|question|task|decision|notice)\\s+)?#([1-9][0-9]{0,14})(?![\\p{L}\\p{N}])(.*)$",
        options: [.caseInsensitive])
    private static let leadingPunctuation = try! NSRegularExpression(pattern: "^[\\s:–—\\-·|,.(]+")
    private static let trailingParens = try! NSRegularExpression(pattern: "\\)+$")
    private static let quotes = try! NSRegularExpression(pattern: "^[\"'“‘«]+|[\"'”’»]+$")

    /// The number and title in a link's text: "#12 Title", "item #12: Title",
    /// "Title".
    public static func writtenLink(_ text: String) -> Written {
        // A link whose text is a URL (an autolinked `matron://item/68` or
        // `/u/…` link) names no title: it is a bare link.
        let whole = trim(text) as NSString
        if bareAddress.firstMatch(in: whole as String, range: NSRange(location: 0, length: whole.length)) != nil {
            return Written(num: nil, title: "")
        }
        let plain = trim(replacing(emphasis, in: text, with: " "))
        let ns = plain as NSString
        let match = numbered.firstMatch(in: plain, range: NSRange(location: 0, length: ns.length))
        var title = match.map { ns.substring(with: $0.range(at: 2)) } ?? plain
        title = trim(title)
        title = replacing(leadingPunctuation, in: title, with: "")
        title = replacing(trailingParens, in: title, with: "")
        title = trim(title)
        title = replacing(quotes, in: title, with: "")
        title = trim(title)
        let num = match.flatMap { Int(ns.substring(with: $0.range(at: 1))) }
        return Written(num: num, title: title)
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                       withTemplate: template)
    }
}

// MARK: - Lookups

/// Whose number a link names, and the number. Items, missions, milestones
/// and projects share one number space per user.
public struct TrackerLinkTarget: Hashable, Sendable {
    public let user: String
    public let num: Int
    public init(user: String, num: Int) { self.user = user; self.num = num }
}

/// What the journal said a linked number is.
public enum TrackerLinkLookup: Hashable, Sendable {
    /// `kind` is item, mission, milestone or project.
    case found(kind: String, title: String?)
    /// The number names nothing the reader may see.
    case notFound
    /// The journal could not be asked. Never kept, and never drawn.
    case failed
}

/// What one tracker link's chip says.
public struct TrackerLinkChip: Hashable, Sendable {
    public let text: String
    /// Drawn in the error colour: the link names something else, or nothing.
    public let isMismatch: Bool
    /// What the number really is, for a tooltip.
    public let hint: String

    /// The chip for a link to `num` whose text is `linkText`; `nil` when the
    /// journal could not be asked, or when the text already names the target.
    public init?(lookup: TrackerLinkLookup, num: Int, linkText: String) {
        switch lookup {
        case .failed:
            return nil
        case .notFound:
            self.init(text: "not found", isMismatch: true, hint: "#\(num) does not exist, or is not visible to you")
        case .found(let kind, let title):
            let written = TrackerLinkTitleRule.writtenLink(linkText)
            let wrongNumber = written.num != nil && written.num != num
            guard let title, !title.isEmpty else {
                // No title to compare a written one with; a written number
                // that is not the link's is still wrong.
                if wrongNumber, let said = written.num {
                    self.init(text: kind, isMismatch: true, hint: "This link says #\(said) but goes to #\(num), a \(kind).")
                } else {
                    self.init(text: kind, isMismatch: false, hint: kind)
                }
                return
            }
            // The link already says what it points at: a chip would only
            // repeat it. A label like "here", or a lone word that happens to
            // start the title, says nothing, so it keeps the chip.
            let claimed = TrackerLinkTitleRule.claims(written)
            if !wrongNumber, claimed, !written.title.isEmpty, TrackerLinkTitleRule.titleMatches(written.title, title) {
                return nil
            }
            // Link text that names something ("#12 Some title", or a few
            // words) and does not match is flagged; a label like "here" or
            // "read more" is not a claim about the target.
            let mismatch = wrongNumber || (claimed && !written.title.isEmpty)
            var hint = title
            if wrongNumber, let said = written.num {
                hint = "This link says #\(said) but goes to #\(num), the \(kind) \"\(title)\"."
            } else if mismatch {
                hint = "#\(num) is not \"\(written.title)\": it is the \(kind) \"\(title)\"."
            }
            self.init(text: "\(kind) · \(title)", isMismatch: mismatch, hint: hint)
        }
    }

    init(text: String, isMismatch: Bool, hint: String) {
        self.text = text
        self.isMismatch = isMismatch
        self.hint = hint
    }
}

/// The answers a body's tracker links have, and how to read whose number a
/// link names: everything the renderer needs to draw their chips. A value,
/// so a row's content carries it and a new answer re-measures the row.
public struct TrackerLinkLookups: Hashable, Sendable {
    public let origin: TrackerLinkOrigin
    public let answers: [TrackerLinkTarget: TrackerLinkLookup]

    public init(origin: TrackerLinkOrigin, answers: [TrackerLinkTarget: TrackerLinkLookup]) {
        self.origin = origin
        self.answers = answers
    }

    /// No answer worth drawing.
    public var isEmpty: Bool { !answers.values.contains { $0 != .failed } }

    /// The chip for a link to `url` reading `linkText`, or `nil`.
    func chip(for url: URL, linkText: String) -> TrackerLinkChip? {
        guard let target = TrackerLinkRefs.target(of: url, origin: origin),
              let lookup = answers[target] else { return nil }
        return TrackerLinkChip(lookup: lookup, num: target.num, linkText: linkText)
    }
}

/// The tracker links in a markdown body.
public enum TrackerLinkRefs {
    /// Whose number `url` names: a `<journal>/u/<user>/<n>` link on the
    /// signed-in journal (anyone's), or `matron://item|mission|project/<n>`,
    /// which is the signed-in user's own.
    public static func target(of url: URL, origin: TrackerLinkOrigin) -> TrackerLinkTarget? {
        if let link = origin.link(in: url) { return TrackerLinkTarget(user: link.user, num: link.num) }
        if let num = MatronItemLink.itemNumber(from: url) { return TrackerLinkTarget(user: origin.user, num: num) }
        switch MatronItemLink.pageLink(from: url) {
        case .mission(let num)?, .project(let num)?: return TrackerLinkTarget(user: origin.user, num: num)
        default: return nil
        }
    }

    /// The distinct targets `markdown` links to, in order of first
    /// appearance. Parsed as the renderer parses, so a link inside code is
    /// not one. A body with no `matron://` and no `/u/` never reaches the
    /// parser, and parses are memoised by body.
    public static func targets(in markdown: String, origin: TrackerLinkOrigin, cache useCache: Bool = true) -> [TrackerLinkTarget] {
        guard markdown.contains("/u/") || markdown.range(of: "matron://", options: .caseInsensitive) != nil
        else { return [] }
        let key = "\(origin.scheme)://\(origin.host):\(origin.port ?? 0)\(origin.basePath)|\(origin.user)|\(markdown)" as NSString
        if useCache, let cached = cache.object(forKey: key) { return cached.targets }
        let targets = parse(markdown, origin: origin)
        if useCache { cache.setObject(Entry(targets), forKey: key) }
        return targets
    }

    private static func parse(_ markdown: String, origin: TrackerLinkOrigin) -> [TrackerLinkTarget] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: MarkdownSource.prepared(markdown), options: options)
        else { return [] }
        var seen = Set<TrackerLinkTarget>()
        var targets: [TrackerLinkTarget] = []
        for (link, _) in parsed.runs[\.link] {
            guard let link, let target = target(of: link, origin: origin), seen.insert(target).inserted else { continue }
            targets.append(target)
        }
        return targets
    }

    private final class Entry {
        let targets: [TrackerLinkTarget]
        init(_ targets: [TrackerLinkTarget]) { self.targets = targets }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 400
        return cache
    }()
}

// MARK: - Per-session cache

/// What the signed-in user's tracker links point at, looked up through the
/// journal's `GET /lookup` and kept for five minutes, so a chat full of
/// links to the same number asks once. Held for one session (it lives in
/// that session's `TrackerNumberLinks`), so a new session starts empty.
///
/// A renderer asks with `lookups(for:)`, which answers what is known now
/// and starts a lookup for anything missing or stale; the answer landing
/// changes `answers`, which the timelines and views observe. Requests in
/// flight are shared. A failure is not kept: the link shows no chip, and a
/// later render asks again once `failureRetry` has passed (a timeline
/// re-renders many times a second while an agent streams, and must not ask
/// the journal on every frame).
@MainActor @Observable
public final class TrackerLinkTitles {
    /// How long an answer is trusted.
    public static let freshFor: TimeInterval = 5 * 60
    /// How soon a failed lookup may be tried again.
    public static let failureRetry: TimeInterval = 30
    /// At most this many answers are kept.
    static let maxAnswers = 500

    /// Every answer this session has, the observed state.
    public private(set) var answers: [TrackerLinkTarget: TrackerLinkLookup] = [:]

    public let origin: TrackerLinkOrigin
    @ObservationIgnored private let lookup: @Sendable (String, Int) async -> TrackerLinkLookup
    @ObservationIgnored private let now: () -> Date
    /// When each answer, or failure, came back.
    @ObservationIgnored private var askedAt: [TrackerLinkTarget: Date] = [:]
    @ObservationIgnored private var inFlight: Set<TrackerLinkTarget> = []

    /// - Parameter lookup: asks the journal what `num` names in `user`'s
    ///   number space.
    public init(origin: TrackerLinkOrigin,
                lookup: @escaping @Sendable (_ user: String, _ num: Int) async -> TrackerLinkLookup,
                now: @escaping () -> Date = Date.init) {
        self.origin = origin
        self.lookup = lookup
        self.now = now
    }

    /// Test seam: whether a lookup is still out.
    var isLoading: Bool { !inFlight.isEmpty }

    /// Test and fixture seam: answers as if just looked up.
    func seed(_ seeded: [TrackerLinkTarget: TrackerLinkLookup]) {
        for (target, answer) in seeded { store(answer, for: target) }
    }

    /// What `markdown`'s tracker links are known to point at, for
    /// `MarkdownAttributed.rendered(for:style:cache:trackerLinks:)`. Starts
    /// a lookup for each link not yet known or gone stale. Reads `answers`,
    /// so an observing caller hears when one lands.
    public func lookups(for markdown: String, cache: Bool = true) -> TrackerLinkLookups {
        let targets = TrackerLinkRefs.targets(in: markdown, origin: origin, cache: cache)
        guard !targets.isEmpty else { return TrackerLinkLookups(origin: origin, answers: [:]) }
        var known: [TrackerLinkTarget: TrackerLinkLookup] = [:]
        for target in targets {
            if let answer = answers[target] { known[target] = answer }
            request(target)
        }
        return TrackerLinkLookups(origin: origin, answers: known)
    }

    private func request(_ target: TrackerLinkTarget) {
        guard !inFlight.contains(target) else { return }
        if let asked = askedAt[target] {
            let wait = answers[target] == nil ? Self.failureRetry : Self.freshFor
            if now().timeIntervalSince(asked) < wait { return }
        }
        inFlight.insert(target)
        let lookup = self.lookup
        Task { [weak self] in
            let answer = await lookup(target.user, target.num)
            self?.store(answer, for: target)
        }
    }

    private func store(_ answer: TrackerLinkLookup, for target: TrackerLinkTarget) {
        inFlight.remove(target)
        askedAt[target] = now()
        guard answer != .failed else {
            // Not kept: an answer from before stays shown until a lookup
            // succeeds, and nothing new is drawn for a failure.
            if answers[target] == nil { return }
            askedAt[target] = now().addingTimeInterval(Self.failureRetry - Self.freshFor)
            return
        }
        if answers[target] == nil, answers.count >= Self.maxAnswers,
           let oldest = askedAt.filter({ answers[$0.key] != nil }).min(by: { $0.value < $1.value })?.key {
            answers[oldest] = nil
            askedAt[oldest] = nil
        }
        if answers[target] != answer { answers[target] = answer }
    }
}

extension TrackerLinkTitles {
    /// A cache over `lookup(user:num:)`-shaped calls that throw: a
    /// `notFound` error means the number names nothing, anything else is a
    /// failure.
    public convenience init(origin: TrackerLinkOrigin,
                            find: @escaping @Sendable (_ user: String, _ num: Int) async throws -> (kind: String, title: String?),
                            isNotFound: @escaping @Sendable (Error) -> Bool) {
        self.init(origin: origin, lookup: { user, num in
            do {
                let hit = try await find(user, num)
                return .found(kind: hit.kind, title: hit.title)
            } catch {
                return isNotFound(error) ? .notFound : .failed
            }
        })
    }
}
