import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A weak handle to the platform scroll view backing a SwiftUI
/// `ScrollView`, captured via `captureNativeScrollView(into:)`.
///
/// Exists for exactly one job the SwiftUI surface cannot do: killing an
/// in-flight fling. `proxy.scrollTo` issued during deceleration is
/// overridden by the deceleration's animator for its entire 1–2s life,
/// and `.scrollDisabled(true)` only stops *touch handling* — the
/// deceleration animation runs to completion regardless (both proven on
/// device, 2026-07-14 traces: jump presses "waited for the scroll to
/// finish"). UIKit's zero-delta `setContentOffset(_:animated:false)` is
/// the canonical instant kill; AppKit's `scroll(to:)` +
/// `reflectScrolledClipView` is the equivalent.
///
/// A class box (not view state): the reference is written from inside a
/// representable during layout and read from button handlers — value
/// state would re-evaluate the host body per write for no visual gain.
@MainActor
public final class NativeScrollViewBox {
    #if canImport(UIKit)
    public weak var scrollView: UIScrollView?
    #elseif canImport(AppKit)
    public weak var scrollView: NSScrollView?
    #endif

    public init() {}

    /// Cancels any in-flight deceleration and pins the viewport to the
    /// very bottom of the content, without animation, in one frame.
    /// Callers should still follow up with `proxy.scrollTo(id, anchor:
    /// .bottom)` — that keeps row-identity exactness (insets, footers)
    /// owned by SwiftUI while this guarantees the fling is dead and the
    /// bulk of the distance is covered.
    public func killMomentumAndSnapToBottom() {
        guard let scrollView else { return }
        #if canImport(UIKit)
        // Zero-delta write: kills the deceleration animator dead.
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        let bottomY = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: bottomY),
            animated: false
        )
        #elseif canImport(AppKit)
        let clip = scrollView.contentView
        let docHeight = scrollView.documentView?.frame.height ?? 0
        let bottomY = max(0, docHeight - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: bottomY))
        scrollView.reflectScrolledClipView(clip)
        #endif
    }
}

public extension View {
    /// Captures the enclosing platform scroll view into `box`. Attach
    /// INSIDE the `ScrollView`'s content (e.g. as a `.background` of the
    /// content stack) — the capture walks *up* the native view hierarchy
    /// from the injected helper view.
    ///
    /// `lockingHorizontalOverflow` additionally installs a
    /// `HorizontalOverflowLock` on the captured scroll view (iOS only —
    /// the AppKit timeline has never exhibited the wiggle, and NSScrollView
    /// constrains its document view differently).
    func captureNativeScrollView(
        into box: NativeScrollViewBox,
        lockingHorizontalOverflow: Bool = false
    ) -> some View {
        background(NativeScrollViewCapture(
            box: box, lockHorizontalOverflow: lockingHorizontalOverflow))
    }
}

#if canImport(UIKit)
private struct NativeScrollViewCapture: UIViewRepresentable {
    let box: NativeScrollViewBox
    let lockHorizontalOverflow: Bool

    func makeUIView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.box = box
        view.lockHorizontalOverflow = lockHorizontalOverflow
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: CaptureView, context: Context) {
        uiView.box = box
        uiView.lockHorizontalOverflow = lockHorizontalOverflow
    }

    final class CaptureView: UIView {
        var box: NativeScrollViewBox?
        var lockHorizontalOverflow = false
        private var overflowLock: HorizontalOverflowLock?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            var candidate = superview
            while let view = candidate, !(view is UIScrollView) {
                candidate = view.superview
            }
            let scrollView = candidate as? UIScrollView
            box?.scrollView = scrollView
            if lockHorizontalOverflow, overflowLock == nil, let scrollView {
                overflowLock = HorizontalOverflowLock(scrollView: scrollView)
            }
        }
    }
}
#elseif canImport(AppKit)
private struct NativeScrollViewCapture: NSViewRepresentable {
    let box: NativeScrollViewBox
    /// Unused on AppKit — the wiggle is a UIScrollView behavior and the Mac
    /// timeline has never exhibited it; accepted so the shared modifier's
    /// call site compiles for both platforms.
    let lockHorizontalOverflow: Bool

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.box = box
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.box = box
    }

    final class CaptureView: NSView {
        var box: NativeScrollViewBox?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box?.scrollView = enclosingScrollView
        }
    }
}
#endif
