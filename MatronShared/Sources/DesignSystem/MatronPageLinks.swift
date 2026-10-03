import SwiftUI
import MatronModels

// Mission and project links.
//
// Agents link a mission or a project the way they link a tracker item —
// `[#61](matron://mission/61)`, `[Promo](matron://project/12)` — and, like
// every `matron://` link, a tap resolves in-app: the scheme is registered
// with nothing (`MatronItemLink`). A renderer routes the tap through the
// `\.openPageLink` environment action, installed once per window/shell by
// `pageLinks(_:resolve:open:)`.

/// One tap on a mission or project link. The `id` makes two taps on the
/// same page two distinct values, so the host's `onChange` sees both.
public struct MatronPageLinkTap: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public let link: MatronPageLink
    public init(link: MatronPageLink) { self.link = link }
}

/// What a resolved page-link tap should do. The host's `resolve` closure
/// answers one of these (typically by mapping
/// `PageLinkResolver.Resolution`) and the modifier applies it.
public enum MatronPageLinkOutcome: Equatable, Sendable {
    /// The number resolved to a local page — navigate to it.
    case open(MatronPageTarget)
    /// It didn't, and this is what to tell the user.
    case explain(String)
    /// The host couldn't even try (no session yet). Say nothing.
    case ignore
}

/// Tap relay for one window (Mac) or the signed-in shell (iOS), held in
/// `@State` by the host view. `action` is ONE closure for the relay's
/// lifetime, for the reason `TrackerItemLinkRelay` gives: every rendered
/// body reads it from the environment.
@MainActor @Observable
public final class MatronPageLinkRelay {
    /// The most recent tap; see `MatronPageLinkTap`.
    public private(set) var pending: MatronPageLinkTap?
    /// Message for the alert when a tap did not open anything. Written and
    /// cleared by `pageLinks(_:resolve:open:)`.
    public var alert: String?

    /// The environment action. Same instance for this relay's lifetime.
    @ObservationIgnored public private(set) var action: (MatronPageLink) -> Void = { _ in }

    public init() {
        action = { [weak self] link in self?.pending = MatronPageLinkTap(link: link) }
    }

    /// Whether `tap` is still the latest one — a resolve that a newer tap
    /// overtook must not act (last tap wins).
    func isCurrent(_ tap: MatronPageLinkTap) -> Bool { pending?.id == tap.id }
}

/// Opens a mission or project page named by number. `nil` — the default —
/// means no host is installed, and such links are swallowed rather than
/// handed to the OS. Installed by `pageLinks(_:resolve:open:)`.
struct OpenPageLinkKey: EnvironmentKey {
    static let defaultValue: ((MatronPageLink) -> Void)? = nil
}

extension EnvironmentValues {
    public var openPageLink: ((MatronPageLink) -> Void)? {
        get { self[OpenPageLinkKey.self] }
        set { self[OpenPageLinkKey.self] = newValue }
    }
}

private struct MatronPageLinksModifier: ViewModifier {
    let relay: MatronPageLinkRelay
    let resolve: (MatronPageLink) async -> MatronPageLinkOutcome
    let open: (MatronPageTarget) -> Void

    func body(content: Content) -> some View {
        // Read during body evaluation so a later write re-renders the
        // alert — see `TrackerItemLinksModifier`.
        let message = relay.alert
        return content
            .environment(\.openPageLink, relay.action)
            .onChange(of: relay.pending) { _, tap in
                guard let tap else { return }
                Task { @MainActor in
                    let outcome = await resolve(tap.link)
                    guard relay.isCurrent(tap) else { return }
                    switch outcome {
                    case .open(let target): open(target)
                    case .explain(let message): relay.alert = message
                    case .ignore: break
                    }
                }
            }
            .alert("Projects", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { relay.alert = nil } })) {
                Button("OK") { relay.alert = nil }
            } message: {
                Text(message ?? "")
            }
    }
}

extension View {
    /// Installs `relay` as the host for `matron://mission/<n>` and
    /// `matron://project/<n>` links in everything below: the environment
    /// action every rendered body reads, the tap → `resolve` hop, and the
    /// alert for a number that did not resolve. `open` runs only for the
    /// latest tap. Apply ONCE, at the window / shell root.
    public func pageLinks(_ relay: MatronPageLinkRelay,
                          resolve: @escaping (MatronPageLink) async -> MatronPageLinkOutcome,
                          open: @escaping (MatronPageTarget) -> Void) -> some View {
        modifier(MatronPageLinksModifier(relay: relay, resolve: resolve, open: open))
    }
}

// MARK: - Link routing for plain Text

/// See `View.inAppLinks()`.
private struct InAppLinksModifier: ViewModifier {
    @Environment(\.openTrackerItem) private var openTrackerItem
    @Environment(\.openConversation) private var openConversation
    @Environment(\.openPageLink) private var openPageLink

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            MarkdownText.handle(url: url, openItem: openTrackerItem, openConversation: openConversation,
                                openPage: openPageLink)
        })
    }
}

extension View {
    /// Routes every link tapped in this view through the app's link policy
    /// (`MatronItemLink.action(for:)`): `matron://` item, conversation,
    /// mission and project links open in-app through the environment's
    /// hosts, and web links go to the system.
    ///
    /// A SwiftUI `Text` built from markdown styles a link and hands the tap
    /// to `\.openURL`, whose default sends it to the OS — and the `matron`
    /// scheme is registered with nothing, so the tap did nothing (mission
    /// 7568). Apply this to any view that shows such text, inside whatever
    /// installs the hosts.
    public func inAppLinks() -> some View {
        modifier(InAppLinksModifier())
    }
}
