import AppKit
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
/// focus system does not report, so the test is geometric: the responder's
/// centre inside the region's window rect.
@MainActor
final class MacFocusRegion {
    /// The probe view spanning the region (`MacFocusRegionProbe`). Weak:
    /// the view hierarchy owns it.
    weak var view: NSView?

    func containsFirstResponder() -> Bool {
        guard let view, let window = view.window,
              let responder = window.firstResponder as? NSView,
              responder.window === window else { return false }
        return Self.contains(responderRect: responder.convert(responder.bounds, to: nil),
                             regionRect: view.convert(view.bounds, to: nil))
    }

    nonisolated static func contains(responderRect: CGRect, regionRect: CGRect) -> Bool {
        guard !regionRect.isEmpty else { return false }
        return regionRect.contains(CGPoint(x: responderRect.midX, y: responderRect.midY))
    }
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
