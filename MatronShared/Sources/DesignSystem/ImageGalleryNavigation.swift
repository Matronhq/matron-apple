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

    /// Classifies a completed drag by its dominant axis: horizontal past
    /// `threshold` pages, downward past `threshold` dismisses (the
    /// pre-existing swipe-down), anything else is a no-op. The dominant
    /// axis decides, so a diagonal flick doesn't both page and dismiss.
    static func swipeIntent(translation: CGSize, threshold: CGFloat) -> SwipeIntent {
        let dx = translation.width, dy = translation.height
        if abs(dx) > abs(dy) {
            guard abs(dx) >= threshold else { return .none }
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
