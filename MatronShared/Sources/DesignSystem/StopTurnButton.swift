import SwiftUI

/// Floating "stop the current turn" affordance for the chat timeline.
/// Shown as an overlay in the top-trailing corner while the bot's
/// activity indicator is live (an agent turn is running); tapping
/// invokes `action`, which the host binds to sending the bridge's
/// `!esc` interrupt. Same shape language as `JumpToBottomButton` so the
/// two floating chat controls read as one family — this one sits on the
/// opposite end of the same trailing edge.
public struct StopTurnButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.red, .regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .help("Stop the current turn")
        .accessibilityLabel("Stop the current turn")
        .accessibilityIdentifier("chat.stopTurn")
        .padding(.trailing, 16)
        .padding(.top, 8)
        .transition(.scale.combined(with: .opacity))
    }
}
