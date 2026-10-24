import Foundation

// The Search page's shapes: what the journal's `GET /search/all` answers
// (tracker entities and the conversations whose messages match), what a
// row opens, and the page as the shared view draws it. Plain values, so
// the view model builds the page and the design system draws it without
// either knowing the other.

/// One tracker entity a search matched — the entity a match rolled up to
/// (a milestone's mission, a comment's item). A memory has a `name` and no
/// `num`; its `title` is the memory's one-line description.
public struct GlobalSearchResult: Equatable, Sendable {
    /// What a hit is. A kind this build does not know is dropped when the
    /// answer is decoded rather than guessed at.
    public enum Kind: String, Sendable, CaseIterable {
        case item, mission, project, memory
    }

    public let kind: Kind
    public let id: String
    public let num: Int?
    public let name: String?
    public let title: String
    public let state: String?
    /// A milestone's or an item's mission, when the journal names it.
    public let missionNum: Int?
    /// The tier it was found in: "number", "exact", "words", "stemmed",
    /// "similar" or "some_words".
    public let why: String
    /// The field the match was in ("title", "body", "comment", …).
    public let field: String?
    /// Carries `**…**` match markers, and starts by repeating the entity's
    /// own name and title (`GlobalSearchText.snippetBeyondTitle`).
    public let snippet: String?

    public init(kind: Kind, id: String, num: Int? = nil, name: String? = nil, title: String,
                state: String? = nil, missionNum: Int? = nil, why: String = "exact",
                field: String? = nil, snippet: String? = nil) {
        self.kind = kind; self.id = id; self.num = num; self.name = name; self.title = title
        self.state = state; self.missionNum = missionNum; self.why = why; self.field = field
        self.snippet = snippet
    }

    /// Unique across kinds, for a list's identity.
    public var rowID: String { "\(kind.rawValue):\(id)" }

    /// The row's first line: a memory's name, else "#12 Title".
    public var label: String {
        if kind == .memory { return name ?? title }
        guard let num else { return title }
        return "#\(num) \(title)"
    }

    /// The row's second line: the matched text beyond the title it
    /// repeats; for a memory with nothing more, its description; else the
    /// entity's state.
    public var detail: String? {
        if let snippet, let beyond = GlobalSearchText.snippetBeyondTitle(snippet, heads: [name, title]) {
            return beyond
        }
        if kind == .memory, name != nil { return title }
        return state
    }

    /// How it was found, in words, for the loose tiers only.
    public var whyLabel: String? { GlobalSearchText.whyLabel(why) }

    /// What a tap opens. An item, mission or project opens by its number,
    /// as "Go to number" does; one the journal sent without a number
    /// cannot be opened.
    public var target: GlobalSearchTarget? {
        if kind == .memory { return .memory(name: name ?? id) }
        return num.map { .number($0) }
    }
}

/// One conversation whose messages match, best first.
public struct GlobalSearchChat: Equatable, Sendable {
    /// The conversation's newest matching message.
    public struct Top: Equatable, Sendable {
        public let seq: Int64
        public let ts: Date
        public let sender: String
        /// Text around the match, with `**…**` markers.
        public let excerpt: String

        public init(seq: Int64, ts: Date, sender: String, excerpt: String) {
            self.seq = seq; self.ts = ts; self.sender = sender; self.excerpt = excerpt
        }
    }

    public let convoID: String
    public let title: String
    /// Matching messages in the conversation.
    public let count: Int
    /// It holds the query as an exact phrase.
    public let isExact: Bool
    public let isLive: Bool
    public let top: Top

    public init(convoID: String, title: String, count: Int, isExact: Bool = false, isLive: Bool = false, top: Top) {
        self.convoID = convoID; self.title = title; self.count = count; self.isExact = isExact
        self.isLive = isLive; self.top = top
    }

    /// "Title · 3 messages"; one match says no count.
    public var label: String {
        let title = title.isEmpty ? "Untitled" : title
        return count > 1 ? "\(title) · \(count) messages" : title
    }
}

/// What `GET /search/all` answered for one query.
public struct GlobalSearchResults: Equatable, Sendable {
    public let results: [GlobalSearchResult]
    public let chats: [GlobalSearchChat]

    public init(results: [GlobalSearchResult], chats: [GlobalSearchChat]) {
        self.results = results; self.chats = chats
    }
}

/// Where a Search row leads.
public enum GlobalSearchTarget: Equatable, Sendable {
    /// An item, mission or project, opened the way "Go to number" opens it.
    case number(Int)
    case memory(name: String)
    case conversation(String)
    /// A conversation opened on its newest matching message, with its
    /// in-conversation search armed.
    case message(convoID: String, seq: Int64)
}

/// The chips that narrow the page to one kind.
public enum GlobalSearchFilter: String, Sendable, CaseIterable, Identifiable {
    case all, conversations, items, missions, projects, memories, messages

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .conversations: return "Conversations"
        case .items: return "Items"
        case .missions: return "Missions"
        case .projects: return "Projects"
        case .memories: return "Memories"
        case .messages: return "Messages"
        }
    }

    /// The chip that shows a result kind's section.
    public init(_ kind: GlobalSearchResult.Kind) {
        switch kind {
        case .item: self = .items
        case .mission: self = .missions
        case .project: self = .projects
        case .memory: self = .memories
        }
    }

    /// Whether a section under `section`'s chip shows while this chip is
    /// chosen.
    public func shows(_ section: GlobalSearchFilter) -> Bool {
        self == .all || self == section
    }
}

/// Everything the Search page draws for the text in its field.
public struct GlobalSearchPage: Equatable, Sendable {
    /// A conversation whose title or latest message holds every word.
    public struct Conversation: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let subtitle: String?

        public init(id: String, title: String, subtitle: String?) {
            self.id = id; self.title = title; self.subtitle = subtitle
        }
    }

    /// The row for a query that is just a number: what carries it, marked
    /// "Go to", or why nothing opens.
    public struct NumberRow: Equatable, Sendable {
        /// "#412 · Item — Fix the parser", or what was said about the number.
        public let label: String
        /// Why a known number cannot be opened.
        public let note: String?
        /// Return (or a tap) opens it.
        public let canOpen: Bool

        public init(label: String, note: String? = nil, canOpen: Bool) {
            self.label = label; self.note = note; self.canOpen = canOpen
        }
    }

    public enum Status: Equatable, Sendable {
        /// Nothing typed.
        case empty
        case searching
        case failed
        /// The answer for the text in the field is in.
        case done
    }

    /// The text, trimmed.
    public let query: String
    public let status: Status
    public let number: NumberRow?
    public let conversations: [Conversation]
    /// Best match first; the number row's own entity left out.
    public let results: [GlobalSearchResult]
    public let chats: [GlobalSearchChat]

    public init(query: String, status: Status, number: NumberRow? = nil, conversations: [Conversation] = [],
                results: [GlobalSearchResult] = [], chats: [GlobalSearchChat] = []) {
        self.query = query; self.status = status; self.number = number; self.conversations = conversations
        self.results = results; self.chats = chats
    }

    /// The results of one kind, best first.
    public func results(_ kind: GlobalSearchResult.Kind) -> [GlobalSearchResult] {
        results.filter { $0.kind == kind }
    }

    /// The search is in and nothing at all matched.
    public var isEmptyResult: Bool {
        status == .done && number == nil && conversations.isEmpty && results.isEmpty && chats.isEmpty
    }
}

public enum GlobalSearchText {
    /// The journal runs a hit's own name and title into its snippet
    /// ("**Postgres** 16 migration Move the app…"). The row already shows
    /// the title, so those leading words go, markers and all, and what
    /// follows stays; a snippet that is only the title is `nil`. Each head
    /// is dropped only when every one of its words leads the snippet.
    public static func snippetBeyondTitle(_ snippet: String, heads: [String?]) -> String? {
        var rest = Substring(snippet)
        for head in heads {
            guard let head else { continue }
            let words = head.split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty else { continue }
            var cursor = rest.drop(while: \.isWhitespace)
            var matched = 0
            for word in words {
                let bare = cursor.hasPrefix("**") ? cursor.dropFirst(2) : cursor
                guard bare.lowercased().hasPrefix(word.lowercased()) else { break }
                var after = bare.dropFirst(word.count)
                if after.hasPrefix("**") { after = after.dropFirst(2) }
                cursor = after.drop(while: \.isWhitespace)
                matched += 1
            }
            if matched == words.count { rest = cursor }
        }
        let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "…" ? nil : trimmed
    }

    /// How a hit was found, in words. The strict tiers need no label.
    public static func whyLabel(_ why: String) -> String? {
        switch why {
        case "stemmed": return "similar words"
        case "similar": return "similar meaning"
        case "some_words": return "some words"
        default: return nil
        }
    }

    /// `text` split at its `**` markers: the odd parts sat between a pair
    /// and are the matches. A dangling marker leaves its tail marked,
    /// which is harmless.
    public static func markedRuns(_ text: String) -> [(text: String, isMatch: Bool)] {
        var runs: [(text: String, isMatch: Bool)] = []
        for (index, part) in text.components(separatedBy: "**").enumerated() where !part.isEmpty {
            runs.append((text: part, isMatch: index % 2 == 1))
        }
        return runs
    }
}
