import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Fullscreen image viewer presented from a chat attachment tap or a
/// media-grid cell. Steps through an `ImageGallery` — Mac ←/→ keys and
/// edge chevrons, iOS horizontal swipe — with a "3 of 12" counter; the
/// ends are hard stops. iOS supports pinch-zoom + swipe-down-to-dismiss;
/// Mac opens a sheet that fills most of the presenting window,
/// aspect-fits the image into it, and adds Preview.app-style
/// interactions (trackpad pinch, drag-pan while zoomed, double-click,
/// ⌘+/⌘−/⌘0) plus a "Done" button — see `MacZoomableImage`.
///
/// Images resolve through the gallery's `load` closure, so the viewer
/// stays free of `MediaService`. The tapped image arrives pre-resolved
/// (`ImageGallery.initial`) and shows instantly; the two neighbours are
/// fetched ahead so a step is usually instant too.
public struct AttachmentFullscreenViewer: View {
    private let gallery: ImageGallery
    private let onDismiss: () -> Void

    @State private var index: Int
    /// Resolved images keyed by entry id. Seeded with the tapped image.
    @State private var loaded: [String: ViewerImage]
    /// Entries whose fetch returned nothing — shown as unavailable.
    /// Neighbour preloads leave them alone, but stepping onto one tries
    /// again: the loader can't tell a reaped blob from a flaky network,
    /// so a miss must not be permanent (Bugbot, PR #175).
    @State private var failed: Set<String> = []
    /// One shared fetch per entry. Unstructured on purpose: it outlives
    /// the `.task(id:)` that started it, so a step can never implicitly
    /// cancel it into a nil that reads as a miss, and a re-visit joins the
    /// running fetch instead of finding a "loading" slot nobody is
    /// filling (Bugbot, PR #175). Fetches for entries the user has moved
    /// away from are cancelled EXPLICITLY on the next step, so they free
    /// their `maxConcurrentLoads` slot instead of holding up the visible
    /// image; the owner recognises its own cancellation and drops the
    /// result without recording a miss.
    @State private var inFlight: [String: Task<ViewerImage?, Never>] = [:]
    /// Sign of the last step (+1 next, −1 previous) — drives which edge
    /// the iOS slide transition enters from.
    @State private var lastStep: Int = 1

    public init(gallery: ImageGallery, onDismiss: @escaping () -> Void) {
        self.gallery = gallery
        self.onDismiss = onDismiss
        _index = State(initialValue: gallery.startIndex)
        var seeded: [String: ViewerImage] = [:]
        if let initial = gallery.initial {
            seeded[gallery.entries[gallery.startIndex].id] = initial
        }
        _loaded = State(initialValue: seeded)
    }

    /// Single-image convenience — a one-entry gallery, no stepping.
    public init(
        image: Image,
        nativePixelSize: CGSize? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.init(gallery: .single(image, pixelSize: nativePixelSize), onDismiss: onDismiss)
    }

    public var body: some View {
        Group {
            #if os(macOS)
            macBody
            #else
            iosBody
            #endif
        }
        .task(id: index) { await loadAround(index) }
        // Closing the viewer abandons every outstanding fetch — nothing
        // will display them, and they'd otherwise run to completion.
        .onDisappear { for fetch in inFlight.values { fetch.cancel() } }
    }

    // MARK: - Gallery state

    private var entries: [ImageGallery.Entry] { gallery.entries }
    private var current: ImageGallery.Entry { entries[index] }
    private var canPage: Bool { entries.count > 1 }
    private var counter: String? {
        ImageGalleryNavigation.counterLabel(index: index, count: entries.count)
    }
    private var canGoPrevious: Bool {
        ImageGalleryNavigation.step(index, by: -1, count: entries.count) != nil
    }
    private var canGoNext: Bool {
        ImageGalleryNavigation.step(index, by: 1, count: entries.count) != nil
    }

    /// What the current entry renders as right now.
    private var slot: ViewerSlot {
        if let image = loaded[current.id] { return .image(image) }
        if current.expired || current.url == nil || failed.contains(current.id) {
            return .unavailable
        }
        return .loading
    }

    private func step(_ delta: Int) {
        guard let next = ImageGalleryNavigation.step(index, by: delta, count: entries.count)
        else { return }
        lastStep = delta
        withAnimation(.easeInOut(duration: 0.22)) { index = next }
    }

    /// Entries either side of the current one whose bitmaps stay cached.
    static let retainedRadius = 4
    /// Fetches this viewer may have in flight at once.
    static let maxConcurrentLoads = 3

    /// Trim the bitmap cache to a window around `index`, then fetch the
    /// current entry and its neighbours in turn. Runs inside `.task(id:)`,
    /// so a step stops it from STARTING further fetches (the ones already
    /// running finish and land in `loaded`); together with the
    /// concurrency cap this bounds what a held arrow key can queue
    /// (CodeRabbit, PR #175).
    private func loadAround(_ index: Int) async {
        let keep = ImageGalleryNavigation.retainedIndices(
            around: index, count: entries.count, radius: Self.retainedRadius
        )
        let keepIDs = Set(keep.map { entries[$0].id })
        loaded = loaded.filter { keepIDs.contains($0.key) }
        // Fetches for anything but the current entry and its neighbours
        // are stale — cancel them so the visible image never queues
        // behind preloads for a position we've left (Bugbot, PR #175).
        let wanted = [index] + ImageGalleryNavigation.preloadIndices(around: index, count: entries.count)
        let wantedIDs = Set(wanted.map { entries[$0].id })
        for (id, fetch) in inFlight where !wantedIDs.contains(id) { fetch.cancel() }
        for i in wanted {
            guard !Task.isCancelled else { return }
            await ensureLoaded(i, retryingFailed: i == index, isCurrent: i == index)
        }
    }

    /// - Parameters:
    ///   - retryingFailed: re-fetch an entry previously recorded as a miss.
    ///   - isCurrent: the visible entry — never waits for a concurrency
    ///     slot, so preloads can't delay what the user is looking at.
    @MainActor
    private func ensureLoaded(_ i: Int, retryingFailed: Bool, isCurrent: Bool) async {
        guard entries.indices.contains(i) else { return }
        let entry = entries[i]
        guard let url = entry.url, !entry.expired, loaded[entry.id] == nil else { return }
        if failed.contains(entry.id) {
            guard retryingFailed else { return }
            failed.remove(entry.id)
        }
        if let running = inFlight[entry.id] {
            // A live fetch's owner will apply its result — nothing to do.
            // A fetch we cancelled on the way out (and now want again)
            // must drain first, then we start a fresh one below.
            guard running.isCancelled else { return }
            _ = await running.value
        }
        if !isCurrent {
            // Wait for a slot rather than piling requests up.
            while inFlight.count >= Self.maxConcurrentLoads {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        guard loaded[entry.id] == nil, inFlight[entry.id]?.isCancelled != false,
              !Task.isCancelled else { return }
        let load = gallery.load
        let fetch = Task { @MainActor in await load(url) }
        inFlight[entry.id] = fetch
        // `Task.value` is not interrupted by our own cancellation, so the
        // bookkeeping below runs even if the step that started this fetch
        // has since been superseded.
        let result = await fetch.value
        // Only clear our own registration — a re-visit may already have
        // replaced a cancelled fetch with a fresh one.
        if inFlight[entry.id] == fetch { inFlight[entry.id] = nil }
        if let result {
            loaded[entry.id] = result
        } else if !fetch.isCancelled {
            failed.insert(entry.id)
        }
    }

    // MARK: - iOS

    #if !os(macOS)
    /// iOS body. Pinch-to-zoom anchored on the pinch itself, one-finger
    /// pan once zoomed, double-tap to toggle, swipe-down to dismiss and
    /// swipe-sideways to step while at fit scale. See `FullscreenImageBody`.
    @ViewBuilder
    private var iosBody: some View {
        FullscreenImageBody(
            slot: slot,
            entryID: current.id,
            counter: counter,
            canPage: canPage,
            canGoPrevious: canGoPrevious,
            canGoNext: canGoNext,
            stepDirection: lastStep,
            onStep: { step($0) },
            onDismiss: onDismiss
        )
        // Hardware-keyboard arrows (iPad) — same hidden-button routing
        // the Mac zoom shortcuts use.
        .background(keyboardStepButtons)
    }
    #endif

    /// Hidden buttons carrying ←/→ — SwiftUI routes `keyboardShortcut`
    /// through the responder chain even at zero opacity. Only mounted
    /// when there is somewhere to step, so a lone image leaves the arrow
    /// keys alone.
    @ViewBuilder
    private var keyboardStepButtons: some View {
        if canPage {
            Group {
                Button("Previous image") { step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!canGoPrevious)
                Button("Next image") { step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!canGoNext)
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

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
                switch slot {
                case .image(let viewerImage):
                    if let pixelSize = viewerImage.pixelSize,
                       let fitted = Self.imageDisplaySize(pixelSize: pixelSize, bound: imageArea) {
                        MacZoomableImage(
                            image: viewerImage.image,
                            containerSize: imageArea,
                            contentSize: fitted
                        )
                        // Fresh zoom/pan state per image — stepping to the
                        // next photo must not inherit the last one's zoom.
                        .id(current.id)
                    } else {
                        // No pixel size: plain aspect-fit, no zoom — the
                        // zoom geometry needs the fitted rect, which only
                        // the pixel aspect ratio can give us up front.
                        viewerImage.image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    }
                case .loading:
                    ProgressView().controlSize(.large)
                case .unavailable:
                    UnavailableImagePlaceholder()
                }
            }
            .frame(width: imageArea.width, height: imageArea.height)
            .padding(Self.imagePadding)
        }
        .frame(width: viewerSize.width, height: viewerSize.height)
        .background(Color.black.opacity(0.85))
        .accessibilityLabel("Image preview")
    }

    /// Chrome row: step chevrons leading (they carry the ←/→ shortcuts,
    /// so disabling them at an end disables the key too), counter
    /// centred, Done trailing.
    @ViewBuilder
    private var doneRow: some View {
        HStack(spacing: 4) {
            if canPage {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!canGoPrevious)
                    .help("Previous image")
                    .accessibilityLabel("Previous image")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!canGoNext)
                    .help("Next image")
                    .accessibilityLabel("Next image")
            }
            Spacer()
            Button("Done") { onDismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal)
        .overlay {
            if let counter {
                Text(counter)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Image \(counter)")
            }
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

/// Render state of the entry the viewer is showing.
fileprivate enum ViewerSlot {
    case image(ViewerImage)
    case loading
    case unavailable
}

/// Stand-in for an entry with nothing to show: a reaped (expired)
/// attachment or a fetch that came back empty. Shown in place rather
/// than skipped so the counter stays in step with the grid.
private struct UnavailableImagePlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.largeTitle)
            Text("Image unavailable")
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
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
/// `AttachmentFullscreenViewer` keeps the parent's `#if` switch a
/// one-line `body` without leaking gesture-state ownership across
/// platforms; the parent owns which entry is showing, this view owns how
/// it is zoomed.
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
/// * **Drag** pans while zoomed; at fit scale its dominant axis decides:
///   downward dismisses (the original swipe-down), sideways steps to the
///   previous/next image (2026-09-03). One gesture serving all three is
///   what keeps them from fighting — at fit scale there is nothing to
///   pan to, and once zoomed a drag is unambiguously a request to see
///   another part of THIS image.
/// * **Double-tap** toggles between fit and `doubleTapScale`, anchored on
///   the tap, as the fast path for "let me read that bit".
private struct FullscreenImageBody: View {
    let slot: ViewerSlot
    /// Identity of the showing entry — changes reset the zoom and drive
    /// the slide transition.
    let entryID: String
    let counter: String?
    let canPage: Bool
    let canGoPrevious: Bool
    let canGoNext: Bool
    /// +1 when the last step was to the next image, −1 for previous.
    let stepDirection: Int
    let onStep: (Int) -> Void
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
    /// Sideways travel of an in-progress page swipe — the image follows
    /// the finger so the gesture reads as dragging to the neighbour.
    @State private var pageTranslation: CGFloat = 0
    @State private var contentSize: CGSize = .zero
    /// A pinch in progress. The simultaneous drag sees the two-finger
    /// centroid as a drag, and `isZoomed` only flips when the pinch
    /// commits — so without this a pinch-out whose centroid drifted
    /// sideways would page to the neighbour, and a pinch back to fit
    /// that committed first would let the same drag's end page or dismiss
    /// (Bugbot, PR #175, twice). Any drag that overlapped a pinch at any
    /// point — zoomed or not — is discarded when it ends.
    @State private var pinchActive = false
    @State private var dragTaintedByPinch = false

    /// Threshold for the swipe-down dismiss and the sideways step. 100pt
    /// is the same value SwiftUI's interactive sheet dismiss uses
    /// internally and reads as "intentional swipe" without tripping on a
    /// normal scroll inertia bounce.
    private static let swipeThreshold: CGFloat = 100

    private var isZoomed: Bool { committedScale > ZoomPanGeometry.minScale }

    var body: some View {
        GeometryReader { proxy in
            let geometry = ZoomPanGeometry(
                containerSize: proxy.size,
                contentSize: contentSize
            )

            ZStack {
                Color.black.ignoresSafeArea()

                slotView
                    // New identity per entry so a step slides the old
                    // image out and the new one in from the far edge.
                    .id(entryID)
                    .transition(.asymmetric(
                        insertion: .move(edge: stepDirection >= 0 ? .trailing : .leading),
                        removal: .move(edge: stepDirection >= 0 ? .leading : .trailing)
                    ))
                    .scaleEffect(scale)
                    .offset(x: offset.width + pageTranslation,
                            y: offset.height + dismissTranslation)
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
        .opacity(1 - min(dismissTranslation / (Self.swipeThreshold * 3), 0.6))
        // While zoomed, a downward pan must not be stolen by the sheet's
        // own interactive dismiss — the user is trying to see the bottom
        // of the image, not close it.
        .interactiveDismissDisabled(isZoomed)
        .onChange(of: entryID) { _, _ in resetZoom() }
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
        .overlay(alignment: .top) {
            if let counter {
                Text(counter)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(.top, 14)
                    .accessibilityLabel("Image \(counter)")
            }
        }
    }

    @ViewBuilder
    private var slotView: some View {
        switch slot {
        case .image(let viewerImage):
            viewerImage.image
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
        case .loading:
            ProgressView().tint(.white).controlSize(.large)
        case .unavailable:
            UnavailableImagePlaceholder()
        }
    }

    private func resetZoom() {
        scale = ZoomPanGeometry.minScale
        offset = .zero
        committedScale = ZoomPanGeometry.minScale
        committedOffset = .zero
        contentSize = .zero
    }

    private func magnification(_ geometry: ZoomPanGeometry) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                pinchActive = true
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
                pinchActive = false
                commit(geometry)
            }
    }

    private func drag(_ geometry: ZoomPanGeometry) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if pinchActive { dragTaintedByPinch = true }
                if isZoomed {
                    offset = geometry.clamped(
                        offset: CGSize(
                            width: committedOffset.width + value.translation.width,
                            height: committedOffset.height + value.translation.height
                        ),
                        at: scale
                    )
                    return
                }
                if dragTaintedByPinch {
                    pageTranslation = 0
                    dismissTranslation = 0
                    return
                }
                let translation = value.translation
                if abs(translation.width) > abs(translation.height) {
                    // Sideways: follow the finger only when there is a
                    // neighbour in that direction, so the ends feel solid.
                    let towardNext = translation.width < 0
                    let canFollow = canPage && (towardNext ? canGoNext : canGoPrevious)
                    pageTranslation = canFollow ? translation.width : 0
                    dismissTranslation = 0
                } else if translation.height > 0 {
                    dismissTranslation = translation.height
                    pageTranslation = 0
                }
            }
            .onEnded { value in
                let tainted = dragTaintedByPinch
                dragTaintedByPinch = false
                if isZoomed {
                    committedOffset = offset
                    return
                }
                if tainted {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dismissTranslation = 0
                        pageTranslation = 0
                    }
                    return
                }
                let intent = ImageGalleryNavigation.swipeIntent(
                    translation: value.translation, threshold: Self.swipeThreshold
                )
                switch intent {
                case .dismiss:
                    onDismiss()
                case .next where canPage && canGoNext:
                    withAnimation(.easeInOut(duration: 0.22)) { pageTranslation = 0 }
                    onStep(1)
                case .previous where canPage && canGoPrevious:
                    withAnimation(.easeInOut(duration: 0.22)) { pageTranslation = 0 }
                    onStep(-1)
                default:
                    withAnimation(.easeOut(duration: 0.2)) {
                        dismissTranslation = 0
                        pageTranslation = 0
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
