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
/// this work is fixing. So the background task is requested FIRST, and a
/// denied grant while backgrounded (or a re-request after one expired) means
/// no hold at all: the attempt is skipped and retried later, typically once
/// the app is foregrounded (Bugbot "Denied background task keeps locks").
/// If the task expires mid-wipe, the hold ends first and the attempt fails.
/// A failed attempt is logged and retried with backoff; the caller keeps the
/// session unpublished until one succeeds.
@MainActor
enum FreshLoginSearchWipe {
    /// Takes the database hold, returning its release — or `nil` when no
    /// safe hold can be taken right now.
    typealias Hold = (_ name: String) -> (() -> Void)?

    private static let logger = os.Logger(subsystem: "chat.matron", category: "fresh-login-wipe")

    static func run(waitForProtectedData: () async -> Void,
                    openSearch: () -> SearchService?,
                    hold: Hold = holdDatabases,
                    retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(15), .seconds(30)]) async {
        var attempt = 0
        while !Task.isCancelled {
            await waitForProtectedData()
            guard let release = hold("fresh-login-wipe") else {
                logger.info("no background time for the fresh-login wipe; retrying later (attempt \(attempt + 1, privacy: .public))")
                try? await Task.sleep(for: retryDelays[min(attempt, retryDelays.count - 1)])
                attempt += 1
                continue
            }
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

    /// The production hold: a background task, then a database activity; the
    /// task's expiration ends both, synchronously, before iOS suspends.
    static func holdDatabases(named name: String) -> (() -> Void)? {
        holdDatabases(
            named: name,
            controller: .shared,
            isInBackground: { UIApplication.shared.applicationState == .background },
            beginTask: { name, expiration in
                UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
            },
            endTask: { UIApplication.shared.endBackgroundTask($0) })
    }

    /// Seamed form of `holdDatabases(named:)` for tests.
    ///
    /// Order matters. The background task is what keeps the process running,
    /// so it is requested before anything is resumed. Denied while the app
    /// is in the background, there is nothing to keep the process alive
    /// through the wipe, and resuming the databases would hold App Group
    /// locks into the suspension: no hold (`nil`). Denied in the foreground
    /// (not expected, but the API allows it) the activity is still safe —
    /// the app is running, and a later background transition ends the
    /// foreground anyway — so it is taken.
    static func holdDatabases(
        named name: String,
        controller: DatabaseSuspensionController,
        isInBackground: () -> Bool,
        beginTask: (_ name: String, _ expiration: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier,
        endTask: @escaping (UIBackgroundTaskIdentifier) -> Void
    ) -> (() -> Void)? {
        final class Token {
            var activity: DatabaseSuspensionController.Activity?
            var taskID: UIBackgroundTaskIdentifier = .invalid
            var endTask: ((UIBackgroundTaskIdentifier) -> Void)?
            func end() {
                // Databases first: once the task ends iOS may suspend.
                activity?.end()
                activity = nil
                guard taskID != .invalid else { return }
                endTask?(taskID)
                taskID = .invalid
            }
        }
        let token = Token()
        token.endTask = endTask
        token.taskID = beginTask("chat.matron.\(name)") { token.end() }
        if token.taskID == .invalid, isInBackground() { return nil }
        token.activity = controller.beginActivity(named: name)
        return { token.end() }
    }
}
