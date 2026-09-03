import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Fullscreen image viewer presented from a chat attachment tap. iOS
/// supports pinch-zoom + swipe-down-to-dismiss; Mac opens a sheet that
/// fills most of the presenting window, aspect-fits the image into it,
/// and adds Preview.app-style interactions (trackpad pinch, drag-pan
/// while zoomed, double-click, ⌘+/⌘−/⌘0) plus a "Done" button — see
/// `MacZoomableImage`.
///
/// The `Image` is taken pre-resolved (via `ChatViewModel.image(for:)`)
/// so the viewer stays a leaf View — avoids dragging `MediaService`
/// into `MatronDesignSystem` for one sheet.
public struct AttachmentFullscreenViewer: View {
    private let image: Image
    /// Native bitmap size in pixels, when the call site knows it. Mac
    /// uses its aspect ratio to lay the image out at an exact fitted
    /// size, which is what the zoom/pan geometry needs to know where the
    /// image's edges are. `nil` (iOS call sites, or an image whose size
    /// never resolved) falls back to a plain aspect-fit without zoom.
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
    @ViewBuilder
    private var macBody: some View {
        // Mac sheet sizing, probed empirically (2026-08-12): a sheet only
        // adopts its content's size when the content is fully RIGID. Any
        // flexibility (a `minWidth`/`minHeight` range, a bare `resizable`
        // image) collapses the sheet to a small system default that gets
        // proposed to the content. So the whole body takes an explicit
        // width × height — most of the presenting window (2026-09-03,
        // Dan: "it should take up most of the area of the app"; the
        // previous rule sized the sheet to the bitmap, so anything
        // smaller than the screen opened in a small box). macOS does NOT
        // clamp sheets to the parent window, so the size is also
        // screen-bounded here.
        let viewerSize = Self.viewerSize(
            windowContentSize: Self.presentingWindowContentSize(),
            screenVisibleSize: Self.screenVisibleSize()
        )
        let imageArea = CGSize(
            width: viewerSize.width - Self.imagePadding * 2,
            height: viewerSize.height - Self.imagePadding * 2 - Self.doneRowHeight
        )
        VStack(spacing: 0) {
            doneRow.frame(height: Self.doneRowHeight)
            Group {
                if let fitted = nativePixelSize.flatMap({
                    Self.imageDisplaySize(pixelSize: $0, bound: imageArea)
                }) {
                    MacZoomableImage(
                        image: image,
                        containerSize: imageArea,
                        contentSize: fitted
                    )
                } else {
                    // No pixel size (never on Mac today, but the parameter
                    // is optional): plain aspect-fit, no zoom — the zoom
                    // geometry needs the fitted rect, which only the
                    // pixel aspect ratio can give us up front.
                    image
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                }
            }
            .frame(width: imageArea.width, height: imageArea.height)
            .padding(Self.imagePadding)
        }
        .frame(width: viewerSize.width, height: viewerSize.height)
        .background(Color.black.opacity(0.85))
        .accessibilityLabel("Image preview")
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

    /// Content area of the window the sheet hangs from. Sheets stack
    /// (the media browser is itself a sheet, and it presents this
    /// viewer), so walk `sheetParent` to the root document window — the
    /// user means "the app", not the 640pt browser sheet. Evaluated while
    /// the sheet is being presented, when the key window is still the
    /// presenter (or, on a re-evaluation, our own sheet — either way the
    /// walk ends at the same root). Same source the New Chat sheet sizes
    /// from (`MacChatListView`, `NSApp.keyWindow?.contentLayoutRect`).
    /// With no key or main window (app not active — seen only in a
    /// launchd-spawned repro, never from a click) a lone visible root
    /// window is trusted; anything more ambiguous returns `nil`, which
    /// sizes against the screen instead.
    private static func presentingWindowContentSize() -> CGSize? {
        var window = NSApp.keyWindow ?? NSApp.mainWindow
        while let parent = window?.sheetParent { window = parent }
        if window == nil {
            let roots = NSApp.windows.filter { $0.isVisible && !$0.isSheet }
            if roots.count == 1 { window = roots[0] }
        }
        guard let window else { return nil }
        // `contentLayoutRect` excludes the title bar / toolbar that the
        // sheet attaches beneath, so the fraction is of the area the
        // sheet can actually cover without hanging past the bottom edge.
        return window.contentLayoutRect.size
    }

    /// Visible frame of the main screen, or a conservative laptop-ish
    /// size when no screen is available (headless tests).
    private static func screenVisibleSize() -> CGSize {
        NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
    }

    /// Fixed height for the Done-button row. Fixed (not intrinsic) so the
    /// sheet's total height can be computed exactly — the rigid frame is
    /// what makes the sheet adopt the content size at all.
    private static let doneRowHeight: CGFloat = 52
    /// Padding around the image inside the sheet.
    private static let imagePadding: CGFloat = 16
    #endif

    // MARK: - Sizing rules (platform-independent, unit-tested)

    /// Share of the presenting window's content area the sheet covers.
    /// "Most of the app" while still reading as a sheet over it rather
    /// than a replacement for it.
    static let windowFillFraction: CGFloat = 0.9
    /// Share of the screen used when there is no presenting window to
    /// measure.
    static let screenFillFraction: CGFloat = 0.85
    /// Gap kept between the sheet and the screen's visible-frame edges.
    static let screenMargin: CGFloat = 24
    /// Smallest sheet: room for the Done row plus a usable image area,
    /// even from a tiny window.
    static let minimumViewerSize = CGSize(width: 480, height: 360)

    /// Sheet size for a presenting window of `windowContentSize` (nil when
    /// unknown) on a screen whose visible frame is `screenVisibleSize`:
    /// `windowFillFraction` of the window, raised to `minimumViewerSize`,
    /// then capped to the screen (less `screenMargin`) — the cap is
    /// applied last because a sheet that overhangs the screen is unusable
    /// no matter how small the floor says it may not go.
    static func viewerSize(
        windowContentSize: CGSize?,
        screenVisibleSize: CGSize
    ) -> CGSize {
        let screenCap = CGSize(
            width: screenVisibleSize.width - screenMargin * 2,
            height: screenVisibleSize.height - screenMargin * 2
        )
        let target = windowContentSize.map {
            CGSize(width: $0.width * windowFillFraction,
                   height: $0.height * windowFillFraction)
        } ?? CGSize(
            width: screenVisibleSize.width * screenFillFraction,
            height: screenVisibleSize.height * screenFillFraction
        )
        return CGSize(
            width: min(screenCap.width, max(minimumViewerSize.width, target.width)),
            height: min(screenCap.height, max(minimumViewerSize.height, target.height))
        )
    }

    /// Aspect-fit of a bitmap with `pixelSize` into `bound` (points) —
    /// scaled up as well as down, so a small screenshot fills the viewer
    /// instead of sitting 1:1 in the middle of it. Returns `nil` for
    /// degenerate inputs (zero-area image or bound), which callers treat
    /// as "fall back to a plain resizable image".
    static func imageDisplaySize(pixelSize: CGSize, bound: CGSize) -> CGSize? {
        guard pixelSize.width > 0, pixelSize.height > 0,
              bound.width > 0, bound.height > 0 else { return nil }
        let ratio = min(bound.width / pixelSize.width,
                        bound.height / pixelSize.height)
        return CGSize(width: pixelSize.width * ratio,
                      height: pixelSize.height * ratio)
    }
}

#if os(macOS)
/// Mac twin of the iOS `FullscreenImageBody` gestures, minus the
/// swipe-to-dismiss (Done/Esc own dismissal on Mac): trackpad pinch zooms
/// about the pointer, drag pans while zoomed, double-click toggles fit ↔
/// `doubleTapScale`, and ⌘+/⌘−/⌘0 step centred for mouse-only and
/// keyboard users. All the zoom/pan math is the shared `ZoomPanGeometry`;
/// unlike iOS there is no measurement preference — the Mac sheet already
/// knows both rects up front: the image area it laid out
/// (`containerSize`) and the image aspect-fitted inside it
/// (`contentSize`).
///
/// Zoomed content stays inside the image area via `.clipped()` — the
/// sheet keeps its opening size; zooming changes what's visible within
/// it, matching Preview.app rather than growing the window.
private struct MacZoomableImage: View {
    let image: Image
    /// The image area the gestures respond over — the letterbox counts,
    /// so a pinch starting beside a tall image still lands.
    let containerSize: CGSize
    /// The image's aspect-fitted rect at scale 1, centred in the container.
    let contentSize: CGSize

    /// Live values, updated continuously during a gesture.
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Values as of the last gesture end — gestures report cumulative
    /// deltas from their own start, so they compose against these (see
    /// the iOS twin).
    @State private var committedScale: CGFloat = 1
    @State private var committedOffset: CGSize = .zero

    private var geometry: ZoomPanGeometry {
        ZoomPanGeometry(containerSize: containerSize, contentSize: contentSize)
    }

    private var isZoomed: Bool { committedScale > ZoomPanGeometry.minScale }

    var body: some View {
        image
            .resizable()
            // High interpolation both ways: big downscales (a 12MP photo
            // fit to ~1000pt) alias at the default, and small bitmaps
            // filling the viewer would otherwise show hard pixel edges.
            .interpolation(.high)
            .scaledToFit()
            .frame(width: contentSize.width, height: contentSize.height)
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: containerSize.width, height: containerSize.height)
            .clipped()
            // Whole rect responds, not just the bitmap's opaque pixels.
            .contentShape(Rectangle())
            .gesture(magnification)
            .simultaneousGesture(drag)
            .simultaneousGesture(doubleClick)
            .background(keyboardZoomButtons)
    }

    private var magnification: some Gesture {
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
            .onEnded { _ in commit() }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                // Only pans — at fit scale there's nothing to pan to, and
                // Mac has no swipe-to-dismiss.
                guard isZoomed else { return }
                offset = geometry.clamped(
                    offset: CGSize(
                        width: committedOffset.width + value.translation.width,
                        height: committedOffset.height + value.translation.height
                    ),
                    at: scale
                )
            }
            .onEnded { _ in
                if isZoomed { committedOffset = offset }
            }
    }

    private var doubleClick: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                let target = isZoomed
                    ? ZoomPanGeometry.minScale
                    : ZoomPanGeometry.doubleTapScale
                animate(to: geometry.zoom(
                    to: target, around: value.location,
                    from: committedOffset, at: committedScale
                ))
            }
    }

    /// Hidden buttons carrying the keyboard shortcuts — SwiftUI routes
    /// `keyboardShortcut` through the responder chain even at zero
    /// opacity. ⌘= doubles for ⌘+ (unshifted key on US layouts, the pair
    /// every Mac app binds together).
    private var keyboardZoomButtons: some View {
        Group {
            Button("Zoom In") { animate(to: centredZoom(ZoomPanGeometry.steppedIn(from: committedScale))) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom In") { animate(to: centredZoom(ZoomPanGeometry.steppedIn(from: committedScale))) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { animate(to: centredZoom(ZoomPanGeometry.steppedOut(from: committedScale))) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Zoom to Fit") { animate(to: centredZoom(ZoomPanGeometry.minScale)) }
                .keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func centredZoom(_ target: CGFloat) -> (scale: CGFloat, offset: CGSize) {
        geometry.zoom(
            to: target,
            around: CGPoint(x: containerSize.width / 2, y: containerSize.height / 2),
            from: committedOffset,
            at: committedScale
        )
    }

    private func animate(to result: (scale: CGFloat, offset: CGSize)) {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = result.scale
            offset = result.offset
        }
        committedScale = result.scale
        committedOffset = result.offset
    }

    /// Settles the live values after a pinch — releasing at or below fit
    /// scale springs back to a centred, unzoomed image (see the iOS twin).
    private func commit() {
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
