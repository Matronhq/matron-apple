import SwiftUI
import MatronModels
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Shareable tracker links.
//
// The journal hands out `https://<journal>/u/<user>/<n>` for an item,
// mission, milestone or project: a link that works in a browser, and
// that agents write in place of `matron://item/<n>`. Items, missions,
// milestones and projects share one per-user number space, so the link
// says only whose number it is, not what kind of thing it names.
//
// A link to a number on the signed-in journal opens in-app:
// `MatronItemLink.action(for:numbers:)` answers `.openTrackerNumber`, and
// the renderer hands it to the `\.trackerNumberLinks` host. The user's own
// number is looked up and opened through the same item and page openers a
// `matron://` link uses. Another person's number opens in the host's
// read-only viewer for links other people share, when the host has one;
// the web app cannot show another person's rows either, so the browser is
// only the fallback. Anything else (another journal, a host-less renderer)
// stays an ordinary web link.

/// The signed-in journal and user: whose shareable links open in-app.
public struct TrackerLinkOrigin: Equatable, Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int?
    /// The journal's own path, without a trailing slash: `""` for a
    /// journal served at the root.
    let basePath: String
    public let user: String

    /// `nil` for a server URL with no http(s) scheme or host, or an empty
    /// user.
    public init?(serverURL: URL, user: String) {
        guard let parts = URLComponents(url: serverURL, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.host?.lowercased(), !host.isEmpty, !user.isEmpty
        else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = Self.effectivePort(parts.port, scheme: scheme)
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        self.basePath = path
        self.user = user
    }

    private static func effectivePort(_ port: Int?, scheme: String) -> Int? {
        switch (scheme, port) {
        case ("https", 443), ("http", 80): return nil
        default: return port
        }
    }

    /// The number in `<journal>/u/<user>/<n>` when `url` is this user's
    /// link on this journal, else `nil`. The user must match exactly, since
    /// another person's number names something else.
    public func number(in url: URL) -> Int? {
        guard let link = link(in: url), link.user == user else { return nil }
        return link.num
    }

    /// Whose number `url` names, and the number, when it is a
    /// `<journal>/u/<user>/<n>` link on this journal (anyone's), else `nil`.
    ///
    /// Scheme and host compare case-insensitively and a default port
    /// matches its absence. The number is held to the canonical form
    /// `matron://item/<n>` uses: plain ASCII digits, greater than zero. One
    /// trailing slash is allowed; a query, a fragment or login details are
    /// not, so nothing is read past the number.
    public func link(in url: URL) -> TrackerLinkPath? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == scheme,
              parts.host?.lowercased() == host,
              Self.effectivePort(parts.port, scheme: scheme) == port,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil
        else { return nil }
        var path = Substring(parts.percentEncodedPath)
        guard path.hasPrefix(basePath + "/u/") else { return nil }
        path = path.dropFirst(basePath.count + 3)
        if path.hasSuffix("/") { path = path.dropLast() }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2,
              let owner = segments[0].removingPercentEncoding, !owner.isEmpty,
              !segments[1].isEmpty, segments[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let num = Int(segments[1]), num > 0
        else { return nil }
        return TrackerLinkPath(user: owner, num: num)
    }
}


/// The host for shareable links, installed once per window or shell
/// (`\.trackerNumberLinks`): the origin a link must match, the lookup from
/// one of the user's own numbers to what it names, and where another
/// person's link is shown.
public struct TrackerNumberLinks: Sendable {
    public let origin: TrackerLinkOrigin
    let find: @Sendable (Int) async -> TrackerNumberLinkTarget
    /// Shows another person's link in-app (read-only); `nil` sends it to
    /// the browser.
    let showOthers: (@MainActor @Sendable (TrackerLinkPath, URL) -> Void)?

    public init(origin: TrackerLinkOrigin, find: @escaping @Sendable (Int) async -> TrackerNumberLinkTarget,
                showOthers: (@MainActor @Sendable (TrackerLinkPath, URL) -> Void)? = nil) {
        self.origin = origin
        self.find = find
        self.showOthers = showOthers
    }

    /// Opens `num`, tapped as `url`, through the openers where it was
    /// tapped: an item through `openItem` (so it lands where a
    /// `matron://item` link would), a page through `openPage`, anything
    /// else in the browser through `openWeb`. An opener that is `nil` falls
    /// back to the browser too. Another person's link goes to
    /// `showOthers`, or the browser without one.
    @MainActor
    public func open(_ num: Int, url: URL, openItem: ((Int) -> Void)?,
                     openPage: ((MatronPageLink) -> Void)?, openWeb: @escaping @MainActor (URL) -> Void) {
        if let link = origin.link(in: url), link.user != origin.user {
            if let showOthers { showOthers(link, url) } else { openWeb(url) }
            return
        }
        Task { @MainActor in
            switch await find(num) {
            case .item(let num) where openItem != nil: openItem?(num)
            case .page(let link) where openPage != nil: openPage?(link)
            default: openWeb(url)
            }
        }
    }
}

extension TrackerNumberLinks {
    /// Opens `url` in the web browser, never back in this app. Once the
    /// journal's domain is associated with the app, the system could hand
    /// one of its links straight back: iOS does not do that for a link the
    /// app opens itself, and on the Mac the link goes to the default
    /// browser by name.
    @MainActor
    public static func openInBrowser(_ url: URL) {
        #if os(macOS)
        let workspace = NSWorkspace.shared
        guard let probe = URL(string: "https://example.com"),
              let browser = workspace.urlForApplication(toOpen: probe),
              browser != Bundle.main.bundleURL
        else {
            workspace.open(url)
            return
        }
        workspace.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

extension EnvironmentValues {
    /// The shareable-link host; `nil` outside a signed-in window or shell,
    /// where such links stay ordinary web links.
    @Entry public var trackerNumberLinks: TrackerNumberLinks? = nil
}

/// Shareable links opened from outside the app (a universal link tapped in
/// a browser, mail or another app), held until a signed-in window or shell
/// takes them: one that arrives while signed out, locked or still launching
/// waits here.
@MainActor @Observable
public final class IncomingTrackerLinks {
    public static let shared = IncomingTrackerLinks()

    /// The latest link not yet taken; a newer one replaces it.
    public private(set) var pending: URL?

    public init() {}

    /// Keeps an http(s) `url` for the next `take()`; anything else is not
    /// a shareable link and is ignored.
    public func receive(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
        pending = url
    }

    /// The pending link, once: a second window asking gets `nil`.
    public func take() -> URL? {
        defer { pending = nil }
        return pending
    }
}

extension TrackerLinkOrigin {
    /// What a signed-in shell does with an incoming link: open the
    /// number in-app when it is this user's own link on this journal, show
    /// another person's link on this journal read-only, else hand it to
    /// the browser.
    public enum IncomingRoute: Equatable, Sendable {
        case number(Int)
        case othersLink(TrackerLinkPath)
        case browser(URL)
    }

    public func route(incoming url: URL) -> IncomingRoute {
        guard let link = link(in: url) else { return .browser(url) }
        return link.user == user ? .number(link.num) : .othersLink(link)
    }
}
