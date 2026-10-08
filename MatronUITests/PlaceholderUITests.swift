import XCTest

/// Task 14 (The Purge) deleted the Matrix-era UI scenarios
/// (`ReverseDirectionIOSUITests`, `MatronVsMatronIOSUITests`) along with
/// the verification flows they drove. This placeholder keeps the
/// `MatronUITests` target non-empty so `xcodegen generate` and
/// `xcodebuild` stay green; a later task replaces it with journal-protocol
/// UI coverage.
final class PlaceholderUITests: XCTestCase {
    func test_placeholder() {
        XCTAssertTrue(true)
    }
}
