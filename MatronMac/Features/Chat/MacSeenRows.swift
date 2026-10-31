import AppKit
import MatronDesignSystem
import MatronJournal
import MatronViewModels

/// The Mac chat timeline's read-state feed (`SeenTracker`): which rows are
/// on screen, from their frames and the scroll viewport, as the table
/// timeline (`MacTimelineController`) hands them over. `SeenVisibility`
/// applies the shared rule: a fraction of the VIEWPORT, so a message taller
/// than two screens (a long final summary, the kind that matters most)
/// still reads as visible.
///
/// A plain reference box, never observed: writes from scroll callbacks
/// must not invalidate the timeline.
@MainActor
final class MacSeenRows {
    private weak var viewModel: ChatViewModel?
    private let surface = UUID()
    private var frames: [String: CGRect] = [:]
    private var viewport: CGRect = .zero
    private var lastReported: Set<String>?
    private weak var observedWindow: NSWindow?
    /// The timeline's window, handed over with its frames.
    private weak var tableWindow: NSWindow?
    private var occlusionObserver: NSObjectProtocol?
    /// Whether the timeline's window is on screen: minimised, hidden or
    /// fully covered shows nothing. A seam for tests, whose host windows
    /// are never reported visible.
    var isWindowVisible: (NSWindow?) -> Bool = { $0?.occlusionState.contains(.visible) ?? false }

    func attach(_ viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    /// The table timeline's feed (`MacTimelineController`): every row on
    /// screen with its frame, and the viewport, in the table's own space
    /// (content insets removed), all at once. Replaces the frames: the
    /// table knows exactly which rows are on screen, so nothing is pruned.
    func setVisibleFrames(_ rowFrames: [(id: String, frame: CGRect)], viewport rect: CGRect, window: NSWindow?) {
        tableWindow = window
        var next: [String: CGRect] = [:]
        for row in rowFrames where SeenVisibility.seq(forRowID: row.id) != nil {
            next[row.id] = row.frame
        }
        frames = next
        viewport = rect
        report()
    }

    /// The chat left: flush what it saw and stop watching the window.
    /// Detaches, so geometry callbacks during teardown can't report again;
    /// `attach` on the next appear resumes.
    func end() {
        viewModel?.endSeenReporting(surface: surface)
        viewModel = nil
        lastReported = nil
        frames = [:]
        stopObservingWindow()
    }

    private func report() {
        guard let viewModel else { return }
        let window = tableWindow
        observe(window)
        let windowVisible = isWindowVisible(window)
        // Rows that left the timeline's window since the table last handed
        // its frames over keep them here until the next hand-over; only
        // rows still in the window count.
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
