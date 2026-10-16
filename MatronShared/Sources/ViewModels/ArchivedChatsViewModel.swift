import Foundation
import MatronChat
import MatronModels

/// The Archived screen (iPhone) and sheet (Mac): every archived
/// conversation, most recently active first, filtered by what is typed in
/// its search field, with Unarchive.
@Observable
@MainActor
public final class ArchivedChatsViewModel {
    /// Every archived conversation, unfiltered.
    public private(set) var summaries: [ChatSummary] = []
    public private(set) var isLoading = true
    /// The search field's text.
    public var query = ""

    /// `summaries` matching `query`.
    public var filtered: [ChatSummary] { Self.filter(summaries, query: query) }

    private let chat: ChatService
    private var task: Task<Void, Never>?

    public init(chat: ChatService) {
        self.chat = chat
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let stream = self?.chat.archivedChatSummaries() else { return }
            for await snapshot in stream {
                guard let self, !Task.isCancelled else { return }
                if self.summaries != snapshot { self.summaries = snapshot }
                if self.isLoading { self.isLoading = false }
            }
            self?.isLoading = false
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    /// Brings the conversations back to the chat list.
    public func unarchive(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        await chat.setArchived(ids, archived: false)
    }

    /// The conversations whose title, snippet or box contains every word of
    /// `query`, ignoring case and accents. An empty query keeps them all.
    public nonisolated static func filter(_ summaries: [ChatSummary], query: String) -> [ChatSummary] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return summaries }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return summaries.filter { summary in
            let fields = [summary.title, summary.snippet, summary.boxName ?? "", summary.sessionShort ?? ""]
            return words.allSatisfy { word in fields.contains { $0.range(of: word, options: options) != nil } }
        }
    }
}
