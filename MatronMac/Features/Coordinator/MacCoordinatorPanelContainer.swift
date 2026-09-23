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
struct MacCoordinatorPanelContainer<Detail: View, Panel: View>: View {
    let isOpen: Bool
    @Binding var width: Double
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let panel: () -> Panel

    @State private var dragStart: CGFloat?

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
            ZStack(alignment: .trailing) {
                detail()
                    .padding(.trailing, MacCoordinatorPanelLayout.detailTrailingPadding(mode: mode, panelWidth: panelWidth))
                if mode != .closed {
                    panelColumn(width: min(panelWidth, geo.size.width), overlay: mode == .overlay)
                }
            }
        }
    }

    private func panelColumn(width: CGFloat, overlay: Bool) -> some View {
        HStack(spacing: 0) {
            resizeHandle
            panel()
        }
        .frame(width: width)
        .background(.background)
        .shadow(color: .black.opacity(overlay ? 0.18 : 0), radius: overlay ? 12 : 0, x: -2)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? CGFloat(width)
                        if dragStart == nil { dragStart = start }
                        width = Double(MacCoordinatorPanelLayout.resized(from: start, translation: value.translation.width))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityHidden(true)
    }
}
