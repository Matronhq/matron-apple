import SwiftUI

/// Floating "jump to the top" affordance for an item thread, in the
/// top-trailing corner while the reader is scrolled away from the top.
/// The same pill as the chat's `JumpToLastOwnMessageButton`, so the
/// up-arrow reads the same in both places.
public struct JumpToTopButton: View {
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
        .help("Jump to the top (⌘↑)")
        #else
        .help("Jump to the top")
        #endif
        .accessibilityLabel("Jump to the top")
        .accessibilityIdentifier("item.jumpToTop")
        .transition(.scale.combined(with: .opacity))
    }
}
