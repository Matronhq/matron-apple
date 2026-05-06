import SwiftUI

/// Floating "jump to latest message" affordance for the chat timeline.
/// Shown as an overlay in the bottom-trailing corner whenever the user
/// has scrolled away from the live tail; tapping invokes `action` which
/// the view binds to a scroll-to-bottom helper. iOS and Mac both render
/// the same shape — keeps the surface tiny and the affordance familiar
/// across platforms.
public struct JumpToBottomButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.primary, .regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to latest")
        .accessibilityIdentifier("chat.jumpToBottom")
        .padding(.trailing, 16)
        .padding(.bottom, 8)
        .transition(.scale.combined(with: .opacity))
    }
}
