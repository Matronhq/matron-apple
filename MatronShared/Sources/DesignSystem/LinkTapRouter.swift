import Foundation
import MatronModels

/// Where a tapped link goes — one dispatch for every place the apps open a
/// link from text: `MarkdownText`, the Mac's `MessageLinkRouter`, the iOS
/// timeline's `TimelineLinkRouter`, and the item hosts' link chips.
///
/// The decision is `MatronItemLink.action(for:numbers:)`; this runs it.
/// Item, conversation, mission and project links resolve in-app (the
/// `matron` scheme is registered with nothing), and with no opener
/// installed they are swallowed, never handed to the OS. Web and email
/// links go to `openExternally`; any other scheme gets `presentBlocked`.
public struct LinkTapRouter {
    public enum Outcome: Equatable {
        case trackerItem(Int)
        case conversation(String)
        case page(MatronPageLink)
        case trackerNumber(Int)
        /// A consent link, handed to `openConsent`.
        case consent(ConsentLink)
        /// Consumed: matrix-internal URLs, an unknown `matron://` link, or a
        /// consent link with no `openConsent`.
        case swallowed
        case external(URL)
        /// Not a web or email link: not opened, the copy prompt shown.
        case blocked(URL)
    }

    public var openTrackerItem: ((Int) -> Void)?
    public var openConversation: ((String) -> Void)?
    public var openPageLink: ((MatronPageLink) -> Void)?
    /// `matron://consent/…`. `nil` swallows it: a consent link belongs on an
    /// item, so only the item hosts open one; message text does not.
    public var openConsent: ((ConsentLink) -> Void)?
    /// The signed-in user's own shareable links (`TrackerWebLinks`).
    public var trackerNumberLinks: TrackerNumberLinks?
    /// A web or email link (`MatronItemLink.Action.system`).
    public var openExternally: @MainActor (URL) -> Void
    /// Where a shareable link goes when the app cannot show what it names.
    public var openTrackerNumberOnWeb: @MainActor (URL) -> Void
    /// A link the app won't hand to the OS (`MatronItemLink.Action.blocked`).
    public var presentBlocked: @MainActor (URL) -> Void

    public init(openTrackerItem: ((Int) -> Void)? = nil,
                openConversation: ((String) -> Void)? = nil,
                openPageLink: ((MatronPageLink) -> Void)? = nil,
                openConsent: ((ConsentLink) -> Void)? = nil,
                trackerNumberLinks: TrackerNumberLinks? = nil,
                openExternally: @escaping @MainActor (URL) -> Void,
                openTrackerNumberOnWeb: @escaping @MainActor (URL) -> Void = { TrackerNumberLinks.openInBrowser($0) },
                presentBlocked: @escaping @MainActor (URL) -> Void = { BlockedLinkPrompt.present($0) }) {
        self.openTrackerItem = openTrackerItem
        self.openConversation = openConversation
        self.openPageLink = openPageLink
        self.openConsent = openConsent
        self.trackerNumberLinks = trackerNumberLinks
        self.openExternally = openExternally
        self.openTrackerNumberOnWeb = openTrackerNumberOnWeb
        self.presentBlocked = presentBlocked
    }

    @MainActor
    @discardableResult
    public func route(_ url: URL) -> Outcome {
        switch MatronItemLink.action(for: url, numbers: trackerNumberLinks?.origin) {
        case .openTrackerNumber(let number):
            // A shareable link: the user's own is looked up, then opened
            // like the matching `matron://` link; another person's goes to
            // the host's read-only viewer; else the browser.
            trackerNumberLinks?.open(number, url: url, openItem: openTrackerItem, openPage: openPageLink,
                                     openWeb: openTrackerNumberOnWeb)
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
        case .openConsent(let consent):
            guard let openConsent else { return .swallowed }
            openConsent(consent)
            return .consent(consent)
        case .swallow:
            return .swallowed
        case .system(let url):
            openExternally(url)
            return .external(url)
        case .blocked(let url):
            presentBlocked(url)
            return .blocked(url)
        }
    }
}
