#if os(macOS)
import AppKit
import Observation

/// One message body (or caption) that can take part in a cross-message
/// selection. `MessageCopyTextView` is the production conformer; tests use
/// fakes. Everything is in WINDOW coordinates so the controller never needs
/// to know about scroll views or SwiftUI hosting.
@MainActor
public protocol CrossSelectionTarget: AnyObject {
    var selectionItemID: String? { get }
    var storageLength: Int { get }
    /// Frame in window coordinates (AppKit, y grows upward).
    var frameInWindow: NSRect { get }
    /// Insertion index for a window point, clamped by the conformer to
    /// `0…storageLength` (AppKit's `characterIndexForInsertion` already does).
    func characterIndex(atWindowPoint point: NSPoint) -> Int
    /// `nil` removes the highlight; a range applies it (zero length = none visible).
    func setCrossSelection(_ range: NSRange?)
    /// Markdown for the current range; `""` when there is none or it is empty.
    func crossSelectionMarkdown() -> String
}

/// A message's contribution to the selection, in row order.
public struct SelectedSpan: Equatable {
    public let id: String
    /// `nil` — the message has no text view (image without caption, a card).
    /// `""` — it has one, but the selected part is empty (pointer in the gap
    /// just above it).
    public let text: String?

    public init(id: String, text: String?) {
        self.id = id
        self.text = text
    }
}

/// What the timeline host builds from `selectedSpans()`: the pasteboard
/// text and how many messages contributed a line (for "Copy N Messages").
public struct SelectionTranscript {
    public let text: String
    public let messageCount: Int

    public init(text: String, messageCount: Int) {
        self.text = text
        self.messageCount = messageCount
    }
}

/// The cross-message selection of ONE timeline (a `MacChatView` or a
/// `MacSubChatPane` each own one). Holds the anchor and head as
/// `(item id, character index)`, the row order the timeline hands in, and
/// weak references to the live message text views so it can push per-view
/// highlight ranges as a drag extends.
///
/// Observation: only `hasSelection` is observed (context-menu builders and
/// ⌘C validation read it). Everything the drag touches per mouse event is
/// `@ObservationIgnored`, so extending the selection never invalidates a
/// SwiftUI row — the eager timeline's per-row gates are the scroll-perf
/// fence and must not be tripped by pointer movement.
@MainActor
@Observable
public final class MessageSelectionController {

    /// Message item ids in row order; assigned by the timeline list whenever
    /// its rows change. Plain storage: written from `onChange`, never read
    /// from a SwiftUI body.
    ///
    /// Reassignment revalidates a FINISHED selection: a selection outlives
    /// its drag, so the row window can move under it — most commonly the
    /// `eph:` streaming placeholder being replaced by its durable row. An
    /// endpoint that leaves the order would leave `hasSelection` true over an
    /// empty `selectedIDs`: highlights linger and every copy path silently
    /// no-ops. Dropping the whole selection is the honest outcome.
    @ObservationIgnored public var orderedIDs: [String] = [] {
        didSet {
            guard hasSelection, let anchor, let head else { return }
            guard !orderedIDs.contains(anchor.id) || !orderedIDs.contains(head.id) else { return }
            // `clear()` never touches `orderedIDs`, so this cannot recurse.
            clear()
        }
    }

    public private(set) var hasSelection = false

    /// The transcript as it stood when the selection was finished — the
    /// snapshot both menu paths use. `@ObservationIgnored` on purpose: the
    /// SwiftUI menu leaf may read it without joining the timeline's
    /// observation graph, and it is stable between finish() and clear(), so
    /// a menu item's title and payload cannot disagree with each other or
    /// change under a click. ⌘C still copies through the LIVE provider.
    @ObservationIgnored public private(set) var finishedTranscript: SelectionTranscript?

    @ObservationIgnored public var transcriptProvider: (() -> SelectionTranscript)?
    @ObservationIgnored public var pasteboardWriter: (String) -> Void = { Pasteboard.copy($0) }
    /// Resolves the target directly under a window point, if any. `window`
    /// is `nil` in tests that drive `extend` without a real window; the
    /// default hit-tester has nothing to walk in that case and returns
    /// `nil`, but a caller-supplied hit-tester (as in tests) is still
    /// consulted — `resolveTarget` always tries it first regardless of
    /// whether `window` is `nil`, falling back to the nearest-row search
    /// only when it returns `nil` or a target with no `selectionItemID`.
    /// The default implementation walks the hit-test view up its
    /// superviews looking for a conformer.
    @ObservationIgnored public var hitTester: (NSPoint, NSWindow?) -> CrossSelectionTarget? = { point, window in
        guard let window else { return nil }
        var view = window.contentView?.hitTest(point)
        while let current = view {
            if let target = current as? CrossSelectionTarget { return target }
            view = current.superview
        }
        return nil
    }

    private struct End: Equatable {
        let id: String
        let charIndex: Int
    }

    @ObservationIgnored private var anchor: End?
    @ObservationIgnored private var head: End?
    @ObservationIgnored private var targets: [String: WeakTarget] = [:]
    /// Ids that currently carry a non-nil range, so a shrink can clear only those.
    @ObservationIgnored private var highlighted: Set<String> = []
    @ObservationIgnored private var clearMonitor: Any?

    private final class WeakTarget {
        weak var target: CrossSelectionTarget?
        init(_ target: CrossSelectionTarget) { self.target = target }
    }

    public init() {}

    // MARK: Registry

    public func register(_ target: CrossSelectionTarget) {
        guard let id = target.selectionItemID else { return }
        targets[id] = WeakTarget(target)
    }

    public func unregister(_ target: CrossSelectionTarget) {
        guard let id = target.selectionItemID, targets[id]?.target === target else { return }
        targets[id] = nil
    }

    private func target(for id: String) -> CrossSelectionTarget? {
        targets[id]?.target
    }

    // MARK: Selection lifecycle

    /// - Returns: `true` when a selection was actually started. `false` (the
    ///   anchor id is not in the current row order) leaves the caller's press
    ///   un-escalated, so it keeps selecting within its own message and still
    ///   closes its selection sequence on mouse-up.
    @discardableResult
    public func beginCrossMessage(anchorID: String, charIndex: Int) -> Bool {
        clear()
        guard orderedIDs.contains(anchorID) else { return false }
        anchor = End(id: anchorID, charIndex: charIndex)
        head = anchor
        hasSelection = true
        return true
    }

    public func extend(toWindowPoint point: NSPoint, window: NSWindow?) {
        guard anchor != nil else { return }
        guard let target = resolveTarget(at: point, window: window),
              let id = target.selectionItemID,
              orderedIDs.contains(id) else { return }
        head = End(id: id, charIndex: target.characterIndex(atWindowPoint: point))
        applySpans()
    }

    public func finish() {
        guard anchor != nil else { return }
        applySpans()
        // `applySpans` falls through to `clear()` when an end has left the
        // row order: there is then no selection to snapshot and no reason to
        // arm a monitor whose only job is to clear one.
        guard anchor != nil else { return }
        finishedTranscript = transcriptProvider?()
        installClearMonitor()
    }

    public func clear() {
        for id in highlighted { target(for: id)?.setCrossSelection(nil) }
        highlighted = []
        anchor = nil
        head = nil
        finishedTranscript = nil
        removeClearMonitor()
        if hasSelection { hasSelection = false }
    }

    // MARK: Reading the selection

    /// Ids between anchor and head inclusive, in row order.
    public var selectedIDs: [String] {
        guard let anchor, let head,
              let a = orderedIDs.firstIndex(of: anchor.id),
              let h = orderedIDs.firstIndex(of: head.id) else { return [] }
        return Array(orderedIDs[min(a, h)...max(a, h)])
    }

    public func selectedSpans() -> [SelectedSpan] {
        selectedIDs.map { id in
            SelectedSpan(id: id, text: target(for: id)?.crossSelectionMarkdown())
        }
    }

    /// ⌘C / Edit ▸ Copy / the AppKit item's fallback. Uses the LIVE provider,
    /// never `finishedTranscript`, so copying a selection that includes a
    /// still-streaming message copies its text as it stands now. Never runs
    /// from a SwiftUI body.
    public func copyTranscript() {
        guard hasSelection, let transcript = transcriptProvider?(), !transcript.text.isEmpty else { return }
        pasteboardWriter(transcript.text)
    }

    /// Copies text captured earlier (a menu item's payload, taken when the
    /// menu was built) rather than re-deriving it at click time — the click
    /// itself can reach the clear-monitor first and leave nothing to derive.
    public func copyText(_ text: String) {
        guard !text.isEmpty else { return }
        pasteboardWriter(text)
    }

    // MARK: Internals

    /// Direct hit first (always consulted, even without a window); otherwise
    /// the registered target vertically nearest the point (distance to its
    /// frame's y-extent, 0 when inside), ties broken by row order.
    ///
    /// The direct hit is only accepted when it is THIS controller's live
    /// registration for its id. The default hit-tester walks the window, so
    /// with a sub-chat pane beside the parent timeline it can return the
    /// other timeline's text view (or a recycled view mid-swap): trusting it
    /// froze the drag, because `extend` then found the id absent from
    /// `orderedIDs` and returned without moving the head instead of falling
    /// back to the nearest row.
    private func resolveTarget(at point: NSPoint, window: NSWindow?) -> CrossSelectionTarget? {
        if let direct = hitTester(point, window), let id = direct.selectionItemID,
           targets[id]?.target === direct {
            return direct
        }
        var best: (CrossSelectionTarget, CGFloat)?
        for id in orderedIDs {
            guard let candidate = target(for: id) else { continue }
            let frame = candidate.frameInWindow
            let distance: CGFloat
            if point.y > frame.maxY { distance = point.y - frame.maxY }
            else if point.y < frame.minY { distance = frame.minY - point.y }
            else { distance = 0 }
            if best == nil || distance < best!.1 { best = (candidate, distance) }
        }
        return best?.0
    }

    /// Recomputes every per-view range from anchor/head and pushes it.
    /// Dragging DOWN (anchor row above head row): anchor `press…end`,
    /// middles full, head `start…pointer`. Dragging UP mirrors it. Same row:
    /// the ordinary min…max range.
    private func applySpans() {
        // Either end can fall out of `orderedIDs` when the timeline's row
        // window moves (rows are dropped without an explicit `clear()`).
        // The highlighted set must stay in lockstep with anchor/head — a
        // stranded highlight with no corresponding selection is worse than
        // dropping the selection outright, so fall through to `clear()`
        // rather than returning with rows still lit and `hasSelection` true.
        guard let anchor, let head,
              let a = orderedIDs.firstIndex(of: anchor.id),
              let h = orderedIDs.firstIndex(of: head.id) else {
            clear()
            return
        }
        var next: [String: NSRange] = [:]
        if a == h {
            // No target (e.g. an image/card row) produces no span for this
            // id — fall through so any stale highlight elsewhere still gets
            // cleared by the loop below, instead of returning early.
            if let target = target(for: anchor.id) {
                let length = target.storageLength
                let lo = min(anchor.charIndex, head.charIndex, length)
                let hi = min(max(anchor.charIndex, head.charIndex), length)
                next[anchor.id] = NSRange(location: lo, length: hi - lo)
            }
        } else {
            let down = a < h
            for id in orderedIDs[min(a, h)...max(a, h)] {
                guard let target = target(for: id) else { continue }
                let length = target.storageLength
                let range: NSRange
                if id == anchor.id {
                    let i = min(anchor.charIndex, length)
                    range = down ? NSRange(location: i, length: length - i) : NSRange(location: 0, length: i)
                } else if id == head.id {
                    let i = min(head.charIndex, length)
                    range = down ? NSRange(location: 0, length: i) : NSRange(location: i, length: length - i)
                } else {
                    range = NSRange(location: 0, length: length)
                }
                next[id] = range
            }
        }
        for id in highlighted where next[id] == nil {
            target(for: id)?.setCrossSelection(nil)
        }
        for (id, range) in next {
            target(for: id)?.setCrossSelection(range)
        }
        highlighted = Set(next.keys.filter { target(for: $0) != nil })
    }

    /// Test seam: a finished selection arms exactly one clear monitor, and a
    /// cleared one arms none (a monitor with nothing to clear would still
    /// fire on every left press for the life of the controller).
    var hasClearMonitor: Bool { clearMonitor != nil }

    private func installClearMonitor() {
        removeClearMonitor()
        clearMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // Any left press anywhere ends the selection. Right-clicks keep
            // it so "Copy N Messages" can act on it.
            self?.clear()
            return event
        }
    }

    private func removeClearMonitor() {
        if let clearMonitor {
            NSEvent.removeMonitor(clearMonitor)
            self.clearMonitor = nil
        }
    }
}
#endif
