import Foundation
import SwiftUI

/// Tracker-item deep links (item #115).
///
/// Agents reference tracker items in ordinary prose as standard markdown
/// links — `[#65](matron://item/65)` — so they render as a normal link in
/// every client and cost nothing when the reader's app doesn't understand
/// them. The `matron` scheme is deliberately NOT registered with the OS
/// (there is no `CFBundleURLTypes` entry; `matron://link` / `matron://rlink`
/// are pasted or scanned, never opened), so a tap must be resolved
/// **in-app**: handing `matron://…` to `NSWorkspace`/`UIApplication` earns
/// the user a "no application can open this URL" sheet.
///
/// This enum is the single source of truth for that decision, shared by both
/// message renderers (`MarkdownText`'s `openURL` action on iOS and
/// `SelectableMessageText`'s NSTextView coordinator on the Mac) so the two
/// paths cannot drift apart.
public enum MatronItemLink {

    /// What a tapped link in a message body should do.
    public enum Action: Equatable {
        /// A well-formed `matron://item/<n>` — open tracker item `n` in-app.
        case openTrackerItem(Int)
        /// Hand to the OS (the pre-existing default for http(s) and for any
        /// scheme we have no opinion about).
        case system(URL)
        /// Consume silently — matrix-internal URLs, and item links when no
        /// in-app handler is installed.
        case swallow
    }

    /// The item number in `matron://item/<positive integer>`, or `nil` for
    /// anything else.
    ///
    /// Strict by design — this parser decides whether a URL a remote agent
    /// wrote gets in-app navigation. Only the canonical form is accepted:
    /// the path must be exactly `/` followed by ASCII digits greater than
    /// zero, with no query and no fragment. Scheme and host compare
    /// case-insensitively (RFC 3986); everything else must match exactly.
    ///
    /// The path is matched as a whole string rather than split into
    /// components, so an empty or trailing segment (`matron://item/65/`,
    /// `matron://item//65`) is rejected too — splitting while omitting
    /// empty subsequences quietly accepted both as `#65`.
    ///
    /// It reads the path off `URLComponents`, not `URL.path`: the latter
    /// normalises a trailing slash away (`matron://item/65/` reports as
    /// `/65`), and it percent-DECODES, which would let `matron://item/%36%35`
    /// through the digit check. `percentEncodedPath` is the URL as written.
    public static func itemNumber(from url: URL) -> Int? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "matron",
              parts.host?.lowercased() == "item",
              parts.query == nil, parts.fragment == nil,
              parts.user == nil, parts.password == nil, parts.port == nil
        else { return nil }
        let path = parts.percentEncodedPath
        guard path.hasPrefix("/") else { return nil }
        let digits = path.dropFirst()
        // `Int(_:)` alone would accept "+65" / "-5" / " 65"; require plain
        // ASCII digits (and let `Int` reject an overflowing run of them).
        // This also rejects any second path segment: a "/" is not a digit.
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(digits), number > 0
        else { return nil }
        return number
    }

    /// Message-body link policy. `matron://item/<n>` first; then the
    /// pre-existing scheme policy, unchanged apart from `matron` itself.
    public static func action(for url: URL) -> Action {
        if let number = itemNumber(from: url) { return .openTrackerItem(number) }
        switch url.scheme?.lowercased() {
        case "matron":
            // A `matron` URL we don't understand — a malformed item link, or
            // a pairing `matron://link` / `matron://rlink` that got
            // linkified. The scheme is registered with NOTHING, so handing
            // it to the OS earns the user a "no application can open this
            // URL" sheet: swallow instead.
            return .swallow
        case "matrix", "mxc":
            // Swallowed until permalink / content-URI handling lands.
            return .swallow
        default:
            return .system(url)
        }
    }
}

// MARK: - Environment

/// One tap on a `matron://item/<n>` link, as published by
/// `TrackerItemLinkRelay`. The `id` makes two consecutive taps on the SAME
/// item two distinct values, so a host view's `onChange` sees both.
public struct TrackerItemLinkTap: Equatable, Identifiable {
    public let id = UUID()
    public let num: Int
    public init(num: Int) { self.num = num }
}

/// Stable-identity relay between the environment action and the view that
/// actually navigates.
///
/// The `\.openTrackerItem` action is read by EVERY rendered message body, so
/// a fresh closure per parent body evaluation would churn the environment
/// under the whole timeline (this repo has scroll-perf scar tissue about
/// exactly that — see `TimelineListContent`'s `.equatable()` fence). The
/// relay is held in `@State`, so `action` is one closure instance for the
/// view's lifetime; the navigation itself happens in the host view's
/// `onChange(of:)` with current values, never through a closure that
/// captured stale ones.
@Observable
public final class TrackerItemLinkRelay {
    /// The most recent tap. The host view navigates and may leave it set —
    /// the `id` keeps the next tap distinguishable either way.
    public var pending: TrackerItemLinkTap?

    /// Message for the tracker alert when a tap did NOT open anything —
    /// `TrackerItemLinkResolver.Resolution.alertMessage(num:)`. Set by the
    /// host, presented (and cleared) by `trackerItemLinks(_:open:)`. The
    /// alert is the whole point of the miss path: the host stays exactly
    /// where it was, so without it an unknown number is a dead tap.
    public var alert: String?

    /// The environment action. Same instance for this relay's lifetime.
    @ObservationIgnored public private(set) var action: (Int) -> Void = { _ in }

    public init() {
        action = { [weak self] num in self?.pending = TrackerItemLinkTap(num: num) }
    }
}

/// Opens a tracker item by NUMBER, in whatever surface the host provides
/// (iOS: pushed onto the chat stack; Mac: the items pane). `nil` — the
/// default — means no host is installed, and item links are swallowed
/// rather than handed to the OS.
///
/// Internal: hosts install the value through `trackerItemLinks(_:open:)` or
/// `\.openTrackerItem`, never through the key itself.
struct OpenTrackerItemKey: EnvironmentKey {
    static let defaultValue: ((Int) -> Void)? = nil
}

extension EnvironmentValues {
    public var openTrackerItem: ((Int) -> Void)? {
        get { self[OpenTrackerItemKey.self] }
        set { self[OpenTrackerItemKey.self] = newValue }
    }
}

/// Installs a surface as the host for `matron://item/<n>` links: the
/// environment action every rendered body reads, the tap → `open` hop, and
/// the tracker alert the resolver's miss paths surface.
///
/// Apply this ONCE, on the host container — not per child. Re-applying it
/// down the tree pushes a fresh environment value under each subtree for no
/// gain, and a second alert on the same surface can shadow the first.
/// Nesting is meaningful only where a genuinely different container takes
/// over (an item detail pushing onto its OWN stack, say): the innermost
/// install wins for everything it contains, which is exactly the "push
/// where the link was tapped" behaviour.
private struct TrackerItemLinksModifier: ViewModifier {
    let relay: TrackerItemLinkRelay
    let open: (Int) async -> Void

    func body(content: Content) -> some View {
        content
            .environment(\.openTrackerItem, relay.action)
            .onChange(of: relay.pending) { _, tap in
                guard let tap else { return }
                Task { @MainActor in await open(tap.num) }
            }
            // Same chrome as every other tracker error (`ItemsPanelViewModel.error`).
            .alert("Tracker", isPresented: Binding(
                get: { relay.alert != nil },
                set: { if !$0 { relay.alert = nil } })) {
                Button("OK") { relay.alert = nil }
            } message: {
                Text(relay.alert ?? "")
            }
    }
}

extension View {
    /// See `TrackerItemLinksModifier`. `open` receives the tapped NUMBER and
    /// is responsible for resolving it (`TrackerItemLinkResolver`) and either
    /// navigating or setting `relay.alert`.
    public func trackerItemLinks(_ relay: TrackerItemLinkRelay,
                                 open: @escaping (Int) async -> Void) -> some View {
        modifier(TrackerItemLinksModifier(relay: relay, open: open))
    }
}
