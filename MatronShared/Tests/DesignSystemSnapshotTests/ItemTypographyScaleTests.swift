import XCTest
@testable import MatronDesignSystem

/// The iPhone item-thread body size (decision #2954). Pinned as a number
/// because the SPM suite runs on the Mac host, where the iOS branch of
/// `ItemTypography.bodyScale` is not compiled — the phone value is kept as
/// its own constant so this test can see it.
final class ItemTypographyScaleTests: XCTestCase {
    /// ≈18pt at the default text size: one notch under the ≈20pt that read
    /// as "a bit big" (Dan, 2026-09-24), still above the 17pt chat body.
    func test_phoneItemBodyIsAboutEighteenPoints() {
        let size = 17 * ItemTypography.phoneBodyScale
        XCTAssertEqual(size, 18, accuracy: 0.1)
        XCTAssertGreaterThan(size, 17, "the item thread still reads a step above the 17pt chat body")
    }

    #if !os(macOS)
    func test_iOSBodyScaleIsThePhoneScale() {
        XCTAssertEqual(ItemTypography.bodyScale, ItemTypography.phoneBodyScale)
    }
    #endif
}
