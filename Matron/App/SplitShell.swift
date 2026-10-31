import SwiftUI

/// Whether a page is shown in the iPad's split shell (`AppShellView`'s
/// regular-width layout) rather than the iPhone's tab bar. A chat there
/// puts its tracker beside the timeline when the column is wide enough
/// and leaves its root alone on a swipe right. `false` everywhere else.
private struct IsInSplitShellKey: EnvironmentKey {
    static let defaultValue = false
}

/// The conversation the split shell's detail column shows, so the
/// Conversations list in its sidebar can mark that row selected, as the
/// Mac's list does. `nil` outside the split shell.
private struct SelectedConversationIDKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var isInSplitShell: Bool {
        get { self[IsInSplitShellKey.self] }
        set { self[IsInSplitShellKey.self] = newValue }
    }

    var selectedConversationID: String? {
        get { self[SelectedConversationIDKey.self] }
        set { self[SelectedConversationIDKey.self] = newValue }
    }
}

/// Which shell the signed-in app draws: the split view (sidebar, chat and
/// tracker side by side, as on the Mac) or the iPhone's tab bar. The split
/// view needs an iPad at regular width with room for its sidebar and a
/// readable chat beside it; a narrow Split View or Slide Over window, and
/// every iPhone, gets the tab bar.
enum SplitShellRule {
    /// The sidebar: the nav column and the list beside it.
    static let navColumnWidth: CGFloat = 72
    static let sidebarWidth: CGFloat = 400
    /// For you and Search list cards built for an iPhone's width: their
    /// sidebar is about that wide beside the nav column.
    static let wideSidebarWidth: CGFloat = 472

    static func sidebarWidth(for tab: AppTab) -> CGFloat {
        tab == .decisions || tab == .search ? wideSidebarWidth : sidebarWidth
    }
    /// Narrower than this the window keeps the tab bar, even at regular
    /// width (half of a smaller iPad in landscape).
    static let minWindowWidth: CGFloat = 700

    static func usesSplitShell(isPad: Bool, horizontalSizeClass: UserInterfaceSizeClass?, width: CGFloat) -> Bool {
        isPad && horizontalSizeClass == .regular && width >= minWindowWidth
    }

    /// The split shell's detail stacks start with the page chosen in the
    /// sidebar: a write that would pop past it keeps it, so Back, the
    /// swipe right and "Back to root" stop at the chosen page instead of
    /// an empty column.
    static func keepingRoot(_ new: [String], old: [String]) -> [String] {
        if new.isEmpty, let root = old.first { return [root] }
        return new
    }
}
