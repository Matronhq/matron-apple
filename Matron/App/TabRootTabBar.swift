import SwiftUI

extension View {
    /// The tab bar's visibility, stated outright by a tab's ROOT from its
    /// own stack's path: showing at the root, hidden under anything pushed
    /// (spec §3).
    ///
    /// Mission #3784 (the bar gone at the Coordinator root, with no way out
    /// of the tab until a push and Back). A root that states nothing relies
    /// on SwiftUI to bring the bar back once the pushed view that hid it
    /// has gone. Measured on the iOS 26.2 simulator, that happens about
    /// half a second after the pop, from work queued on the main queue, and
    /// if that work is lost the bar stays hidden. A value the root states
    /// itself is applied with the view update that uncovers it. It also
    /// outranks the pushed view's, so the root states both halves: a bare
    /// `.visible` here shows the bar over the pushed views too.
    func tabBarShownAtRoot(of path: some Collection) -> some View {
        toolbar(path.isEmpty ? .visible : .hidden, for: .tabBar)
    }
}
