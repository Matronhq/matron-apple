#if os(macOS)
import AppKit
import MatronModels

/// The link-click policy for a message body's `NSTextView` — one source for
/// both Mac hosts: `SelectableMessageText` (its representable's `Coordinator`
/// subclasses this) and `MessageBodyView` (the table timeline's rows).
///
/// Handles link clicks with the same policy as `MarkdownText` — the decision
/// itself comes from `MatronItemLink.action(for:)`, which both renderers
/// share, because `MarkdownText.handle`'s `OpenURLAction.Result` return type
/// is only meaningful inside SwiftUI's `openURL` environment. Note that
/// matrix/mxc URLs never carry a `.link` attribute (see `MarkdownAttributed`),
/// so in practice only item links, http(s) and unknown schemes ever reach
/// this delegate.
///
/// Not `final`: the SwiftUI representable's `Coordinator` subclasses it inside
/// this module (it adds the `lastApplied` storage pointer). It is not `open`,
/// so no other module can.
public class MessageLinkRouter: NSObject, NSTextViewDelegate {
    /// In-app tracker-item opener. The host sets it — SwiftUI's
    /// representable from its environment on every update.
    public var openTrackerItem: ((Int) -> Void)?
    /// Same, for `matron://convo/<id>`.
    public var openConversation: ((String) -> Void)?
    /// Same, for `matron://mission/<n>` and `matron://project/<n>`.
    public var openPageLink: ((MatronPageLink) -> Void)?
    /// Same, for the signed-in user's own shareable links.
    public var trackerNumberLinks: TrackerNumberLinks?

    /// Seam for the external opener so tests can prove a `matron://`
    /// click never reaches `NSWorkspace`.
    public var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }

    public override init() {
        super.init()
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // Tell the press-rescue layer the link WAS dispatched, whichever
        // internal AppKit route got here — this is what keeps the
        // swallowed-click fallback from ever double-opening.
        (textView as? MouseTrackingRescueTextView)?.noteLinkClickHandled()
        let url: URL?
        switch link {
        case let value as URL: url = value
        case let value as String: url = URL(string: value)
        default: url = nil
        }
        guard let url else { return false }
        switch MatronItemLink.action(for: url, numbers: trackerNumberLinks?.origin) {
        case .openTrackerNumber(let number):
            // A shareable link: the user's own is looked up, then opened
            // like the matching `matron://` link; another person's goes to
            // the host's read-only viewer; else the browser.
            trackerNumberLinks?.open(number, url: url, openItem: openTrackerItem, openPage: openPageLink,
                                     openWeb: TrackerNumberLinks.openInBrowser)
        case .openTrackerItem(let number):
            // `matron://item/<n>` — opened in-app, and
            // swallowed when no host installed a handler. The scheme is
            // not registered with the OS, so it must never be handed on.
            openTrackerItem?(number)
        case .openConversation(let convoID):
            // `matron://convo/<id>` — in-app, or swallowed with no host.
            openConversation?(convoID)
        case .openPage(let page):
            // `matron://mission/<n>` / `matron://project/<n>` — same.
            openPageLink?(page)
        case .swallow, .openConsent:
            // matrix/mxc — swallowed until permalink / content-URI
            // handling lands; mirrors `MarkdownText.handle(url:)`. A
            // consent link belongs on an item, not in prose.
            break
        case .system(let url):
            openExternally(url)
        }
        // Return `true` either way: we've decided the outcome, so the text
        // view shouldn't also hand the URL to its default opener.
        return true
    }
}
#endif
