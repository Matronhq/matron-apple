import Foundation
import MatronModels
import MatronJournal

/// The store reads behind the item detail's context block:
/// the item's mission and its owner conversation, both followed live. A
/// slice, like `ItemsStoreReading`, so tests fake it; conformance for the
/// real store is declared here since `MatronJournal` cannot import this
/// module.
public protocol ItemContextReading: Sendable {
    func missionStream(id: String) -> AsyncStream<Mission?>
    /// Whether this device has the conversation (the gate on the owner
    /// row's tap) and its `"<box> · <title>"` label.
    func conversationOriginStream(id: String) -> AsyncStream<JournalStore.ConversationOrigin>
    /// Which of `ids` this device has a conversation row for, followed
    /// live: the gate on a comment caption's conversation tap, as
    /// `conversationOriginStream` is the gate on the owner row's.
    func knownConversationIDsStream(among ids: Set<String>) -> AsyncStream<Set<String>>
}

public extension ItemContextReading {
    /// A store that cannot say knows none, so no caption offers a tap.
    func knownConversationIDsStream(among ids: Set<String>) -> AsyncStream<Set<String>> {
        AsyncStream { $0.yield([]); $0.finish() }
    }
}

extension JournalStore: ItemContextReading {}
