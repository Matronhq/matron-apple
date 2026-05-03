import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

final class AttachmentImageSnapshotTests: XCTestCase {
    func test_placeholder() {
        assertVariants(
            of: AttachmentImage(image: nil, caption: "screenshot.png").frame(width: 320),
            named: "placeholder"
        )
    }
}

final class AttachmentFileSnapshotTests: XCTestCase {
    func test_basic() {
        assertVariants(
            of: AttachmentFile(filename: "diff.patch", sizeBytes: 4096).frame(width: 320),
            named: "basic"
        )
    }

    func test_unknownSize() {
        assertVariants(
            of: AttachmentFile(filename: "report.pdf", sizeBytes: nil).frame(width: 320),
            named: "unknownSize"
        )
    }
}
