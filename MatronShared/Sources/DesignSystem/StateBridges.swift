import Foundation
import MatronSync

/// Single source of truth for service-layer-state → design-system-state
/// mappings. Previously `bannerState(from:)` was duplicated as a
/// `static func` on both iOS `ChatListView` and Mac `MacChatListView`
/// — identical bodies, two copies, future `SyncConnectionState` case
/// additions would have needed touching both. Hoisting it as a
/// `static func` on the design-system target enum means every
/// consumer constructs through the SAME mapping; adding a new case
/// fails to compile here instead of silently falling through in one
/// of the two views.
///
/// `SendStateGlyph` has the same shape problem (duplicated between
/// `TimelineItemView` / `MacTimelineItemView`) but its source enum
/// `TimelineItem.SendState` lives in `MatronChat` which transitively
/// pulls in MatrixRustSDK — too heavy a dep for a single four-line
/// converter. Left duplicated; if `SendState` ever moves to
/// `MatronModels` the `from(_:)` factory follows here.

public extension SyncBannerState {
    /// Translate from the service-layer connection state to the
    /// design-system banner state. Identity mapping today; kept as a
    /// distinct surface so future banner UX (e.g. a separate
    /// "reconnecting" treatment) can diverge without changing every
    /// caller.
    static func from(_ state: SyncConnectionState) -> SyncBannerState {
        switch state {
        case .connecting: return .connecting
        case .running: return .running
        case .offline(let reason): return .offline(reason: reason)
        }
    }
}
