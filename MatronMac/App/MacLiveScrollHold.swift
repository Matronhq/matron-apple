import AppKit
import MatronViewModels

/// Holds the window's live updates (`LiveUpdateGate`) while any scroll
/// view in the app is live-scrolling — a trackpad or wheel gesture,
/// momentum included — and lets them through when the last one stops.
/// Every update that lands mid-scroll lays the window out again, and that
/// is the judder: the lists can wait the second or two a scroll takes.
@MainActor
final class MacLiveScrollHold {
    static let shared = MacLiveScrollHold()

    private var gate: LiveUpdateGate?
    private var scrolling: Set<ObjectIdentifier> = []
    private var observers: [NSObjectProtocol] = []

    /// Idempotent.
    func install(gate: LiveUpdateGate) {
        guard self.gate == nil else { return }
        self.gate = gate
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let id = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated { self?.began(id) }
        })
        observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let id = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated { self?.ended(id) }
        })
    }

    /// One hold per scroll view, however many start notifications it posts.
    func began(_ id: ObjectIdentifier?) {
        guard let id, scrolling.insert(id).inserted else { return }
        gate?.beginHold()
    }

    func ended(_ id: ObjectIdentifier?) {
        guard let id, scrolling.remove(id) != nil else { return }
        gate?.endHold()
    }
}
