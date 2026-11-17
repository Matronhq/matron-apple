import Foundation
import MatronJournal

/// A store's re-read of a list from the journal on reconnect and on return
/// to the front, through a `RefreshPacer`. A request inside the pacer's
/// interval is not dropped: it runs when the interval ends, if the app is
/// then in front, so a missed live frame is never kept for longer than
/// the interval.
@MainActor
final class PacedReader {
    private let pacer: RefreshPacer
    private var later: Task<Void, Never>?

    init(pacer: RefreshPacer) {
        self.pacer = pacer
    }

    func request(_ read: @escaping @MainActor () async -> Void) async {
        if pacer.take() {
            later?.cancel()
            later = nil
            await read()
            return
        }
        guard later == nil, let wait = pacer.untilNext() else { return }
        later = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.later = nil
            await self.request(read)
        }
    }

    /// The store stopped: drops a scheduled read, and forgets the last one,
    /// which may have been abandoned mid-flight, so a restart reads at once.
    func cancel() {
        later?.cancel()
        later = nil
        pacer.reset()
    }
}
