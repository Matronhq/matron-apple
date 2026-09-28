import SwiftUI

/// Whether the tab ON SCREEN is showing its root (`AppShellNavigation
/// .isAtRoot`), set by the shell for every page of every tab. `nil`
/// outside the shell.
private struct SelectedTabIsAtRootKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var selectedTabIsAtRoot: Bool? {
        get { self[SelectedTabIsAtRootKey.self] }
        set { self[SelectedTabIsAtRootKey.self] = newValue }
    }
}

/// See `tabBarFollowsTheSelectedTab(otherwise:)`.
private struct TabBarFollowsTheSelectedTab: ViewModifier {
    @Environment(\.selectedTabIsAtRoot) private var selectedTabIsAtRoot
    let fallback: Visibility

    func body(content: Content) -> some View {
        content.toolbar(TabBarRule.visibility(selectedTabIsAtRoot: selectedTabIsAtRoot, otherwise: fallback),
                        for: .tabBar)
    }
}

enum TabBarRule {
    /// Showing at the root of the tab on screen, hidden under anything
    /// pushed on it (spec §3); `fallback` outside the shell.
    static func visibility(selectedTabIsAtRoot: Bool?, otherwise fallback: Visibility) -> Visibility {
        guard let selectedTabIsAtRoot else { return fallback }
        return selectedTabIsAtRoot ? .visible : .hidden
    }
}

extension View {
    /// The tab bar's visibility, stated by EVERY page in the shell, root or
    /// pushed, from one rule: the tab on screen and whether anything is
    /// pushed on it.
    ///
    /// Mission #3784 (the bar gone at the Coordinator root, with no way out
    /// of the tab). The four tabs share one tab bar, and SwiftUI applies a
    /// page's value to it whichever tab the page is on. Measured on the
    /// iOS 26.2 simulator: with the Coordinator root on screen, a chat
    /// pushed onto the Conversations stack behind it (`autoOpenChat`, a
    /// session the Coordinator just started) hid the bar, and nothing on
    /// the Coordinator tab changed to bring it back. A page that states
    /// its own stack's depth is therefore wrong whenever its tab is not
    /// the one on screen. Stating the same value everywhere leaves nothing
    /// to disagree.
    ///
    /// It also covers the earlier half of the fault: a root that states
    /// nothing waits about half a second after a pop for SwiftUI to bring
    /// the bar back, from work queued on the main queue, and stays without
    /// it if that work is lost.
    func tabBarFollowsTheSelectedTab(otherwise fallback: Visibility) -> some View {
        modifier(TabBarFollowsTheSelectedTab(fallback: fallback))
    }
}
