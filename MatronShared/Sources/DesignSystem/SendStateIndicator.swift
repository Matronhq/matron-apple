import SwiftUI

/// Tri-state mirror of `TimelineSendState` for the design-system
/// surface. Kept as a distinct enum (rather than re-exporting the
/// model-layer type) so glyph UX can diverge from the model — bridged
/// from `TimelineSendState` via `SendStateGlyph.from(_:)` in
/// `StateBridges.swift`.
public enum SendStateGlyph: Equatable, Sendable {
    case sending
    case sent
    case failed(reason: String)
}

/// Small footer indicator rendered under an own-message bubble that
/// reflects the `TimelineItem.SendState`. `.sent` is the default
/// state and produces no glyph (a checkmark would clutter the
/// timeline once every-other row carries one); `.sending` shows a
/// clock + "Sending…" caption; `.failed` shows a red exclamation +
/// "Tap to retry" affordance and forwards taps to `onRetry`.
public struct SendStateIndicator: View {
    private let state: SendStateGlyph
    private let onRetry: (() -> Void)?

    public init(state: SendStateGlyph, onRetry: (() -> Void)? = nil) {
        self.state = state
        self.onRetry = onRetry
    }

    public var body: some View {
        switch state {
        case .sent:
            // Default state — render nothing. A static checkmark on
            // every successful send would visually clutter the
            // timeline; the absence of an indicator IS the success
            // signal (mirrors iMessage / WhatsApp conventions).
            EmptyView()

        case .sending:
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.caption2)
                Text("Sending…")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Sending")

        case .failed(let reason):
            // Tappable retry affordance. `.borderless` button style
            // strips the chrome so the row reads as inline copy with
            // a leading glyph rather than a distinct control.
            Button(action: { onRetry?() }) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption2)
                    Text("Failed — tap to retry")
                        .font(.caption2)
                }
                .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Send failed: \(reason). Tap to retry.")
        }
    }
}
