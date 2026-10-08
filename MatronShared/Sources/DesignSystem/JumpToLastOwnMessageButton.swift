import SwiftUI

/// Floating "jump to my last message" affordance for the chat timeline.
/// Hosted inside `ChatTopTrailingControls`, in the Stop pill's slot when
/// no turn is running, or beneath it when one is — never in the header
/// toolbar. Same shape language and tint as `StopTurnButton` and
/// `JumpToBottomButton` so all three floating chat controls read as one
/// family.
public struct JumpToLastOwnMessageButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.to.line")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .help("Jump to my last message (⇧⌘U)")
        #else
        .help("Jump to my last message")
        #endif
        .accessibilityLabel("Jump to my last message")
        .accessibilityIdentifier("chat.jumpToLastOwnMessage")
        .transition(.scale.combined(with: .opacity))
    }
}
