import Foundation
import os
import UIKit
import MatronJournal
import MatronSearch

/// Empties the shared search index before a fresh login publishes its
/// session — and does not return until it has.
///
/// The index is shared by every account that signs in on this device, so a
/// wipe that silently fails hands the next account the previous one's
/// searchable messages. Two ways it used to fail (Bugbot, round 4):
/// - the phone was locked, so the `NSFileProtectionComplete` index could not
///   be reached (the wait below covers that);
/// - the login completed with the app in the background, where the
///   databases are suspended and GRDB refuses the delete with SQLITE_ABORT —
///   which a `try?` swallowed before publishing the session anyway.
///
/// So each attempt waits for protected data, then HOLDS the databases for
/// the delete: a `DatabaseSuspensionController` activity (resumed and
/// unsuspendable while held) backed by a `UIApplication` background task, so
/// iOS also keeps the process running for it — holding the activity alone
/// would keep a lock open straight into a suspension, the very `0xdead10cc`
/// this work is fixing. If the background task expires, the hold ends first
/// and the attempt fails. A failed attempt is logged and retried with
/// backoff; the caller keeps the session unpublished until one succeeds.
@MainActor
enum FreshLoginSearchWipe {
    typealias Hold = (_ name: String) -> () -> Void

    private static let logger = os.Logger(subsystem: "chat.matron", category: "fresh-login-wipe")

    static func run(waitForProtectedData: () async -> Void,
                    openSearch: () -> SearchService?,
                    hold: Hold = holdDatabases,
                    retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(15), .seconds(30)]) async {
        var attempt = 0
        while !Task.isCancelled {
            await waitForProtectedData()
            let release = hold("fresh-login-wipe")
            let succeeded: Bool
            if let search = openSearch() {
                do {
                    try await search.wipe()
                    succeeded = true
                } catch {
                    logger.error("search wipe failed (attempt \(attempt + 1, privacy: .public)): \(String(describing: error), privacy: .public)")
                    succeeded = false
                }
            } else {
                logger.error("search index could not be opened for the fresh-login wipe (attempt \(attempt + 1, privacy: .public))")
                succeeded = false
            }
            release()
            if succeeded { return }
            try? await Task.sleep(for: retryDelays[min(attempt, retryDelays.count - 1)])
            attempt += 1
        }
    }

    /// The production hold: a database activity plus a background task whose
    /// expiration ends both, synchronously, before iOS suspends.
    static func holdDatabases(named name: String) -> () -> Void {
        final class Token {
            var activity: DatabaseSuspensionController.Activity?
            var taskID: UIBackgroundTaskIdentifier = .invalid
            func end() {
                activity?.end()
                activity = nil
                guard taskID != .invalid else { return }
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        let token = Token()
        token.activity = DatabaseSuspensionController.shared.beginActivity(named: name)
        token.taskID = UIApplication.shared.beginBackgroundTask(withName: "chat.matron.\(name)") {
            MainActor.assumeIsolated { token.end() }
        }
        return { token.end() }
    }
}
