import Foundation
import Observation
import MatronChat
import MatronJournal
import MatronModels
import MatronViewModels

/// The AppKit sidebar's data, on the main actor: hands `MacListView` the
/// feed's publications, tells the feed what the window decides beside the
/// rows (`MacSidebarChatContext`, watched through observation tracking on
/// the chat-list view model and the notification settings), and says
/// whether the list is empty, for the sidebar's empty state.
///
/// Cheap to make: nothing starts until `publications()` is called, which
/// `MacListView` does once, when its host is made.
@Observable @MainActor
final class MacSidebarChatSource {
    typealias Publication = MacSidebarChatFeed.Publication

    /// `nil` until the first publication; then whether it has no rows.
    /// Written only when it flips.
    private(set) var isEmpty: Bool?

    @ObservationIgnored private let viewModel: ChatListViewModel
    @ObservationIgnored private let notifyStore: NotifySettingsStore?
    @ObservationIgnored private let makeInputs: (AsyncStream<MacSidebarChatContext>) -> MacSidebarChatFeed.Inputs
    @ObservationIgnored private var contextContinuation: AsyncStream<MacSidebarChatContext>.Continuation?
    @ObservationIgnored private(set) var context: MacSidebarChatContext?
    @ObservationIgnored private var relay: Task<Void, Never>?
    /// Bumped per `publications()`, so an older stream ending stops nothing.
    @ObservationIgnored private var generation = 0
    /// Publications relayed (test seam).
    @ObservationIgnored private(set) var relayedCountForTesting = 0

    init(viewModel: ChatListViewModel, notifyStore: NotifySettingsStore?,
         inputs: @escaping (AsyncStream<MacSidebarChatContext>) -> MacSidebarChatFeed.Inputs) {
        self.viewModel = viewModel
        self.notifyStore = notifyStore
        self.makeInputs = inputs
    }

    convenience init(viewModel: ChatListViewModel, notifyStore: NotifySettingsStore?, store: JournalStore) {
        self.init(viewModel: viewModel, notifyStore: notifyStore) { contexts in
            MacSidebarChatFeed.inputs(store: store, contexts: contexts)
        }
    }

    /// The list's publications, for `MacListView`. A second call replaces
    /// the first stream.
    func publications() -> AsyncStream<Publication> {
        stop()
        generation += 1
        let generation = generation
        let (contexts, contextContinuation) = AsyncStream<MacSidebarChatContext>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        self.contextContinuation = contextContinuation
        context = nil
        trackContext()
        var inputs = makeInputs(contexts)
        // `trackContext()` has just read the context: the feed starts with it.
        inputs.initialContext = context
        let feed = MacSidebarChatFeed.publications(inputs)
        let (output, continuation) = AsyncStream<Publication>.makeStream()
        relay = Task { @MainActor [weak self] in
            for await publication in feed {
                guard let self, !Task.isCancelled else { break }
                self.relayedCountForTesting += 1
                let empty = publication.rows.isEmpty
                if self.isEmpty != empty { self.isEmpty = empty }
                continuation.yield(publication)
            }
            continuation.finish()
        }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.stop()
            }
        }
        return output
    }

    func stop() {
        relay?.cancel()
        relay = nil
        contextContinuation?.finish()
        contextContinuation = nil
    }

    /// The context as the models say now.
    static func context(viewModel: ChatListViewModel, notifyStore: NotifySettingsStore?) -> MacSidebarChatContext {
        var silenced: Set<String> = []
        if let notifyStore {
            for override in notifyStore.activeOverrides where notifyStore.state(for: override.convoID).isSilenced {
                silenced.insert(override.convoID)
            }
        }
        return MacSidebarChatContext(hiddenID: viewModel.hiddenConversationID,
                                     pinnedIDs: viewModel.pinnedConversationIDs,
                                     silencedIDs: silenced, newIDs: viewModel.newConversationIDs)
    }

    /// Sends the context, and again whenever something it reads changes.
    private func trackContext() {
        guard let contextContinuation else { return }
        let next = withObservationTracking {
            Self.context(viewModel: viewModel, notifyStore: notifyStore)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackContext() }
        }
        guard next != context else { return }
        context = next
        contextContinuation.yield(next)
    }
}
