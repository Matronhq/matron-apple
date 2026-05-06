import XCTest
import MatrixRustSDK
@testable import MatronPush

/// Pins the per-platform / per-build-config `PushConfig.appID`. Sygnal
/// rejects tokens whose `app_id` doesn't match a configured app entry,
/// so a silent rename here would break push delivery without any
/// runtime crash. The mapping must stay in lockstep with Sygnal's
/// `sygnal.yaml` — see Phase 4 plan Task 9 ("Server-side runbook").
final class PushConfigTests: XCTestCase {
    func test_appID_isPlatformAndBuildSpecific() {
        #if os(iOS)
            #if DEBUG
            XCTAssertEqual(PushConfig.appID, "chat.matron.ios.dev")
            #else
            XCTAssertEqual(PushConfig.appID, "chat.matron.ios")
            #endif
        #elseif os(macOS)
            #if DEBUG
            XCTAssertEqual(PushConfig.appID, "chat.matron.mac.dev")
            #else
            XCTAssertEqual(PushConfig.appID, "chat.matron.mac")
            #endif
        #endif
    }

    func test_pushFormat_isEventIDOnly() {
        // Anything other than `.eventIdOnly` would mean the homeserver
        // sends decrypted content in the APNs payload — which would
        // leak plaintext via Apple's push relay. Pin this enum value
        // so a refactor (or a SDK that adds a new `PushFormat` case)
        // can't silently regress it.
        XCTAssertEqual(PushConfig.pushFormat, .eventIdOnly)
    }

    func test_appDisplayName_andLanguage_arePinned() {
        XCTAssertEqual(PushConfig.appDisplayName, "Matron")
        XCTAssertEqual(PushConfig.language, "en")
    }
}
