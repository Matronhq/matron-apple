import Foundation
import MatronJournal

extension Error {
    /// A read that ended because it was called off (the screen left, a
    /// newer read began), not because it failed: the task is cancelled, or
    /// the error says the request was. View models set no `error` for it.
    var isReadCancellation: Bool {
        if Task.isCancelled || self is CancellationError { return true }
        if let api = self as? JournalAPIError { return api.isCancellation }
        return (self as? URLError)?.code == .cancelled
    }
}
