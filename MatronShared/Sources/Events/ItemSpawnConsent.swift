import Foundation

/// What item detail needs to draw the spawn consent card for a consent item
/// (item #2318): the request id from the item's `matron://consent/spawn/<id>`
/// link, the card's own facts when its `permission_request` event is in the
/// local store, and where the ask is in its life.
///
/// `request` is optional on purpose: the card event may not have reached
/// this device yet (a consent item opened from a push before the origin
/// conversation synced). Such an ask is drawn as waiting for its card and
/// is NOT answerable — never reconstructed from the item's markdown, and
/// never answered on the request id alone. The id comes from a link any
/// agent can write into any item, so an item without its card could be
/// another conversation's ask under a benign body; what the user approves
/// must be the card's own payload, or nothing.
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
