import XCTest
import MatronModels
@testable import MatronDesignSystem

/// Pins the service-layer / model-layer → design-system enum bridges
/// declared in `StateBridges.swift`. Both bridges are identity
/// mappings today; the indirection lets design-system UX diverge from
/// the source enums without changing every call site, and these tests
/// fail compile-loudly if a new case is added without a matching
/// mapping (the bridges' `switch` is exhaustive on the source enum).
final class StateBridgesTests: XCTestCase {
    // MARK: - SyncBannerState.from(_:)

    func test_syncBannerState_mapsConnecting() {
        XCTAssertEqual(SyncBannerState.from(.connecting), .connecting)
    }

    func test_syncBannerState_mapsRunning() {
        XCTAssertEqual(SyncBannerState.from(.running), .running)
    }

    func test_syncBannerState_mapsOfflineWithReason() {
        XCTAssertEqual(
            SyncBannerState.from(.offline(reason: "network down")),
            .offline(reason: "network down")
        )
    }

    // MARK: - SendStateGlyph.from(_:)

    func test_sendStateGlyph_mapsSent() {
        XCTAssertEqual(SendStateGlyph.from(.sent), .sent)
    }

    func test_sendStateGlyph_mapsSending() {
        XCTAssertEqual(SendStateGlyph.from(.sending), .sending)
    }

    func test_sendStateGlyph_mapsFailedWithReason() {
        XCTAssertEqual(
            SendStateGlyph.from(.failed(reason: "boom")),
            .failed(reason: "boom")
        )
    }
}
