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

    /// The panel's width when the current drag began. `@GestureState`, so
    /// a cancelled drag (the window losing key mid-drag, say) resets it
    /// and the next drag starts from the live width.
    @GestureState private var dragStart: CGFloat?

    /// The handle's hit area either side of its 1 pt line.
    static var handleHitWidth: CGFloat { 9 }

    init(isOpen: Bool, width: Binding<Double>,
         @ViewBuilder detail: @escaping () -> Detail, @ViewBuilder panel: @escaping () -> Panel) {
        self.isOpen = isOpen
        self._width = width
        self.detail = detail
        self.panel = panel
    }

    var body: some View {
        GeometryReader { geo in
            let panelWidth = MacCoordinatorPanelLayout.clamp(CGFloat(width))
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

    private func panelColumn(width: CGFloat, overlay: Bool) -> some View {
        panel()
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(.background)
            // The line sits on the panel's leading edge; its wider hit
            // area straddles it, over the detail's last few points.
            .overlay(alignment: .leading) { resizeHandle }
            .shadow(color: .black.opacity(overlay ? 0.18 : 0), radius: overlay ? 12 : 0, x: -2)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(width: Self.handleHitWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .offset(x: -Self.handleHitWidth / 2 + 0.5)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    // One callback: `start` is this drag's own state, so
                    // the width never compounds on an update that ran
                    // before the gesture state landed.
                    .updating($dragStart) { value, start, _ in
                        let origin = start ?? CGFloat(width)
                        start = origin
                        width = Double(MacCoordinatorPanelLayout.resized(from: origin, translation: value.translation.width))
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
