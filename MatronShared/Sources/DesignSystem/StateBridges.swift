import Foundation
import MatronModels

/// Single source of truth for service-layer-state → design-system-state
/// mappings. Hoisted here so every consumer constructs through the
/// SAME mapping; adding a new case to a source enum fails to compile
/// against the bridge instead of silently falling through in one of N
/// platform-specific copies. Two bridges currently live here:
///
/// - `SyncBannerState.from(_:)` — `SyncConnectionState` (MatronModels) →
///   `SyncBannerState`. Was duplicated as `bannerState(from:)` on iOS
///   `ChatListView` and Mac `MacChatListView`.
/// - `SendStateGlyph.from(_:)` — `TimelineSendState` (MatronModels) →
///   `SendStateGlyph`. Was duplicated as `sendStateGlyph(for:)` on iOS
///   `TimelineItemView` and Mac `MacTimelineItemView`. The source enum
///   is `MatronModels`-resident specifically to keep the design-system
///   target free of any `MatrixRustSDK` transitive dep.

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

public extension SendStateGlyph {
    /// Translate from the model-layer send state to the design-system
    /// glyph. Identity mapping today; the indirection lets glyph UX
    /// (e.g. a distinct "queued" state) diverge from the model enum
    /// without changing every caller.
    static func from(_ state: TimelineSendState) -> SendStateGlyph {
        switch state {
        case .sent: return .sent
        case .sending: return .sending
        case .failed(let reason): return .failed(reason: reason)
        }
    }
}
