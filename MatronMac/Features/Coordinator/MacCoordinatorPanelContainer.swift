import SwiftUI
import AppKit

/// The detail column with the Coordinator panel at its trailing edge
/// (Coordinator redesign §3b). Sits OUTSIDE the per-nav detail content, so
/// the panel survives moving between Conversations, Missions and Decisions
/// and every Back/Forward. The detail keeps one structural position open
/// or closed (a `ZStack` child with trailing padding), so toggling or
/// resizing the panel never remounts the transcript. No `NavigationStack`
/// in here: inside a `NavigationSplitView` detail it would push onto the
/// column's own stack (#2608).
///
/// Publishes the width it actually DRAWS the panel at as
/// `MacCoordinatorPanelInsetPreference`, so `MacChatHeaderHost` keeps the
/// header off exactly that — the same open/width state, and in overlay
/// mode the clipped width rather than the stored one.
struct MacCoordinatorPanelContainer<Detail: View, Panel: View>: View {
    let isOpen: Bool
    @Binding var width: Double
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let panel: () -> Panel

    /// The live drag's horizontal translation. The panel draws at the
    /// dragged width from this local state, and the stored width (the
    /// window's `@SceneStorage`, whose every write re-evaluates the root
    /// view) is written once, on release. `@GestureState`, so a cancelled
    /// drag (the window losing key mid-drag, say) snaps back and writes
    /// nothing.
    @GestureState private var dragTranslation: CGFloat?

    /// The handle's hit area around its 1 pt line (on the panel's leading
    /// edge): a little over the detail, mostly inside the panel, so it
    /// barely overlaps the detail's trailing edge (scroller, bubbles).
    static var handleOutside: CGFloat { 2 }
    static var handleInside: CGFloat { 7 }

    init(isOpen: Bool, width: Binding<Double>,
         @ViewBuilder detail: @escaping () -> Detail, @ViewBuilder panel: @escaping () -> Panel) {
        self.isOpen = isOpen
        self._width = width
        self.detail = detail
        self.panel = panel
    }

    var body: some View {
        GeometryReader { geo in
            let panelWidth = liveWidth
            let mode = MacCoordinatorPanelLayout.mode(isOpen: isOpen, containerWidth: geo.size.width, panelWidth: panelWidth)
            let drawn = MacCoordinatorPanelLayout.drawnPanelWidth(mode: mode, panelWidth: panelWidth,
                                                                   containerWidth: geo.size.width)
            ZStack(alignment: .trailing) {
                detail()
                    .padding(.trailing, MacCoordinatorPanelLayout.detailTrailingPadding(mode: mode, panelWidth: panelWidth))
                if mode != .closed {
                    panelColumn(width: drawn, overlay: mode == .overlay)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .trailing)
            .preference(key: MacCoordinatorPanelInsetPreference.self, value: drawn)
        }
    }

    /// The stored width, or the dragged one while a drag is live.
    private var liveWidth: CGFloat {
        guard let dragTranslation else { return MacCoordinatorPanelLayout.clamp(CGFloat(width)) }
        return MacCoordinatorPanelLayout.resized(from: CGFloat(width), translation: dragTranslation)
    }

    private func panelColumn(width: CGFloat, overlay: Bool) -> some View {
        panel()
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(.background)
            // The line sits on the panel's leading edge; its hit area
            // reaches `handleOutside` over the detail.
            .overlay(alignment: .leading) { resizeHandle }
            .shadow(color: .black.opacity(overlay ? 0.18 : 0), radius: overlay ? 12 : 0, x: -2)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            // Line centred on the panel's edge: half a point either side.
            .padding(.leading, Self.handleOutside - 0.5)
            .frame(width: Self.handleOutside + Self.handleInside, alignment: .leading)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .offset(x: -Self.handleOutside)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($dragTranslation) { value, translation, _ in
                        translation = value.translation.width
                    }
                    .onEnded { value in
                        width = Double(MacCoordinatorPanelLayout.resized(from: CGFloat(width),
                                                                         translation: value.translation.width))
                    }
            )
            .accessibilityHidden(true)
    }
}

/// The width the window's Coordinator panel is drawn at (0 closed), read by
/// `MacChatHeaderHost` for the header's trailing inset. `nil` means no
/// panel container is mounted below, and the host's own `trailingInset`
/// applies.
struct MacCoordinatorPanelInsetPreference: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}
