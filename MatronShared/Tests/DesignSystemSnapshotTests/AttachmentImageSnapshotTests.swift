import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

final class AttachmentImageSnapshotTests: XCTestCase {
    func test_placeholder() {
        assertVariants(
            of: AttachmentImage(image: nil, meta: "screenshot.png").frame(width: 320),
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

    func test_downloading() {
        assertVariants(
            of: AttachmentFile(filename: "report.pdf", sizeBytes: 12_515_546, isLoading: true)
                .frame(width: 320),
            named: "downloading"
        )
    }

    func test_expired() {
        // Reaped server-side (journal media reaper): dimmed, "Expired"
        // subtitle, no tap affordance. Size is deliberately still known —
        // the tombstone keeps name/size/caption.
        assertVariants(
            of: AttachmentFile(filename: "report.pdf", sizeBytes: 12_515_546, isExpired: true)
                .frame(width: 320),
            named: "expired"
        )
    }
}
