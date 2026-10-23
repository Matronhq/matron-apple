import CoreGraphics

/// Pure rules behind previous/next stepping in the fullscreen image
/// viewer — Mac ←/→ keys and edge chevrons, iOS horizontal swipe. Kept
/// as plain functions so the ends-are-hard-stops, neighbour-preload and
/// swipe-vs-dismiss decisions are unit-tested rather than buried in
/// gesture closures.
enum ImageGalleryNavigation {
    /// What a finished iOS drag at fit scale means.
    enum SwipeIntent: Equatable {
        case previous, next, dismiss, none
    }

    /// Index reached by moving `delta` from `index`, or `nil` when that
    /// would leave the gallery. No wrap-around.
    static func step(_ index: Int, by delta: Int, count: Int) -> Int? {
        let target = index + delta
        guard delta != 0, target >= 0, target < count else { return nil }
        return target
    }

    /// The in-range immediate neighbours of `index`, oldest first — the
    /// entries worth fetching ahead so a step is instant.
    static func preloadIndices(around index: Int, count: Int) -> [Int] {
        [index - 1, index + 1].filter { $0 >= 0 && $0 < count }
    }

    /// The indices within `radius` of `index`, clamped to the gallery —
    /// the entries whose resolved bitmaps are worth keeping in memory.
    /// Everything else is evicted on a step, so holding an arrow key
    /// through a big gallery can't pin every image at once.
    static func retainedIndices(around index: Int, count: Int, radius: Int) -> Set<Int> {
        guard count > 0 else { return [] }
        let lower = max(0, index - radius)
        let upper = min(count - 1, index + radius)
        guard lower <= upper else { return [] }
        return Set(lower...upper)
    }

    /// Shortest sideways travel that can count as a flick. Below this a
    /// release is a tap or a wobble, however fast it was moving.
    static let minimumFlickDistance: CGFloat = 30

    /// Classifies a completed drag by its dominant axis: horizontal past
    /// `threshold` pages, downward past `threshold` dismisses (the
    /// pre-existing swipe-down), anything else is a no-op. The dominant
    /// axis decides, so a diagonal flick doesn't both page and dismiss.
    ///
    /// A sideways flick also pages when it travelled at least
    /// `minimumFlickDistance` and its momentum would have carried it past
    /// `threshold` in the same direction (`predictedEndTranslation`, the
    /// drag's own projection of where it was heading). A thumb flick
    /// often lifts after 50–90pt, so a distance rule alone left it
    /// springing back. Dismiss keeps the distance rule: closing the
    /// viewer by accident costs more than a missed page.
    static func swipeIntent(
        translation: CGSize,
        predictedEndTranslation: CGSize? = nil,
        threshold: CGFloat
    ) -> SwipeIntent {
        let dx = translation.width, dy = translation.height
        if abs(dx) > abs(dy) {
            let flicked = predictedEndTranslation.map { predicted in
                abs(dx) >= minimumFlickDistance
                    && abs(predicted.width) >= threshold
                    && (predicted.width < 0) == (dx < 0)
            } ?? false
            guard abs(dx) >= threshold || flicked else { return .none }
            return dx < 0 ? .next : .previous
        }
        return dy >= threshold ? .dismiss : .none
    }

    /// "3 of 12" for the viewer chrome; `nil` when there is nothing to
    /// step between, so a lone image shows no counter.
    static func counterLabel(index: Int, count: Int) -> String? {
        guard count > 1 else { return nil }
        return "\(index + 1) of \(count)"
    }
}
