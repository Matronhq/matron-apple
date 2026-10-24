import Foundation
import Observation
import MatronChat
import MatronJournal
import MatronModels

/// Drives the Search page on both platforms: one field that searches
/// everything. Conversation titles are filtered in memory from the chat
/// list; items, missions, projects, memories and the conversations whose
/// messages match come from the journal (`GlobalSearching`), best match
/// first. A query that is just a number (`412`, `#412`) is also looked up
/// the way "Go to number" looks it up, shown first, and opened by Return
/// (`submit()`).
///
/// The view model outlives the page on the Mac and the tab on iPhone, so
/// coming back shows the text and its results again.
@MainActor @Observable
public final class GlobalSearchViewModel {
    /// The field's text. A change re-keys the number lookup at once; the
    /// journal is asked by `search()`, once typing pauses.
    public var query: String {
        didSet {
            guard query != oldValue else { return }
            number.text = query
        }
    }
    /// The chip the page is narrowed to.
    public var filter: GlobalSearchFilter = .all
    /// The number in the field, as "Go to number" knows it: what it names,
    /// and opening it.
    public let number: GoToNumberViewModel

    /// The journal's answer, with the text it answered. Shown only while
    /// that is still the text in the field: a stale answer never shows
    /// under new text.
    private struct Answer: Equatable {
        let query: String
        let results: GlobalSearchResults
        let failed: Bool
    }
    private var answer: Answer? = nil

    private let searcher: any GlobalSearching
    private let chats: @MainActor () -> [ChatSummary]
    private let debounce: Duration
    /// Bumped by every `search()`; a run only publishes while it is still
    /// the latest, so a slow answer for "pa" can't land under "parser".
    private var generation = 0

    /// Rows asked of the journal.
    static let resultLimit = 40
    /// The journal's longest query; anything longer is not sent.
    static let maxQueryLength = 256
    /// At most this many conversation titles show above the tracker hits.
    static let conversationLimit = 8

    /// - Parameters:
    ///   - text: what the field starts with.
    ///   - searcher: the journal's `GET /search/all`.
    ///   - chats: the current chat list, read on demand so a long-lived
    ///     view model sees new rooms and renamed titles.
    ///   - debounce: how long typing must pause before the journal is asked.
    ///   - number: the number lookup; its own debounce should be zero, as
    ///     `search()` has already waited.
    public init(text: String = "", searcher: any GlobalSearching,
                chats: @escaping @MainActor () -> [ChatSummary],
                debounce: Duration = .milliseconds(200), number: GoToNumberViewModel) {
        self.query = text
        self.searcher = searcher
        self.chats = chats
        self.debounce = debounce
        self.number = number
        number.text = text
    }

    /// Production wiring: numbers go through the "Go to number" resolver,
    /// and a found one opens through `openNumber`.
    public convenience init(text: String = "", searcher: any GlobalSearching,
                            chats: @escaping @MainActor () -> [ChatSummary],
                            resolver: GoToNumberResolver,
                            openNumber: @escaping (GoToNumberTarget) -> Void) {
        self.init(text: text, searcher: searcher, chats: chats,
                  number: GoToNumberViewModel(debounce: .zero, resolver: resolver, open: openNumber))
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Asks the journal about the current text, after `debounce`, and
    /// looks a number up beside it. Call it from a task keyed on the text
    /// (`.task(id:)`), so a newer keystroke cancels this run while it is
    /// still waiting.
    public func search() async {
        generation &+= 1
        let run = generation
        let text = Self.trimmed(query)
        guard !text.isEmpty else { return }
        // Too long to send: say "nothing matches" rather than leave the
        // page on "Searching…".
        guard text.count <= Self.maxQueryLength else {
            answer = Answer(query: text, results: GlobalSearchResults(results: [], chats: []), failed: false)
            return
        }
        if debounce > .zero {
            // Cancelled by a newer keystroke or by the page going away.
            guard (try? await Task.sleep(for: debounce)) != nil else { return }
        }
        guard run == generation else { return }
        // Beside the search, not before it: a number this device does not
        // hold costs a round trip to the journal.
        let number = self.number
        async let numberLookedUp: Void = Self.lookUp(number)
        if answer?.query != text || answer?.failed == true {
            let outcome: Answer
            do {
                outcome = Answer(query: text, results: try await searcher.searchAll(text, limit: Self.resultLimit),
                                 failed: false)
            } catch {
                outcome = Answer(query: text, results: GlobalSearchResults(results: [], chats: []), failed: true)
            }
            // A newer run owns the page now; a cancelled one (the page went
            // away) did not really fail.
            if run == generation, !Task.isCancelled { answer = outcome }
        }
        _ = await numberLookedUp
    }

    private nonisolated static func lookUp(_ number: GoToNumberViewModel) async {
        await number.lookUp()
    }

    /// Return in the field: a number opens what carries it, as "Go to
    /// number" did; any other text, or a number that leads nowhere, leaves
    /// the results on screen (the number row then says why). `true` when
    /// something opened.
    @discardableResult
    public func submit() async -> Bool {
        guard GoToNumber.parse(query) != nil else { return false }
        return await number.submit()
    }

    /// Everything the page draws for the text in the field.
    public var page: GlobalSearchPage {
        let text = Self.trimmed(query)
        guard !text.isEmpty else { return GlobalSearchPage(query: "", status: .empty) }
        let current = answer?.query == text ? answer : nil
        let status: GlobalSearchPage.Status
        if let current {
            status = current.failed ? .failed : .done
        } else {
            status = .searching
        }
        var results = current?.results.results ?? []
        // The number row stands for its own entity: it is not listed twice.
        if case .found(let hit) = number.status {
            results.removeAll { $0.num == hit.num && $0.kind.rawValue == hit.kind.rawValue }
        }
        return GlobalSearchPage(query: text, status: status, number: numberRow,
                                conversations: Self.matchingConversations(chats(), query: text),
                                results: results, chats: current?.results.chats ?? [])
    }

    /// The "Go to" row for a number in the field: what carries it, or why
    /// nothing opens. None while it is looked up, or for other text.
    var numberRow: GlobalSearchPage.NumberRow? {
        guard GoToNumber.parse(query) != nil else { return nil }
        switch number.status {
        case .idle, .looking:
            return nil
        case .found(let hit):
            return GlobalSearchPage.NumberRow(label: hit.label, note: hit.cannotOpenReason,
                                              canOpen: hit.cannotOpenReason == nil)
        case .nothing(let message), .failed(let message):
            return GlobalSearchPage.NumberRow(label: message, canOpen: false)
        }
    }

    /// Conversations whose title or latest message holds every word of the
    /// query, as the Conversations search matches them.
    static func matchingConversations(_ chats: [ChatSummary], query: String) -> [GlobalSearchPage.Conversation] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let matching = chats.filter { chat in
            let text = "\(chat.title) \(chat.snippet)".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        return matching.prefix(conversationLimit).map { chat in
            GlobalSearchPage.Conversation(id: chat.id, title: chat.title.isEmpty ? "Untitled" : chat.title,
                                          subtitle: chat.snippet.isEmpty ? nil : chat.snippet)
        }
    }
}
