import XCTest
@testable import MatronJournal

/// These errors surface verbatim in UI banners via `localizedDescription`.
/// Without LocalizedError conformances, Foundation renders enum dumps like
/// "MatronJournal.JournalSyncError error 0." (shipped to a real banner,
/// 2026-07-30 screenshots) — pin the human copy so it can't regress.
final class JournalErrorDescriptionTests: XCTestCase {
    func testSyncErrorsAreHumanReadable() {
        XCTAssertEqual(JournalSyncError.offline.localizedDescription,
                       "No connection to the server.")
        XCTAssertEqual(JournalSyncError.authRevoked.localizedDescription,
                       "This device was signed out by the server.")
    }

    func testAPIErrorsAreHumanReadable() {
        XCTAssertEqual(JournalAPIError.rateLimited.localizedDescription,
                       "The server is busy — trying again shortly.")
        XCTAssertEqual(JournalAPIError.lockedOut(retryAfterSeconds: 30).localizedDescription,
                       "Too many attempts — try again in 30s.")
        XCTAssertEqual(JournalAPIError.http(status: 502, message: "").localizedDescription,
                       "Server error (HTTP 502).")
        XCTAssertEqual(JournalAPIError.http(status: 500, message: "boom").localizedDescription,
                       "boom")
        XCTAssertEqual(JournalAPIError.transport("").localizedDescription,
                       "Couldn't reach the server.")
        // No raw "error N" fallbacks anywhere in the enum.
        let all: [JournalAPIError] = [
            .badCredentials, .lockedOut(retryAfterSeconds: 1), .rateLimited,
            .unauthenticated, .forbidden, .notFound, .conflict,
            .http(status: 418, message: "x"), .transport("x"),
        ]
        for error in all {
            XCTAssertFalse(error.localizedDescription.contains("JournalAPIError"),
                           "\(error) must not render as an enum dump")
        }
    }

    func testRPCErrorsAreHumanReadable() {
        XCTAssertEqual(RPCRequestError.timeout.localizedDescription,
                       "The agent didn't answer in time.")
        XCTAssertEqual(RPCRequestError.offline.localizedDescription,
                       "No connection to the server.")
    }
}
