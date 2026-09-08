import SwiftUI

/// Floating "file the composer as a task" affordance (Task 12: items
/// tracker composer integration). Centred above the composer, shown only
/// while `ComposerViewModel.canMakeTask` is true — mirrors
/// `JumpToBottomButton`'s materials/shadow so the two floating affordances
/// read as one family.
public struct MakeTaskPill: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label("Make task", systemImage: "checklist")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Make task from this message")
        #if os(macOS)
        .keyboardShortcut("t", modifiers: [.command, .shift])
        #endif
        .transition(.scale.combined(with: .opacity))
    }
}
