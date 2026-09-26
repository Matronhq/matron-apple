import UIKit
import MatronDesignSystem

/// Link taps from the UIKit timeline's text views and table grids. The
/// decision is `MatronItemLink.action(for:)` — the policy `MarkdownText`
/// and the Mac's `SelectableMessageText` share — so the three renderers
/// cannot drift. Item and conversation links resolve in-app (the `matron`
/// scheme is registered with nothing); with no handler installed they are
/// swallowed, never handed to the OS.
struct TimelineLinkRouter {
    var openTrackerItem: ((Int) -> Void)?
    var openConversation: ((String) -> Void)?
    /// Seam for tests; production hands the URL to the OS.
    var openExternally: @MainActor (URL) -> Void = { UIApplication.shared.open($0) }

    enum Outcome: Equatable {
        case trackerItem(Int)
        case conversation(String)
        case swallowed
        case external(URL)
    }

    @MainActor
    @discardableResult
    func route(_ url: URL) -> Outcome {
        switch MatronItemLink.action(for: url) {
        case .openTrackerItem(let number):
            openTrackerItem?(number)
            return .trackerItem(number)
        case .openConversation(let convoID):
            openConversation?(convoID)
            return .conversation(convoID)
        case .swallow, .openConsent:
            return .swallowed
        case .system(let url):
            openExternally(url)
            return .external(url)
        }
    }

    /// Whether UIKit's own default link action (Safari / universal links)
    /// should handle `url` — exactly the `.system` policy branch.
    static func isSystemLink(_ url: URL) -> Bool {
        if case .system = MatronItemLink.action(for: url) { return true }
        return false
    }
}
