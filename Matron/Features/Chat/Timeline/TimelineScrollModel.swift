import CoreGraphics

/// The UIKit timeline's geometry and scroll state, with no UIKit in it
/// (spec §2 "pure-logic core"). Heights come in exact (measured, never
/// estimated); the model answers where every row sits and where the
/// viewport must be after any change — `ChatTimelineController` writes
/// `contentOffsetY` to the collection view and nothing else moves it.
///
/// Coordinates: content space, top-down. A conversation shorter than the
/// viewport hugs the bottom (`alignmentPad`), like the SwiftUI path's
/// `defaultScrollAnchor(.bottom, for: .alignment)`.
struct TimelineScrollModel: Equatable {
    struct Metrics: Equatable {
        /// `.padding(.vertical)` around the SwiftUI `VStack`.
        var topInset: CGFloat = 16
        var bottomInset: CGFloat = 16
        /// `VStack(spacing: 8)`.
        var rowSpacing: CGFloat = 8
        /// "At the bottom" — `ChatView.nearBottomThresholdPt`.
        var nearBottomThreshold: CGFloat = 100
        /// Reveal older history within this many screens of the top (spec).
        var nearTopScreens: CGFloat = 1.5
    }

    struct Row: Equatable {
        let id: String
        var height: CGFloat
    }

    /// A viewport position by row identity: the row and how far the
    /// reference edge sits below that row's top.
    struct Anchor: Equatable {
        let rowID: String
        let offsetInRow: CGFloat
    }

    let metrics: Metrics
    private(set) var rows: [Row] = []
    private(set) var footerHeight: CGFloat = 0
    private(set) var viewportHeight: CGFloat = 0
    private(set) var contentOffsetY: CGFloat = 0
    private(set) var isFollowingTail = true
    /// Mirrors `ChatViewModel.windowContainsTail`: follow-tail may only
    /// re-arm when the rendered window really ends at the live tail.
    var windowContainsTail = true

    private var tops: [CGFloat] = []
    private var indexByID: [String: Int] = [:]
    private var rowsBottom: CGFloat = 0

    init(metrics: Metrics = Metrics()) {
        self.metrics = metrics
        rowsBottom = metrics.topInset
    }

    // MARK: Geometry

    var stackHeight: CGFloat { rowsBottom + metrics.bottomInset + footerHeight }
    var alignmentPad: CGFloat { max(0, viewportHeight - stackHeight) }
    var contentHeight: CGFloat { max(stackHeight, viewportHeight) }
    var maxOffsetY: CGFloat { max(0, contentHeight - viewportHeight) }
    var footerMinY: CGFloat { alignmentPad + rowsBottom + metrics.bottomInset }

    func rowMinY(at index: Int) -> CGFloat { alignmentPad + tops[index] }
    func index(of id: String) -> Int? { indexByID[id] }
    func height(of id: String) -> CGFloat? { indexByID[id].map { rows[$0].height } }

    // MARK: Content changes

    mutating func replaceRows(_ newRows: [Row], footerHeight newFooter: CGFloat) {
        rows = newRows
        footerHeight = newFooter
        rebuild()
        settle()
    }

    mutating func updateHeight(ofRow id: String, to height: CGFloat) {
        guard let index = indexByID[id], rows[index].height != height else { return }
        rows[index].height = height
        rebuild()
        settle()
    }

    mutating func setFooterHeight(_ height: CGFloat) {
        guard height != footerHeight else { return }
        footerHeight = height
        settle()
    }

    // MARK: Viewport

    mutating func setViewportHeight(_ height: CGFloat) {
        guard height != viewportHeight else { return }
        viewportHeight = height
        settle()
    }

    // MARK: Follow-tail

    mutating func followTail() {
        isFollowingTail = true
        contentOffsetY = maxOffsetY
    }

    mutating func stopFollowing() {
        isFollowingTail = false
    }

    // MARK: Internals

    private mutating func rebuild() {
        tops.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        var y = metrics.topInset
        for (index, row) in rows.enumerated() {
            tops.append(y)
            indexByID[row.id] = index
            y += row.height
            if index < rows.count - 1 { y += metrics.rowSpacing }
        }
        rowsBottom = y
    }

    /// After any change: pinned while following, else clamped (Task 9
    /// replaces this with anchor preservation).
    private mutating func settle() {
        if isFollowingTail {
            contentOffsetY = maxOffsetY
        } else {
            contentOffsetY = min(max(0, contentOffsetY), maxOffsetY)
        }
    }
}
