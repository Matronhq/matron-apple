import Foundation
import GRDB

extension Error {
    /// Whether this is GRDB refusing a write because the databases are
    /// suspended (`SQLITE_ABORT` "Database is suspended", or the
    /// `SQLITE_INTERRUPT` of a statement cut short by the suspension) — see
    /// `DatabaseSuspensionController`. Not a fault: the iPhone app went to
    /// the background while a fetch was in the network, and the write that
    /// followed it landed after the suspension. Callers that cache server
    /// answers defer the work and fetch again after the resume instead of
    /// reporting it.
    var isDatabaseSuspension: Bool {
        (self as? DatabaseError)?.isInterruptionError == true
    }
}
