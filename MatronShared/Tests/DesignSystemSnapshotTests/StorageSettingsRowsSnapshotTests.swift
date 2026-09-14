import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

/// The Storage rows are one shared view (plan R8) rather than two parallel
/// copies in the platform Settings screens, which is also what gives spec
/// §3.10's "Storage section snapshot on both platforms" a single home in
/// principle: `assertVariants` is written to render both the iOS and the
/// macOS renderer. In practice, on this host, only the macOS renderer ever
/// runs: `swift test` executes on macOS, and `assertVariants`'s iOS branch
/// is gated `#if canImport(UIKit) && !os(macOS)`, which compiles out
/// entirely here — there is no code path in this suite (or in any other
/// `assertVariants` consumer in the repo) that records or checks an iOS
/// baseline from a `swift test` run. Recording here therefore produces six
/// `mac-*` PNGs (`storage-loaded` × {light,dark,axxxl} and
/// `storage-loading` × {light,dark,axxxl}), not twelve — the iOS half of
/// spec §3.10 is unverified on this host and stays that way until this
/// suite is wired into an iOS xcodebuild scheme.
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

    /// Non-round fixtures (review M1): the old `ByteCountFormatter`-backed
    /// implementation passed the fixture above only because 440 MB happens
    /// to land on an exact unit boundary with no fractional part, which
    /// hid the locale bug entirely. These three actually exercise the
    /// rounding/decimal path.
    func testByteTextRoundsFractionalUnitsToOneDecimalPlace() {
        XCTAssertEqual(StorageSettingsRows.byteText(1_536_000), "1.5 MB")
        XCTAssertEqual(StorageSettingsRows.byteText(1_500), "1.5 KB")
        XCTAssertEqual(StorageSettingsRows.byteText(2_147_483_648), "2.1 GB")
    }

    /// M8: the unit is picked from the raw byte count before rounding, so
    /// without the post-rounding bump this renders "1000 MB" — the
    /// rounded-up value crossing the very threshold that should have
    /// selected GB instead.
    func testByteTextBumpsUnitWhenRoundingCrossesTheThreshold() {
        XCTAssertEqual(StorageSettingsRows.byteText(999_999_999), "1 GB")
    }

    /// The regression M1 flagged: `ByteCountFormatter` has no `.locale`
    /// override, so it renders "1,5 MB" under a comma-decimal locale like
    /// `fr_FR`. `byteText` now formats the numeric part through a
    /// `NumberFormatter` pinned to `en_US_POSIX`, which does not consult
    /// `Locale.current` at all — so the output is identical regardless of
    /// what locale is active when this runs, and in particular never
    /// contains a comma decimal point.
    func testByteTextDoesNotVaryWithTheCurrentLocale() {
        let text = StorageSettingsRows.byteText(1_536_000)
        XCTAssertEqual(text, "1.5 MB")
        XCTAssertFalse(text.contains(","), "got \(text) — a comma means Locale.current leaked in")
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
