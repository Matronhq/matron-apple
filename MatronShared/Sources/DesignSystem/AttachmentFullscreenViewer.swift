import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Fullscreen image viewer presented from a chat attachment tap. iOS
/// supports pinch-zoom + swipe-down-to-dismiss; Mac displays the
/// resolved `Image` with a "Done" button (Mac doesn't have the touch
/// gestures, and adding click-and-drag pan would diverge from the
/// platform's native QuickLook conventions).
///
/// The `Image` is taken pre-resolved (via `ChatViewModel.image(for:)`)
/// so the viewer stays a leaf View — avoids dragging `MediaService`
/// into `MatronDesignSystem` for one sheet.
public struct AttachmentFullscreenViewer: View {
    private let image: Image
    /// Native bitmap size in pixels, when the call site knows it. Mac
    /// uses it to open the sheet at the image's natural size instead of
    /// a fixed 480pt minimum that shrank big photos and stretched small
    /// bitmaps into pixelation. `nil` (iOS call sites, or an image whose
    /// size never resolved) keeps the legacy flexible layout.
    private let nativePixelSize: CGSize?
    private let onDismiss: () -> Void

    public init(
        image: Image,
        nativePixelSize: CGSize? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.image = image
        self.nativePixelSize = nativePixelSize
        self.onDismiss = onDismiss
    }

    public var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    // MARK: - iOS

    #if !os(macOS)
    /// iOS body. Pinch-to-zoom anchored on the pinch itself, one-finger
    /// pan once zoomed, double-tap to toggle, and swipe-down to dismiss
    /// while at fit scale. See `FullscreenImageBody`.
    @ViewBuilder
    private var iosBody: some View {
        FullscreenImageBody(image: image, onDismiss: onDismiss)
    }
    #endif

    // MARK: - Mac

    #if os(macOS)
    /// Scale of the screen the sheet lands on — needed to translate the
    /// bitmap's pixel size into the largest point size that doesn't
    /// upscale (2x screen → half the pixels, in points).
    @Environment(\.displayScale) private var displayScale

    @ViewBuilder
    private var macBody: some View {
        // Mac sheet sizing, probed empirically (2026-08-12): a sheet only
        // adopts its content's size when the content is fully RIGID. Any
        // flexibility (a `minWidth`/`minHeight` range, a bare `resizable`
        // image) collapses the sheet to a small system default that gets
        // proposed to the content — which is exactly the old "small and
        // pixelated" bug. So when the bitmap's native size is known, the
        // whole body takes an explicit width × height. macOS does NOT
        // clamp sheets to the parent window, so the display size must be
        // screen-bounded here.
        if let displaySize = nativePixelSize.flatMap({
            Self.imageDisplaySize(
                pixelSize: $0,
                displayScale: displayScale,
                bound: Self.screenBound()
            )
        }) {
            VStack(spacing: 0) {
                doneRow.frame(height: Self.doneRowHeight)
                image
                    .resizable()
                    // High interpolation for the big downscales (a 12MP
                    // photo fit to ~1000pt) that alias visibly at the
                    // default.
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: displaySize.width, height: displaySize.height)
                    // Fill whatever the min-size floor adds beyond the
                    // image, keeping a small bitmap centred at 1:1 rather
                    // than stretched.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Self.imagePadding)
            }
            .frame(
                width: max(480, displaySize.width + Self.imagePadding * 2),
                height: max(
                    360,
                    displaySize.height + Self.imagePadding * 2 + Self.doneRowHeight
                )
            )
            .background(Color.black.opacity(0.85))
            .accessibilityLabel("Image preview")
        } else {
            // Legacy flexible layout for call sites that can't supply a
            // pixel size (never on Mac today, but the parameter is
            // optional).
            VStack(spacing: 0) {
                doneRow
                image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding()
                Spacer(minLength: 0)
            }
            .frame(minWidth: 480, minHeight: 360)
            .background(Color.black.opacity(0.85))
            .accessibilityLabel("Image preview")
        }
    }

    @ViewBuilder
    private var doneRow: some View {
        HStack {
            Spacer()
            Button("Done") { onDismiss() }
                .keyboardShortcut(.cancelAction)
                .padding()
        }
    }

    /// Largest display rect the image may occupy: 85% of the main
    /// screen's visible frame, less the sheet chrome around the image.
    /// Falls back to a conservative laptop-ish bound when no screen is
    /// available (headless tests).
    private static func screenBound() -> CGSize {
        let visible = NSScreen.main?.visibleFrame.size
            ?? CGSize(width: 1280, height: 800)
        return CGSize(
            width: visible.width * 0.85 - imagePadding * 2,
            height: visible.height * 0.85 - imagePadding * 2 - doneRowHeight
        )
    }

    /// Fixed height for the Done-button row. Fixed (not intrinsic) so the
    /// sheet's total height can be computed exactly — the rigid frame is
    /// what makes the sheet adopt the content size at all.
    private static let doneRowHeight: CGFloat = 52
    /// Padding around the image inside the sheet.
    private static let imagePadding: CGFloat = 16
    #endif

    /// Display size in points for a bitmap of `pixelSize` shown on a
    /// screen of `displayScale`, bounded by `bound` (points): 1:1 pixels
    /// when the image fits, aspect-fit downscale when it doesn't, never
    /// an upscale. Returns `nil` for degenerate inputs (zero-area image
    /// or bound), which callers treat as "fall back to flexible layout".
    /// Platform-independent math, `static` for direct unit testing.
    static func imageDisplaySize(
        pixelSize: CGSize,
        displayScale: CGFloat,
        bound: CGSize
    ) -> CGSize? {
        guard pixelSize.width > 0, pixelSize.height > 0,
              bound.width > 0, bound.height > 0 else { return nil }
        let scale = displayScale > 0 ? displayScale : 1
        let natural = CGSize(width: pixelSize.width / scale,
                             height: pixelSize.height / scale)
        let ratio = min(bound.width / natural.width,
                        bound.height / natural.height, 1)
        return CGSize(width: natural.width * ratio,
                      height: natural.height * ratio)
    }
}

#if !os(macOS)
/// Measures the image's laid-out (aspect-fitted) rect, which is what the
/// pan clamp needs — `Image` carries no accessible intrinsic size, so the
/// only way to learn the fitted rect is to ask the layout system for it.
private struct ContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// iOS subview that hosts the gesture state. Lifting it out of
/// `AttachmentFullscreenViewer` keeps the parent stateless so the
/// `#if` switch above stays a one-line `body` without leaking
/// gesture-state ownership across platforms.
///
/// Gestures, and why each is shaped the way it is:
///
/// * **Pinch** zooms about the pinch's own start point via
///   `ZoomPanGeometry.zoom`. The previous version fed `scaleEffect` a
///   bare scale, whose default anchor is the view's centre — so the image
///   could only ever grow out of its middle, and with no pan gesture at
///   all there was no way to reach anything else (2026-08-08, Dan: "only
///   able to do it with the centre of the zoom fixed in the middle of the
///   image eg was not able to pan"). It also read `value.magnitude`
///   directly, which restarts at 1.0 each gesture, so successive pinches
///   couldn't accumulate.
/// * **Drag** pans while zoomed and dismisses while at fit scale. One
///   gesture serving both is what makes "swipe down to close" survive:
///   at fit scale there is nothing to pan to, and once zoomed a downward
///   drag is unambiguously a request to see the bottom of the image.
/// * **Double-tap** toggles between fit and `doubleTapScale`, anchored on
///   the tap, as the fast path for "let me read that bit".
private struct FullscreenImageBody: View {
    let image: Image
    let onDismiss: () -> Void

    /// Live values, updated continuously during a gesture.
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Values as of the last gesture end. Gestures report cumulative
    /// deltas from their own start, so they must compose against these,
    /// not against the live values they are themselves driving.
    @State private var committedScale: CGFloat = 1
    @State private var committedOffset: CGSize = .zero
    /// Downward travel of an in-progress dismiss swipe, kept apart from
    /// `offset` so it never pollutes the pan state.
    @State private var dismissTranslation: CGFloat = 0
    @State private var contentSize: CGSize = .zero

    /// Threshold for the swipe-down dismiss. 100pt is the same value
    /// SwiftUI's interactive sheet dismiss uses internally and reads
    /// as "intentional swipe" without tripping on a normal scroll
    /// inertia bounce.
    private static let dismissThreshold: CGFloat = 100

    private var isZoomed: Bool { committedScale > ZoomPanGeometry.minScale }

    var body: some View {
        GeometryReader { proxy in
            let geometry = ZoomPanGeometry(
                containerSize: proxy.size,
                contentSize: contentSize
            )

            ZStack {
                Color.black.ignoresSafeArea()

                image
                    .resizable()
                    .scaledToFit()
                    // Measured before the transforms: `scaleEffect` and
                    // `offset` are render-time only and don't change the
                    // laid-out rect, but reading the size here keeps that
                    // independence explicit.
                    .background(
                        GeometryReader { imageProxy in
                            Color.clear.preference(
                                key: ContentSizeKey.self,
                                value: imageProxy.size
                            )
                        }
                    )
                    .scaleEffect(scale)
                    .offset(x: offset.width, y: offset.height + dismissTranslation)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Without this the gestures only respond over the image's own
            // pixels, so a pinch starting on the black letterbox is lost.
            .contentShape(Rectangle())
            .gesture(magnification(geometry))
            .simultaneousGesture(drag(geometry))
            .simultaneousGesture(doubleTap(geometry))
            .onPreferenceChange(ContentSizeKey.self) { contentSize = $0 }
        }
        .background(Color.black.ignoresSafeArea())
        // Fades the sheet out under an in-progress dismiss swipe, so the
        // gesture reads as "dragging the photo away" rather than as the
        // image sliding off a black wall.
        .opacity(1 - min(dismissTranslation / (Self.dismissThreshold * 3), 0.6))
        // While zoomed, a downward pan must not be stolen by the sheet's
        // own interactive dismiss — the user is trying to see the bottom
        // of the image, not close it.
        .interactiveDismissDisabled(isZoomed)
        .overlay(alignment: .topTrailing) {
            // Top-trailing close button — provides a no-gesture path
            // out for VoiceOver users / anyone unfamiliar with the
            // swipe-down convention.
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white, .black.opacity(0.4))
                    .padding()
            }
            .accessibilityLabel("Close image preview")
        }
    }

    private func magnification(_ geometry: ZoomPanGeometry) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let result = geometry.zoom(
                    to: committedScale * value.magnification,
                    around: value.startLocation,
                    from: committedOffset,
                    at: committedScale
                )
                scale = result.scale
                offset = result.offset
            }
            .onEnded { _ in
                commit(geometry)
            }
    }

    private func drag(_ geometry: ZoomPanGeometry) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if isZoomed {
                    offset = geometry.clamped(
                        offset: CGSize(
                            width: committedOffset.width + value.translation.width,
                            height: committedOffset.height + value.translation.height
                        ),
                        at: scale
                    )
                } else if value.translation.height > 0 {
                    dismissTranslation = value.translation.height
                }
            }
            .onEnded { value in
                if isZoomed {
                    committedOffset = offset
                } else if value.translation.height > Self.dismissThreshold {
                    onDismiss()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dismissTranslation = 0
                    }
                }
            }
    }

    private func doubleTap(_ geometry: ZoomPanGeometry) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                let target = isZoomed
                    ? ZoomPanGeometry.minScale
                    : ZoomPanGeometry.doubleTapScale
                let result = geometry.zoom(
                    to: target,
                    around: value.location,
                    from: committedOffset,
                    at: committedScale
                )
                withAnimation(.easeOut(duration: 0.25)) {
                    scale = result.scale
                    offset = result.offset
                }
                committedScale = result.scale
                committedOffset = result.offset
            }
    }

    /// Settles the live values after a pinch. Releasing at or below fit
    /// scale springs back to a centred, unzoomed image rather than
    /// leaving it parked slightly off-centre.
    private func commit(_ geometry: ZoomPanGeometry) {
        if scale <= ZoomPanGeometry.minScale {
            withAnimation(.easeOut(duration: 0.2)) {
                scale = ZoomPanGeometry.minScale
                offset = .zero
            }
            committedScale = ZoomPanGeometry.minScale
            committedOffset = .zero
        } else {
            committedScale = scale
            let settled = geometry.clamped(offset: offset, at: scale)
            if settled != offset {
                withAnimation(.easeOut(duration: 0.2)) { offset = settled }
            }
            committedOffset = settled
        }
    }
}
#endif
