import SwiftUI

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
    private let onDismiss: () -> Void

    public init(image: Image, onDismiss: @escaping () -> Void) {
        self.image = image
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
    @ViewBuilder
    private var macBody: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .padding()
            }
            image
                .resizable()
                .scaledToFit()
                .padding()
            Spacer(minLength: 0)
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Color.black.opacity(0.85))
        .accessibilityLabel("Image preview")
    }
    #endif
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
