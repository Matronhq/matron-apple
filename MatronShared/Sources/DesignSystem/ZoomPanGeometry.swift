import CoreGraphics

/// Pure geometry for the fullscreen image viewer's pinch-zoom and pan.
///
/// Split out of the View so the two rules that actually decide how the
/// gesture feels — "the point under your fingers stays under your fingers"
/// and "you can never drag the image off its own edges" — are ordinary
/// functions with unit tests, rather than arithmetic buried in a gesture
/// closure that can only be checked by hand on a device.
///
/// Coordinate model: the content is laid out centred in the container at
/// `contentSize`, then rendered as `scaleEffect(scale)` about its centre
/// followed by `offset(offset)`. So a content-local point `p` (measured
/// from the content's centre, at scale 1) lands at container-centre
/// `p * scale + offset`. Every function below is that one equation.
struct ZoomPanGeometry: Equatable {
    /// The viewer's bounds.
    var containerSize: CGSize
    /// The image's laid-out rect at scale 1 — i.e. the aspect-fitted size,
    /// not the image's pixel dimensions. Measured from the view.
    var contentSize: CGSize

    static let minScale: CGFloat = 1
    /// 6x is enough to read small text in an agent's screenshot without
    /// zooming so far past the source resolution that it's only mush.
    static let maxScale: CGFloat = 6
    /// Where a double-tap lands when zooming in.
    static let doubleTapScale: CGFloat = 2.5

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minScale), maxScale)
    }

    /// Multiplier for one keyboard zoom step (Mac ⌘+/⌘−). 1.5 needs
    /// four presses to cross the whole 1…6 range — granular enough to
    /// aim, fast enough not to feel like cranking a winch.
    static let keyboardStep: CGFloat = 1.5

    /// One keyboard step in, clamped. Inverse of `steppedOut(from:)`
    /// within the clamp range so repeated +/− can't drift.
    static func steppedIn(from scale: CGFloat) -> CGFloat {
        clampedScale(scale * keyboardStep)
    }

    /// One keyboard step out, clamped.
    static func steppedOut(from scale: CGFloat) -> CGFloat {
        clampedScale(scale / keyboardStep)
    }

    /// Half the amount the scaled content overflows the container on each
    /// axis — i.e. how far the content may be dragged before its edge
    /// would pull inside the container. Zero on an axis the content
    /// doesn't overflow, which is what pins a fit-width image vertically
    /// instead of letting it drift in the letterbox.
    func panLimit(at scale: CGFloat) -> CGSize {
        CGSize(
            width: max(0, (contentSize.width * scale - containerSize.width) / 2),
            height: max(0, (contentSize.height * scale - containerSize.height) / 2)
        )
    }

    func clamped(offset: CGSize, at scale: CGFloat) -> CGSize {
        let limit = panLimit(at: scale)
        return CGSize(
            width: min(max(offset.width, -limit.width), limit.width),
            height: min(max(offset.height, -limit.height), limit.height)
        )
    }

    /// The offset that holds `containerPoint` visually still while the
    /// scale changes from `oldScale` to `newScale`.
    ///
    /// Solving `p * oldScale + oldOffset == p * newScale + newOffset` for
    /// the new offset gives `oldOffset + p * (oldScale - newScale)`, where
    /// `p` is the content-local point currently under `containerPoint`.
    /// This is the whole difference between pinching a photo and watching
    /// it inflate from its middle: without it, `scaleEffect`'s default
    /// centre anchor means the only thing you can ever zoom into is the
    /// centre of the image.
    ///
    /// `containerPoint` is in the container's own coordinate space
    /// (origin top-left), which is what `MagnifyGesture`/`SpatialTapGesture`
    /// report when attached to the container.
    func offsetKeepingFocus(
        containerPoint: CGPoint,
        oldOffset: CGSize,
        oldScale: CGFloat,
        newScale: CGFloat
    ) -> CGSize {
        // Guard rather than trust: a zero scale would divide by zero, and
        // scale is clamped to >= 1 everywhere it is set.
        guard oldScale > 0 else { return oldOffset }
        let fromCentre = CGPoint(
            x: containerPoint.x - containerSize.width / 2,
            y: containerPoint.y - containerSize.height / 2
        )
        let contentLocal = CGPoint(
            x: (fromCentre.x - oldOffset.width) / oldScale,
            y: (fromCentre.y - oldOffset.height) / oldScale
        )
        return CGSize(
            width: oldOffset.width + contentLocal.x * (oldScale - newScale),
            height: oldOffset.height + contentLocal.y * (oldScale - newScale)
        )
    }

    /// Focus-preserving zoom with the result already clamped into range —
    /// the single call every gesture handler makes.
    func zoom(
        to requestedScale: CGFloat,
        around containerPoint: CGPoint,
        from offset: CGSize,
        at scale: CGFloat
    ) -> (scale: CGFloat, offset: CGSize) {
        let newScale = Self.clampedScale(requestedScale)
        let focused = offsetKeepingFocus(
            containerPoint: containerPoint,
            oldOffset: offset,
            oldScale: scale,
            newScale: newScale
        )
        return (newScale, clamped(offset: focused, at: newScale))
    }
}
