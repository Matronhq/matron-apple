import SwiftUI
#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

/// Hiding the iOS keyboard from a composer row. Two gestures reach the
/// same intent — dragging the timeline down through the keyboard
/// (`ScrollView.scrollDismissesKeyboard(.interactively)`, applied at each
/// timeline) and dragging the composer row itself downward, which is the
/// gesture people actually reach for when they want the screen back to
/// read. The latter has no SwiftUI equivalent, so it lives here.
public enum KeyboardDismiss {
    /// Drops the keyboard by resigning whatever is first responder. The
    /// composers are plain `TextField`s with no `@FocusState` seam of
    /// their own (same reason `ChatPagerModel` resigns this way), so the
    /// responder chain is the only handle. A no-op on the Mac.
    public static func resign() {
        #if canImport(UIKit) && !os(macOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    /// Whether a drag on the composer row has become a "hide the
    /// keyboard" gesture: mostly vertical and downward by at least
    /// `minimumDrop` points. Upward and sideways drags (text selection,
    /// a slip while reaching for the send button) never count.
    static func shouldDismiss(translation: CGSize, minimumDrop: CGFloat = 24) -> Bool {
        translation.height >= minimumDrop && translation.height > abs(translation.width)
    }
}

public extension View {
    /// Dragging this view downward hides the keyboard (iOS only; the
    /// modifier is inert on the Mac). Attached as a *simultaneous*
    /// gesture so the field's own touches — caret placement, selection,
    /// scrolling a tall draft — keep working; the dismissal simply fires
    /// alongside them once the drag reads as a deliberate pull-down.
    func dragDownDismissesKeyboard() -> some View {
        #if canImport(UIKit) && !os(macOS)
        return simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .local)
                .onChanged { value in
                    if KeyboardDismiss.shouldDismiss(translation: value.translation) {
                        KeyboardDismiss.resign()
                    }
                }
        )
        #else
        return self
        #endif
    }
}
