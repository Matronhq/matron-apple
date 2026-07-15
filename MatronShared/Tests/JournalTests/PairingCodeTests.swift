import XCTest
@testable import MatronJournal

final class PairingCodeTests: XCTestCase {
    func test_normalize_uppercasesAndStripsSeparators() {
        XCTAssertEqual(PairingCode.normalize("ktnm-3vq8"), "KTNM3VQ8")
        XCTAssertEqual(PairingCode.normalize(" ktnm 3vq8 "), "KTNM3VQ8")
        XCTAssertEqual(PairingCode.normalize("KTNM3VQ8"), "KTNM3VQ8")
        XCTAssertEqual(PairingCode.normalize("k-t*n_m3.vq8"), "KTNM3VQ8")
        XCTAssertEqual(PairingCode.normalize(""), "")
    }

    func test_display_insertsHyphenAfterFourChars_partialInputSafe() {
        XCTAssertEqual(PairingCode.display("ktnm3vq8"), "KTNM-3VQ8")
        XCTAssertEqual(PairingCode.display("ktn"), "KTN")
        XCTAssertEqual(PairingCode.display("ktnm"), "KTNM")
        XCTAssertEqual(PairingCode.display("ktnm3"), "KTNM-3")
        XCTAssertEqual(PairingCode.display(""), "")
    }

    func test_isPlausible_exactlyEightNormalizedChars() {
        XCTAssertTrue(PairingCode.isPlausible("ktnm-3vq8"))
        XCTAssertTrue(PairingCode.isPlausible("KTNM3VQ8"))
        XCTAssertFalse(PairingCode.isPlausible("ktnm-3vq"))
        XCTAssertFalse(PairingCode.isPlausible("ktnm-3vq88"))
        XCTAssertFalse(PairingCode.isPlausible(""))
    }
}
