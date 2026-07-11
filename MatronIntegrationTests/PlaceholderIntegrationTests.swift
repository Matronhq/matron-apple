import XCTest

/// Task 14 (The Purge) deleted the Matrix-era integration scenarios
/// (`VerificationFlowIntegrationTests`, `ChatListLiveUpdatesTests`) along
/// with the SDK stack they exercised. This placeholder keeps the
/// `MatronIntegrationTests` target non-empty so `xcodegen generate` and
/// `xcodebuild` stay green; Task 15/16 replaces it with journal-protocol
/// integration coverage.
final class PlaceholderIntegrationTests: XCTestCase {
    func test_placeholder() {
        XCTAssertTrue(true)
    }
}
