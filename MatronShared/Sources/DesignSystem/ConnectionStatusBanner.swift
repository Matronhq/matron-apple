import SwiftUI

/// Thin coloured strip at the top of the chat list that surfaces sliding
/// sync's connection state. Mirrors the existing chat-list verification
/// banners in shape (full-width, leading-aligned, ultra-thin material
/// for the warm states; opaque red for offline) so the user has a
/// consistent vocabulary for "the app is telling you something" across
/// surfaces.
///
/// Three visual states, driven by `state`:
///   * `.connecting` — accent-tinted material strip with a tiny
///     `ProgressView` and "Connecting…" / "Reconnecting…" copy. Picks
///     between those two strings via `hasEverBeenRunning` so a fresh
///     app open doesn't say "Reconnecting" before there's been a
///     connection to lose.
///   * `.running` — view returns nothing (zero-height). Caller can wrap
///     in `if state != .running { … }` but rendering the empty body
///     here lets the call site stay flat without an explicit guard.
///   * `.offline(reason:)` — opaque red strip with the reason. No
///     progress indicator — the SDK handles retry; the banner just
///     reports the steady-state.
public struct ConnectionStatusBanner: View {
    private let state: SyncBannerState
    /// Whether the app has ever observed a successful connection in
    /// this session. Drives the "Connecting…" vs "Reconnecting…" copy
    /// — both map to `.connecting` in the model, but pre-first-run is
    /// "Connecting" and any subsequent connecting state is
    /// "Reconnecting" (the connection got dropped after we'd been
    /// running). Owned by the caller because it tracks lifetime
    /// state across multiple banner mounts.
    private let hasEverConnected: Bool

    public init(state: SyncBannerState, hasEverConnected: Bool) {
        self.state = state
        self.hasEverConnected = hasEverConnected
    }

    public var body: some View {
        switch state {
        case .running:
            EmptyView()
        case .connecting:
            connectingBanner
        case .offline(let reason):
            offlineBanner(reason: reason)
        }
    }

    private var connectingBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(hasEverConnected ? "Reconnecting…" : "Connecting…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hasEverConnected ? "Reconnecting" : "Connecting")
        .accessibilityIdentifier("sync.banner.connecting")
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func offlineBanner(reason: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.white)
            // Default copy when the SDK doesn't hand us a reason — the
            // user still gets a meaningful signal ("you're offline")
            // without an empty trailing colon.
            Text(reason ?? "Offline")
                .font(.callout)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.9))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Offline: \(reason ?? "no connection")")
        .accessibilityIdentifier("sync.banner.offline")
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Local mirror of the connection-state enum the View consumes. Defined
/// in `MatronDesignSystem` so the banner doesn't have to import
/// `MatronSync` (the design-system target deliberately stays free of
/// SDK / service-layer dependencies). Hosts in `Matron` / `MatronMac`
/// translate from `SyncConnectionState` to this local type at the
/// boundary — mapping is identity-shaped, so the cost is one switch.
public enum SyncBannerState: Equatable, Sendable {
    case connecting
    case running
    case offline(reason: String?)
}
