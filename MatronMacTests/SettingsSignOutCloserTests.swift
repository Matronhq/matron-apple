#if os(macOS)
import XCTest
@testable import MatronMac

final class SettingsSignOutCloserTests: XCTestCase {
    func test_signingOut_closesSettings() {
        XCTAssertTrue(SettingsSignOutCloser.closes(wasSignedIn: true, isSignedIn: false))
    }

    func test_signingIn_keepsSettingsOpen() {
        XCTAssertFalse(SettingsSignOutCloser.closes(wasSignedIn: false, isSignedIn: true))
    }

    func test_noChange_keepsSettingsOpen() {
        XCTAssertFalse(SettingsSignOutCloser.closes(wasSignedIn: true, isSignedIn: true))
        XCTAssertFalse(SettingsSignOutCloser.closes(wasSignedIn: false, isSignedIn: false))
    }
}
#endif
