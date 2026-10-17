import UIKit
import MatronDesignSystem
import MatronModels

/// Link taps from the UIKit timeline's text views and table grids. The
/// decision is `MatronItemLink.action(for:)` — the policy `MarkdownText`
/// and the Mac's `SelectableMessageText` share — so the three renderers
/// cannot drift. Item, conversation, mission and project links resolve
/// in-app (the `matron` scheme is registered with nothing); with no handler
/// installed they are swallowed, never handed to the OS.
struct TimelineLinkRouter {
    var openTrackerItem: ((Int) -> Void)?
    var openConversation: ((String) -> Void)?
    var openPageLink: ((MatronPageLink) -> Void)?
    /// The signed-in user's own shareable links (`TrackerWebLinks`).
    var trackerNumberLinks: TrackerNumberLinks?
    /// Seam for tests; production hands the URL to the OS.
    var openExternally: @MainActor (URL) -> Void = { UIApplication.shared.open($0) }
    /// Seam for tests; production shows `BlockedLinkPrompt` for a link the
    /// app won't hand to the OS.
    var presentBlocked: @MainActor (URL) -> Void = { BlockedLinkPrompt.present($0) }

    enum Outcome: Equatable {
        case trackerItem(Int)
        case conversation(String)
        case page(MatronPageLink)
        case trackerNumber(Int)
        case swallowed
        case external(URL)
        /// Not a web or email link: not opened, the copy prompt shown.
        case blocked(URL)
    }

    @MainActor
    @discardableResult
    func route(_ url: URL) -> Outcome {
        switch MatronItemLink.action(for: url, numbers: trackerNumberLinks?.origin) {
        case .openTrackerNumber(let number):
            trackerNumberLinks?.open(number, url: url, openItem: openTrackerItem, openPage: openPageLink,
                                     openWeb: openExternally)
            return .trackerNumber(number)
        case .openTrackerItem(let number):
            openTrackerItem?(number)
            return .trackerItem(number)
        case .openConversation(let convoID):
            openConversation?(convoID)
            return .conversation(convoID)
        case .openPage(let link):
            openPageLink?(link)
            return .page(link)
        case .swallow, .openConsent:
            return .swallowed
        case .system(let url):
            openExternally(url)
            return .external(url)
        case .blocked(let url):
            presentBlocked(url)
            return .blocked(url)
        }
    }

    /// Whether UIKit's own default link action (Safari / universal links)
    /// should handle `url` — exactly the `.system` policy branch.
    static func isSystemLink(_ url: URL) -> Bool {
        TimelineLinkRouter().isSystemLink(url)
    }

    /// `isSystemLink`, with the user's own shareable links on this
    /// router's journal kept in-app.
    func isSystemLink(_ url: URL) -> Bool {
        if case .system = MatronItemLink.action(for: url, numbers: trackerNumberLinks?.origin) { return true }
        return false
    }

    /// Whether `url` is a link the app won't hand to the OS
    /// (`MatronItemLink.Action.blocked`).
    func isBlockedLink(_ url: URL) -> Bool {
        if case .blocked = MatronItemLink.action(for: url, numbers: trackerNumberLinks?.origin) { return true }
        return false
    }

    /// The long-press menu for a link in a text view. UIKit's default menu
    /// offers to open the link with the OS, so a blocked link gets a menu
    /// with Copy Link only, and no preview (which would load it). Every
    /// other link keeps the default menu and preview.
    @MainActor
    func menuConfiguration(for textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration {
        guard case .link(let url) = textItem.content, isBlockedLink(url) else {
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }
        return UITextItem.MenuConfiguration(preview: nil, menu: Self.blockedLinkMenu(for: url))
    }

    /// The menu `menuConfiguration(for:defaultMenu:)` shows for a blocked
    /// link. Separate so tests can read it without a `UITextItem`.
    @MainActor
    static func blockedLinkMenu(for url: URL) -> UIMenu {
        UIMenu(children: [
            UIAction(title: BlockedLinkPrompt.copyTitle, image: UIImage(systemName: "doc.on.doc")) { _ in
                Pasteboard.copy(url.absoluteString)
            },
        ])
    }
}
