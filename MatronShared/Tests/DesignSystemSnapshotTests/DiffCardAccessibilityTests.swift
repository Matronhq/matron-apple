import XCTest
@testable import MatronDesignSystem
import MatronEvents

/// Pins `DiffCard.accessibilitySummary(for:)` — the single source of truth
/// the chat timeline rows (iOS `TimelineItemView`, Mac `MacTimelineItemView`)
/// must reuse for their row-level `.accessibilityLabel` instead of
/// duplicating a shorter "Edited <file>" string that would silently
/// replace this card's own combined accessibility value (bugbot:
/// "VoiceOver drops the rich diff summary").
final class DiffCardAccessibilityTests: XCTestCase {
    private func event(
        tool: String? = "Edit", newFile: Bool = false,
        added: Int? = 2, removed: Int? = 1, hasFilename: Bool = true
    ) -> DiffEvent {
        // `filename` derives from `lastPathComponent` of displayPath/filePath
        // (DiffEvent.filename) — a bare basename here keeps the expected
        // strings below unambiguous.
        DiffEvent(filePath: hasFilename ? "/w/Sources/A.swift" : nil, displayPath: nil,
                  viewerURL: nil, tool: tool, label: nil, diff: "",
                  added: added, removed: removed, truncated: false, newFile: newFile)
    }

    func test_edit_includesCountsAndFilename() {
        XCTAssertEqual(
            DiffCard.accessibilitySummary(for: event()),
            "Edited A.swift, 2 additions, 1 removal")
    }

    func test_write_newFile_usesCreatedWording() {
        XCTAssertEqual(
            DiffCard.accessibilitySummary(for: event(tool: "Write", newFile: true, added: 5, removed: nil)),
            "Created A.swift, 5 additions")
    }

    func test_write_existingFile_usesWroteWording() {
        XCTAssertEqual(
            DiffCard.accessibilitySummary(for: event(tool: "Write", newFile: false, added: nil, removed: 3)),
            "Wrote A.swift, 3 removals")
    }

    func test_missingFilename_fallsBackToGenericFile() {
        XCTAssertEqual(
            DiffCard.accessibilitySummary(for: event(added: 1, removed: nil, hasFilename: false)),
            "Edited file, 1 addition")
    }

    func test_singularCounts_dropPluralS() {
        XCTAssertEqual(
            DiffCard.accessibilitySummary(for: event(added: 1, removed: 1)),
            "Edited A.swift, 1 addition, 1 removal")
    }

    func test_noCounts_omitsThem() {
        XCTAssertEqual(
            DiffCard.accessibilitySummary(for: event(added: nil, removed: nil)),
            "Edited A.swift")
    }
}
