import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

/// The Storage rows are one shared view (plan R8) rather than two parallel
/// copies in the platform Settings screens, which is also what gives spec
/// §3.10's "Storage section snapshot on both platforms" a single home:
/// `assertVariants` renders the iOS and the macOS renderer.
final class StorageSettingsRowsSnapshotTests: XCTestCase {
    private let model = StorageSettingsRows.Model(
        journalBytes: 440 * 1_000_000,
        searchBytes: 544 * 1_000_000,
        events: 457_102,
        conversations: 6_214,
        launchText: "store 1.9 s · first list 2.4 s · catch-up 6.1 s",
        maintenanceText: "1 hour ago")

    func testByteTextIsHumanReadableAndVariesWithSize() {
        XCTAssertFalse(StorageSettingsRows.byteText(0).isEmpty)
        XCTAssertNotEqual(StorageSettingsRows.byteText(0),
                          StorageSettingsRows.byteText(440_000_000))
        XCTAssertTrue(StorageSettingsRows.byteText(440_000_000).contains("MB"),
                      "got \(StorageSettingsRows.byteText(440_000_000))")
    }

    /// Pinned to `en_US_POSIX` inside `countsText`, so this assertion holds
    /// on a machine with German or French measurement settings — where
    /// `.number.grouping(.automatic)` would render `457.102` or `457 102`.
    func testCountsTextIsEventsThenConversations() {
        XCTAssertEqual(StorageSettingsRows.countsText(events: 457_102, conversations: 6_214),
                       "457,102 / 6,214")
    }

    func testLoadedRows() {
        assertVariants(of: Form { Section("Storage") { StorageSettingsRows(model: model) } }
            .frame(width: 420, height: 260), named: "storage-loaded")
    }

    func testSpinnerWhileTheReadIsInFlight() {
        assertVariants(of: Form { Section("Storage") { StorageSettingsRows(model: nil) } }
            .frame(width: 420, height: 120), named: "storage-loading")
    }
}
