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
/// legacy matrix/mxc URLs never carry a `.link` attribute (see `MarkdownAttributed`),
/// so in practice only item links, http(s) and unknown schemes ever reach
/// this delegate. Only http(s) and mailto go on to `NSWorkspace`; any other
/// scheme gets `BlockedLinkPrompt` instead.
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
    /// Seam for the prompt shown instead of opening a link the app won't
    /// hand to the OS (`MatronItemLink.Action.blocked`).
    public var presentBlocked: @MainActor (URL) -> Void = { BlockedLinkPrompt.present($0) }

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
        // `matron://` links open in-app, and are swallowed when no host
        // installed a handler: the scheme is not registered with the OS, so
        // it must never be handed on. Legacy matrix/mxc links, which
        // nothing can open, and consent links are swallowed too (a consent
        // link belongs on an item, not in prose).
        // Only web and email links reach `openExternally`.
        let openExternally = self.openExternally
        LinkTapRouter(openTrackerItem: openTrackerItem, openConversation: openConversation,
                      openPageLink: openPageLink, trackerNumberLinks: trackerNumberLinks,
                      openExternally: { openExternally($0) }, presentBlocked: presentBlocked)
            .route(url)
        // Return `true` either way: we've decided the outcome, so the text
        // view shouldn't also hand the URL to its default opener.
        return true
    }
}
#endif
