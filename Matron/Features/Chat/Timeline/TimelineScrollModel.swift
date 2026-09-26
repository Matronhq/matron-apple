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

    /// Set by the last content change whose anchor row vanished — the
    /// controller breadcrumbs it (spec: nearest-survivor rescue).
    struct Rescue: Equatable {
        let lostRowID: String
        let survivorID: String?
    }
    private(set) var lastRescue: Rescue?

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
        let anchor = isFollowingTail ? nil : topAnchor()
        let previousIDs = rows.map(\.id)
        rows = newRows
        footerHeight = newFooter
        rebuild()
        settle(keeping: anchor, previousIDs: previousIDs)
    }

    mutating func updateHeight(ofRow id: String, to height: CGFloat) {
        guard let index = indexByID[id], rows[index].height != height else { return }
        let anchor = isFollowingTail ? nil : topAnchor()
        rows[index].height = height
        rebuild()
        settle(keeping: anchor, previousIDs: rows.map(\.id))
    }

    mutating func setFooterHeight(_ height: CGFloat) {
        guard height != footerHeight else { return }
        let anchor = isFollowingTail ? nil : topAnchor()
        footerHeight = height
        settle(keeping: anchor, previousIDs: rows.map(\.id))
    }

    /// The user's own scrolling (and UIKit bounce) — recorded, not clamped.
    mutating func noteUserOffset(_ y: CGFloat) {
        contentOffsetY = y
    }

    // MARK: Anchors

    /// First visible non-separator row, and how far the viewport's TOP edge
    /// sits below that row's top. Separators never anchor: they are day-keyed
    /// and relocate when the window head moves.
    func topAnchor() -> Anchor? {
        for (index, row) in rows.enumerated() where !row.id.hasPrefix("sep:") {
            let minY = rowMinY(at: index)
            if minY + row.height > contentOffsetY {
                return Anchor(rowID: row.id, offsetInRow: contentOffsetY - minY)
            }
        }
        return nil
    }

    /// Last non-separator row starting above the viewport's BOTTOM edge, and
    /// how far that edge sits below the row's top — what a keyboard resize
    /// keeps fixed while reading history (Messages behaviour).
    func bottomAnchor() -> Anchor? {
        let bottomEdge = contentOffsetY + viewportHeight
        for index in rows.indices.reversed() where !rows[index].id.hasPrefix("sep:") {
            let minY = rowMinY(at: index)
            if minY < bottomEdge {
                return Anchor(rowID: rows[index].id, offsetInRow: bottomEdge - minY)
            }
        }
        return nil
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

    private mutating func settle() {
        settle(keeping: nil, previousIDs: [])
    }

    /// After any change: pinned while following; otherwise the anchor row
    /// keeps its on-screen position, or its nearest survivor takes its
    /// place, or — nothing survives — the viewport goes to the bottom.
    private mutating func settle(keeping anchor: Anchor?, previousIDs: [String]) {
        lastRescue = nil
        if isFollowingTail {
            contentOffsetY = maxOffsetY
            return
        }
        guard let anchor else {
            clampOffset()
            return
        }
        if let index = indexByID[anchor.rowID] {
            contentOffsetY = rowMinY(at: index) + min(anchor.offsetInRow, rows[index].height)
        } else if let survivor = nearestSurvivor(of: anchor.rowID, in: previousIDs),
                  let index = indexByID[survivor] {
            lastRescue = Rescue(lostRowID: anchor.rowID, survivorID: survivor)
            contentOffsetY = rowMinY(at: index)
        } else {
            lastRescue = Rescue(lostRowID: anchor.rowID, survivorID: nil)
            contentOffsetY = maxOffsetY
        }
        clampOffset()
    }

    /// Nearest still-present, non-separator neighbour of `id` in the
    /// previous row order — below first (the row that slides into its
    /// place), then above, widening one step at a time.
    private func nearestSurvivor(of id: String, in previousIDs: [String]) -> String? {
        guard let origin = previousIDs.firstIndex(of: id) else { return nil }
        var step = 1
        while origin + step < previousIDs.count || origin - step >= 0 {
            for candidate in [origin + step, origin - step] where previousIDs.indices.contains(candidate) {
                let candidateID = previousIDs[candidate]
                if !candidateID.hasPrefix("sep:"), indexByID[candidateID] != nil { return candidateID }
            }
            step += 1
        }
        return nil
    }

    private mutating func clampOffset() {
        contentOffsetY = min(max(0, contentOffsetY), maxOffsetY)
    }
}
