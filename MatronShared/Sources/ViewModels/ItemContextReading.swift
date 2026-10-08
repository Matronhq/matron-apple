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
}

extension JournalStore: ItemContextReading {}
