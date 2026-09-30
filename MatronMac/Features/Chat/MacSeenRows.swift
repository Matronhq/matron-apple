import AppKit
import SwiftUI
import MatronDesignSystem
import MatronJournal
import MatronViewModels

/// The Mac chat timeline's read-state feed (`SeenTracker`): which rows are
/// on screen, from their frames and the scroll viewport.
///
/// `onScrollTargetVisibilityChange` can't do this. Its threshold is a
/// fraction of the ROW, so a message taller than two screens (a long final
/// summary, the kind that matters most) never reads as visible. Rows report
/// their frames in the content's own coordinate space, which only changes on
/// layout, not on scroll; the scroll viewport arrives from
/// `onScrollGeometryChange`. `SeenVisibility` applies the shared rule.
///
/// A plain reference box, never observed: writes from geometry callbacks
/// must not invalidate the timeline.
@MainActor
final class MacSeenRows {
    /// Named on the scroll view's content; rows measure against it.
    static let coordinateSpace = "mac-timeline-content"

    private weak var viewModel: ChatViewModel?
    private weak var nativeScroll: NativeScrollViewBox?
    private let surface = UUID()
    private var frames: [String: CGRect] = [:]
    private var viewport: CGRect = .zero
    private var lastReported: Set<String>?
    private weak var observedWindow: NSWindow?
    private var occlusionObserver: NSObjectProtocol?
    /// Whether the timeline's window is on screen: minimised, hidden or
    /// fully covered shows nothing. A seam for tests, whose host windows
    /// are never reported visible.
    var isWindowVisible: (NSWindow?) -> Bool = { $0?.occlusionState.contains(.visible) ?? false }

    func attach(_ viewModel: ChatViewModel, scroll: NativeScrollViewBox) {
        self.viewModel = viewModel
        self.nativeScroll = scroll
    }

    /// A row's frame in `coordinateSpace`.
    func setFrame(_ frame: CGRect, for rowID: String) {
        // Separators and other seq-less rows can never be seen.
        guard SeenVisibility.seq(forRowID: rowID) != nil else { return }
        frames[rowID] = frame
        report()
    }

    /// The visible part of the content, content insets removed.
    func setViewport(_ rect: CGRect) {
        viewport = rect
        report()
    }

    /// The chat left: flush what it saw and stop watching the window.
    func end() {
        viewModel?.endSeenReporting(surface: surface)
        lastReported = nil
        frames = [:]
        stopObservingWindow()
    }

    private func report() {
        guard let viewModel else { return }
        let window = nativeScroll?.scrollView?.window
        observe(window)
        let windowVisible = isWindowVisible(window)
        // Rows that left the window keep their last frame here; only rows
        // still in it count. (Pruning here rather than on each row's
        // `onDisappear`: on a pane-branch move the new row instance can
        // report before the old one disappears.)
        var visible: [String] = []
        if windowVisible {
            let live = Set(viewModel.windowedRows.compactMap { row -> String? in
                if case .message(let item) = row { return item.id }
                return nil
            })
            if frames.keys.contains(where: { !live.contains($0) }) {
                frames = frames.filter { live.contains($0.key) }
            }
            visible = SeenVisibility.visibleIDs(frames.map { (id: $0.key, frame: $0.value) }, in: viewport)
        }
        let set = Set(visible)
        guard set != lastReported else { return }
        lastReported = set
        viewModel.reportVisibleRows(visible, surface: surface)
    }

    private func observe(_ window: NSWindow?) {
        guard window !== observedWindow else { return }
        stopObservingWindow()
        guard let window else { return }
        observedWindow = window
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
    }

    private func stopObservingWindow() {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        observedWindow = nil
    }
}

extension View {
    /// Feeds the scroll viewport to `rows`: the visible part of the content,
    /// content insets removed, in the space the rows measure in.
    func reportsSeenViewport(to rows: MacSeenRows) -> some View {
        onScrollGeometryChange(for: CGRect.self) { geo in
            var rect = geo.visibleRect
            rect.origin.y += geo.contentInsets.top
            rect.size.height -= geo.contentInsets.top + geo.contentInsets.bottom
            return rect
        } action: { _, rect in
            rows.setViewport(rect)
        }
    }

    /// Feeds this row's frame to `rows`, in the content's own coordinate
    /// space (it moves on layout, not on scroll). Fires with the initial
    /// frame on every appear, so a remounted row reports again.
    func reportsSeenFrame(id: String, to rows: MacSeenRows?) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(MacSeenRows.coordinateSpace))
        } action: { frame in
            rows?.setFrame(frame, for: id)
        }
    }
}
