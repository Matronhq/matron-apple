import SwiftUI

/// Where the list rows with a trailing swipe action (swipe left to archive)
/// are on screen, in global coordinates. The shell's swipe between tabs
/// reads it when a drag starts: a leftward drag that starts on such a row
/// belongs to the row, so the tab must not switch as well. Rows register
/// with `ownsTrailingRowSwipe()`.
///
/// A plain class, not `@Observable`: frames change on every scroll, and
/// nothing needs to redraw when they do.
@MainActor
final class RowSwipeZones {
    private var frames: [AnyHashable: CGRect] = [:]

    func set(_ frame: CGRect, for id: AnyHashable) { frames[id] = frame }
    func remove(_ id: AnyHashable) { frames[id] = nil }

    /// Whether a drag starting at `point` (global coordinates) starts on a
    /// registered row.
    func contains(_ point: CGPoint) -> Bool {
        frames.values.contains { $0.contains(point) }
    }
}

private struct RowSwipeZonesKey: EnvironmentKey {
    static let defaultValue: RowSwipeZones? = nil
}

extension EnvironmentValues {
    /// The shell's `RowSwipeZones`; `nil` outside the shell.
    var rowSwipeZones: RowSwipeZones? {
        get { self[RowSwipeZonesKey.self] }
        set { self[RowSwipeZonesKey.self] = newValue }
    }
}

/// See `ownsTrailingRowSwipe()`.
private struct OwnsTrailingRowSwipe: ViewModifier {
    @Environment(\.rowSwipeZones) private var zones
    /// This row's own key, so two rows never share or remove each
    /// other's zone.
    @State private var key = UUID()
    /// The row's last frame. A tab switch hides the row and brings it back
    /// without moving it, so no geometry change re-registers it: it is
    /// put back from here on appear.
    @State private var frame: CGRect?
    /// Only a row on screen has a zone; a geometry change while hidden
    /// must not put it back.
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { newFrame in
                frame = newFrame
                if isVisible { zones?.set(newFrame, for: key) }
            }
            .onAppear {
                isVisible = true
                if let frame { zones?.set(frame, for: key) }
            }
            .onDisappear {
                isVisible = false
                zones?.remove(key)
            }
    }
}

extension View {
    /// Marks a list row whose `.swipeActions(edge: .trailing)` owns a
    /// leftward drag started on it, so the shell's swipe between tabs
    /// leaves that drag alone.
    func ownsTrailingRowSwipe() -> some View {
        modifier(OwnsTrailingRowSwipe())
    }
}
