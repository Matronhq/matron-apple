import Foundation
import MatronJournal

/// The one store read the consent card in item detail needs: a
/// conversation's consent cards and spawn outcomes, so the card's facts and
/// its resolved state come from the journal's own rows — the same rows the
/// timeline card is drawn from — rather than from anything remembered
/// locally. A slice, like `ItemsStoreReading`, so tests fake it; conformance
/// for the real store is declared here since `MatronJournal` cannot import
/// this module.
public protocol ConsentEventsReading: Sendable {
    /// Live `permission_request` and `spawn_outcome` events of one
    /// conversation, oldest first: the current rows first, then again on
    /// every change. Live because the card can land AFTER the item — a
    /// consent item opened from a push on a device that has not yet
    /// synced the origin conversation — and the ask must become
    /// answerable the moment its card arrives, without reopening the item.
    func consentEventsStream(convoID: String) -> AsyncStream<[JournalEvent]>
}

extension JournalStore: ConsentEventsReading {}
