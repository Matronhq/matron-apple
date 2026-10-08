import XCTest
@testable import MatronDesignSystem

final class QRCodeTests: XCTestCase {
    func test_image_rendersSquareCGImage() {
        let image = QRCode.image(for: "matron://link?v=1&server=https%3A%2F%2Fchat.example.com&code=KTNM-3VQ8")
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, image?.height)
        XCTAssertGreaterThan(image?.width ?? 0, 100) // scaled up, not the raw ~30px matrix
    }
}
