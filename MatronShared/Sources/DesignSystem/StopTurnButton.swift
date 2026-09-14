import SwiftUI

/// Floating "stop the current turn" affordance for the chat timeline.
/// Hosted inside `ChatTopTrailingControls`, which owns the top-trailing
/// placement and padding; shown while the bot's activity indicator is
/// live (an agent turn is running); tapping invokes `action`, which the
/// host binds to sending the bridge's `!esc` interrupt. Same shape
/// language AND tint as `JumpToBottomButton` so the floating chat
/// controls read as one family — this one sits on the opposite end of
/// the same trailing edge. (Red was tried first; Dan preferred the
/// neutral tint, 2026-08-05.)
public struct StopTurnButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.primary, .regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .help("Stop the current turn")
        .accessibilityLabel("Stop the current turn")
        .accessibilityIdentifier("chat.stopTurn")
        .transition(.scale.combined(with: .opacity))
    }
}
