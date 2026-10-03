import SwiftUI

/// The way out of a deep stack (Dan, 2026-10-03, mission 7047): the tab
/// bar is hidden under anything pushed (`TabBarRule`), and a conversation
/// can now be reached through a chain of chats, items and mission pages,
/// each of which Back retraces one at a time. Several pages deep, one tap
/// returns to the tab's root, where the tab bar is.
enum StackExit {
    /// Offered from the second pushed page on. One page deep, Back
    /// already leads to the root.
    static func isOffered(depth: Int) -> Bool {
        depth >= 2
    }

    static let symbol = "chevron.backward.2"

    static func label(rootName: String) -> String {
        "Back to \(rootName)"
    }
}

/// See `leadsBackToTheRoot(named:)`.
private struct LeadsBackToTheRoot: ViewModifier {
    @Environment(\.chatNavigationPath) private var path
    let rootName: String

    func body(content: Content) -> some View {
        content.toolbar {
            if let path, StackExit.isOffered(depth: path.wrappedValue.count) {
                ToolbarItem(placement: .topBarLeading) {
                    Button { path.wrappedValue = [] } label: {
                        Image(systemName: StackExit.symbol)
                    }
                    .accessibilityLabel(StackExit.label(rootName: rootName))
                }
            }
        }
    }
}

extension View {
    /// A button beside Back that clears the stack this page is pushed on
    /// (`\.chatNavigationPath`), shown per `StackExit.isOffered`. Stated
    /// by every destination of every tab's stack, so no pushed page is
    /// without it. `rootName` is the tab's name, for VoiceOver.
    func leadsBackToTheRoot(named rootName: String) -> some View {
        modifier(LeadsBackToTheRoot(rootName: rootName))
    }
}
