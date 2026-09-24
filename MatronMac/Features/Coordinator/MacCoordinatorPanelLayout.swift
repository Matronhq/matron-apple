import CoreGraphics

/// Geometry of the window's Coordinator panel (Coordinator redesign §3b).
/// Pure so the rules are testable without a window.
enum MacCoordinatorPanelLayout {
    static let minWidth: CGFloat = 320
    static let idealWidth: CGFloat = 380
    static let maxWidth: CGFloat = 720
    /// The detail's floor beside the panel: `MacChatView`'s chat column
    /// minimum (420). Below it the panel overlays instead of squeezing.
    static let detailMinWidth: CGFloat = 420

    enum Mode: Equatable { case closed, beside, overlay }

    static func clamp(_ width: CGFloat) -> CGFloat { min(max(width, minWidth), maxWidth) }

    static func mode(isOpen: Bool, containerWidth: CGFloat, panelWidth: CGFloat) -> Mode {
        guard isOpen else { return .closed }
        return containerWidth - clamp(panelWidth) >= detailMinWidth ? .beside : .overlay
    }

    /// Trailing padding for the detail: the panel's width beside it, none
    /// under an overlay or with the panel closed.
    static func detailTrailingPadding(mode: Mode, panelWidth: CGFloat) -> CGFloat {
        mode == .beside ? clamp(panelWidth) : 0
    }

    /// How far the chat header keeps its capsules from the window's
    /// trailing edge: the panel's width whenever the panel shows.
    static func headerTrailingInset(isOpen: Bool, panelWidth: CGFloat) -> CGFloat {
        isOpen ? clamp(panelWidth) : 0
    }

    /// The width the panel is actually drawn at: nothing closed, its own
    /// width beside the detail, and under an overlay never wider than the
    /// container. The header's trailing inset is this value (published by
    /// `MacCoordinatorPanelContainer`), so it matches what is on screen.
    static func drawnPanelWidth(mode: Mode, panelWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        switch mode {
        case .closed: return 0
        case .beside: return clamp(panelWidth)
        case .overlay: return max(0, min(clamp(panelWidth), containerWidth))
        }
    }

    /// Width after dragging the panel's LEADING edge by `translation`
    /// (positive = rightwards, which narrows the panel).
    static func resized(from start: CGFloat, translation: CGFloat) -> CGFloat {
        clamp(start - translation)
    }
}
