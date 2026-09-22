import Foundation

/// What item detail needs to draw the spawn consent card for a consent item
/// (item #2318): the request id from the item's `matron://consent/spawn/<id>`
/// link, the card's own facts when its `permission_request` event is in the
/// local store, and where the ask is in its life.
///
/// `request` is optional on purpose. The item body already carries every
/// fact the card shows (the journal writes them there, verbatim), and the
/// answer API is keyed on the request id alone — so an ask whose card event
/// has not reached this device is still answerable, just drawn as the answer
/// controls without the card around them. Never reconstructed from the
/// item's markdown: what the user approves must be the card's own payload,
/// or nothing.
///
/// Lives in MatronEvents beside `AgentSpawnCardState` so the view model that
/// derives it (MatronViewModels) and the leaf view that renders it
/// (MatronDesignSystem) share one type without either importing the other.
public struct ItemSpawnConsent: Equatable, Sendable {
    public let requestID: String
    public let request: AgentSpawnRequest?
    public let state: AgentSpawnCardState

    public init(requestID: String, request: AgentSpawnRequest?, state: AgentSpawnCardState) {
        self.requestID = requestID
        self.request = request
        self.state = state
    }
}
