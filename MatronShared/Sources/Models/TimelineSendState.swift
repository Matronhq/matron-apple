import Foundation

/// Send-state for an own-message timeline row. Lives in `MatronModels`
/// (rather than being nested inside `TimelineItem` in `MatronChat`) so
/// that `MatronDesignSystem` can bridge it to `SendStateGlyph` without
/// pulling `MatronChat` (and its transitive `MatrixRustSDK` dep) into
/// the design-system target. `TimelineItem.SendState` remains as a
/// typealias for source compatibility — see `TimelineItem.swift`.
public enum TimelineSendState: Equatable, Sendable {
    case sent
    case sending
    /// Durably queued in the offline outbox — will send automatically when
    /// a connection is available. Distinct from `.sending` so the UI can
    /// be honest that nothing is in flight yet.
    case queued
    case failed(reason: String)
}
