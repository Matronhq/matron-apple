import AppKit
import Observation
import SwiftUI

/// Where Edit ▸ Find in Chat (⌘F) lands in one window (tracker #2864 A).
/// Pure, so the routing is testable without a window.
enum MacFindInChatRouting {
    enum Target: Equatable {
        /// The Coordinator panel's chat.
        case panel
        /// The chat in the detail column.
        case main
        /// No chat on screen: the sidebar's search-all-chats field, as ⌘F
        /// did before Find in Chat.
        case globalSearch
    }

    /// The chat holding keyboard focus wins; otherwise the main chat, then
    /// the panel's (Missions or Decisions beside an open panel). `nil` when
    /// there is nothing to search.
    static func target(focusInPanel: Bool, panelHasChat: Bool,
                       mainHasChat: Bool, globalSearchAvailable: Bool) -> Target? {
        if focusInPanel, panelHasChat { return .panel }
        if mainHasChat { return .main }
        if panelHasChat { return .panel }
        return globalSearchAvailable ? .globalSearch : nil
    }
}

/// A screen region of one window — the Coordinator panel — that can say
/// whether the window's first responder sits inside it. Keyboard focus in
/// the panel lives in AppKit views (the composer's `NSTextView`, the
/// transcript's text views, a text field's field editor), which SwiftUI's
/// focus system does not report, and every chat in the window shares one
/// hosting view, so view ancestry can't tell the panel's from the main
/// chat's either. The test is geometric, on the responder's VISIBLE part
/// (review I1: a 3000 pt reply's bounds centre is off the window; a view
/// scrolled out of sight has no visible part and claims nothing).
@MainActor
final class MacFocusRegion {
    /// The probe view spanning the region (`MacFocusRegionProbe`). Weak:
    /// the view hierarchy owns it.
    weak var view: NSView?

    func containsFirstResponder() -> Bool {
        guard let view, let window = view.window,
              let responder = window.firstResponder as? NSView,
              responder.window === window else { return false }
        // Intersected with the bounds: `NSTextView.visibleRect` reports its
        // superview's whole visible area, unclipped to the text view.
        let visible = responder.visibleRect.intersection(responder.bounds)
        return Self.contains(responderRect: responder.convert(visible, to: nil),
                             regionRect: view.convert(view.bounds, to: nil))
    }

    /// `responderRect` is the responder's visible rect in window
    /// coordinates. Judged at its LEADING edge, not its centre: in overlay
    /// mode the main chat runs on under the panel, so the main composer's
    /// centre can sit inside the panel's rect while its leading edge never
    /// does (review I2). Empty (scrolled out, unmounted) claims nothing.
    nonisolated static func contains(responderRect: CGRect, regionRect: CGRect) -> Bool {
        guard !responderRect.isEmpty, !regionRect.isEmpty else { return false }
        let probe = CGPoint(x: min(responderRect.minX + 1, responderRect.midX), y: responderRect.midY)
        return regionRect.contains(probe)
    }
}

/// Whether a chat's transcript column is on screen. `MacChatView` renders
/// it in several structural branches and drops it entirely when a sub-chat
/// or the items pane takes over a narrow detail; a find opened then would
/// leave an invisible bar behind (review I3). Counts appear/disappear
/// pairs: on a branch move the new column can appear before the old one
/// disappears.
/// Observable because the Find in Chat menu item's enabled state reads the
/// panel's presence in the window's body.
@MainActor @Observable
final class MacChatColumnPresence {
    private var visibleCount = 0

    var isShown: Bool { visibleCount > 0 }

    func appeared() { visibleCount += 1 }

    func disappeared() { visibleCount = max(0, visibleCount - 1) }
}

extension View {
    /// Counts this chat column in and out of `presence`.
    func reportsChatColumnPresence(_ presence: MacChatColumnPresence?) -> some View {
        onAppear { presence?.appeared() }
            .onDisappear { presence?.disappeared() }
    }
}

extension EnvironmentValues {
    /// The window's presence tracker for the chat mounted below — one for
    /// the detail, one for the Coordinator panel. `nil` outside a window
    /// shell (previews, tests).
    @Entry var macChatColumnPresence: MacChatColumnPresence? = nil
}

/// Zero-behaviour `NSView` filling the region it backs, handed to a
/// `MacFocusRegion`. Sits in a `.background`, so it takes the region's
/// frame and never takes clicks.
struct MacFocusRegionProbe: NSViewRepresentable {
    let region: MacFocusRegion

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView(frame: .zero)
        region.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        region.view = nsView
    }

    private final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
