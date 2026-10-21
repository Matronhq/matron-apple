#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import MatronDesignSystem

/// An image attachment's line reads `name · size`. However long the name,
/// the line stays one line and no wider than the image above it: the name
/// is truncated (in the middle), never the size, and the card never widens.
@MainActor
final class AttachmentImageFilenameTests: XCTestCase {
    private let pixelSize = CGSize(width: 1600, height: 1000)

    private func fittingSize(filename: String?, meta: String? = "38.9 MB") -> CGSize {
        let host = NSHostingView(rootView: AttachmentImage(image: nil, filename: filename, meta: meta,
                                                           pixelSize: pixelSize))
        return host.fittingSize
    }

    func test_aLongNameStaysOneLineAndNoWiderThanTheImage() throws {
        let box = try XCTUnwrap(AttachmentImage.displaySize(for: pixelSize))
        let short = fittingSize(filename: "a.png")
        let long = fittingSize(filename: String(repeating: "a-very-long-file-name-", count: 12) + "final.png")
        XCTAssertEqual(long.height, short.height, accuracy: 0.5, "a long name must not wrap onto a second line")
        XCTAssertLessThanOrEqual(long.width, box.width + 0.5, "a long name must not widen the attachment")
    }

    func test_theNameAddsNoHeightOverTheSizeAlone() {
        XCTAssertEqual(fittingSize(filename: "divider.png").height, fittingSize(filename: nil).height, accuracy: 0.5)
    }

    func test_anEmptyNameIsTheSizeAlone() {
        XCTAssertEqual(fittingSize(filename: ""), fittingSize(filename: nil))
    }
}
#endif
