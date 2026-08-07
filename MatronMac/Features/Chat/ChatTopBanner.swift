import SwiftUI

/// Insets and rounds the attention banners that sit above the timeline —
/// the chat-error strip and `CompactContextBanner` — so they read as cards
/// at the top of the conversation rather than bands welded to the window
/// frame.
///
/// Both banners were full-bleed (`frame(maxWidth: .infinity)` over an
/// opaque red), which on macOS 26 collides with the floating sidebar.
/// Measured in the running app (Dan, 2026-08-07, 1497pt window): the
/// compact banner spanned x 987→2084 — starting exactly on the sidebar
/// divider, 400pt (one sidebar width) narrower than the window — and its
/// vertical band, 82→113, bracketed the sidebar search field's 93→109.
/// Nothing was actually occluding it, but a solid colour butting flush
/// into the divider at exactly search-field height reads as continuing
/// underneath the sidebar, which is what it looked like ("the red bar goes
/// behind the sidebar / search bar").
///
/// The horizontal inset is deliberately the same bare `.padding(.horizontal)`
/// the timeline rows use (`MacTimelineItemView`), not a literal: the banner
/// should stay aligned with the message content if that metric ever moves.
///
/// Mac-only, and it stays at the call site rather than moving into
/// `CompactContextBanner`: iOS and Android have no sidebar, and full-bleed
/// is the right treatment there — the shared component keeps its own look.
extension View {
    func chatTopBanner() -> some View {
        modifier(ChatTopBanner())
    }
}

struct ChatTopBanner: ViewModifier {
    /// Matches the bubble corner rounding so the banner belongs to the
    /// same family as the rows below it.
    static let cornerRadius: CGFloat = 8

    /// Lifts the banner off the toolbar. Without it the strip sits hard
    /// against the window chrome, which is half of what made it read as
    /// part of the frame.
    static let topSpacing: CGFloat = 8

    func body(content: Content) -> some View {
        content
            // Clip BEFORE padding — padding outside the clip is the margin
            // that keeps the colour off the sidebar divider.
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .padding(.horizontal)
            .padding(.top, Self.topSpacing)
    }
}
