import Foundation
import Observation

// The title beside a tracker link.
//
// Agents sometimes link a real number that is not the one they meant, and a
// bare `#412` gives the reader no way to tell. So every tracker link in
// rendered markdown shows what its number really is: a small chip after the
// link with its kind, and its title unless the link text already says it.
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
/// from the web client; keep the two in step.
public enum TrackerLinkTitleRule {
    private static let stopwords: Set<String> = [
        "a", "an", "the", "of", "to", "for", "and", "or", "on", "in", "at", "by", "with", "from",
        "is", "it", "this", "that", "item", "one", "new",
    ]

    private static let marks = try! NSRegularExpression(pattern: "\\p{M}+")
    private static let trailingEllipsis = try! NSRegularExpression(pattern: "(\\.\\.\\.|…)\\s*$")
    private static let separators = try! NSRegularExpression(pattern: "[^\\p{L}\\p{N}]+")

    static func tokens(_ text: String) -> [String] {
        var text = text.decomposedStringWithCompatibilityMapping
        text = replacing(marks, in: text, with: "")
        text = text.lowercased()
        text = replacing(trailingEllipsis, in: text, with: "")
        return replacing(separators, in: text, with: "\u{0}")
            .split(separator: "\u{0}", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        return min(a.utf16.count, b.utf16.count) >= 3 && (a.hasPrefix(b) || b.hasPrefix(a))
    }

    /// Does `written` name the record titled `actual`? A prefix (the last
    /// word possibly cut short), an abbreviation, or a paraphrase that keeps
    /// most of the words passes; a title about something else does not.
    public static func titleMatches(_ written: String, _ actual: String) -> Bool {
        let w = tokens(written)
        let a = tokens(actual)
        guard !w.isEmpty, !a.isEmpty else { return false }
        if w.count <= a.count, w.indices.allSatisfy({ i in
            w[i] == a[i] || (i == w.count - 1 && a[i].hasPrefix(w[i]))
        }) {
            return true
        }
        let content = w.filter { !stopwords.contains($0) }
        let words = content.isEmpty ? w : content
        let hits = words.filter { t in a.contains { sameWord(t, $0) } }.count
        return hits >= min(2, words.count) && Double(hits) / Double(words.count) >= 0.6
    }

    /// The number and title written in a link's text.
    public struct Written: Equatable, Sendable {
        public let num: Int?
        public let title: String
        public init(num: Int?, title: String) { self.num = num; self.title = title }
    }

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
    /// journal could not be asked.
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
                self.init(text: kind, isMismatch: false, hint: kind)
                return
            }
            if !wrongNumber, !written.title.isEmpty, TrackerLinkTitleRule.titleMatches(written.title, title) {
                self.init(text: kind, isMismatch: false, hint: title)
                return
            }
            // Link text that names something ("#12 Some title", or a few
            // words) and does not match is flagged; a one-word "here" is not
            // a claim about the target.
            let claims = written.num != nil || TrackerLinkTitleRule.tokens(written.title).count >= 2
            let mismatch = wrongNumber || (claims && !written.title.isEmpty)
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
        // A link written bare shows its own address, which names nothing.
        let text = linkText.contains("://") ? "" : linkText
        return TrackerLinkChip(lookup: lookup, num: target.num, linkText: text)
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
