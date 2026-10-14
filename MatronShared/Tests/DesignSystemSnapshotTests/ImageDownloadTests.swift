import XCTest
import UniformTypeIdentifiers
import ImageIO
@testable import MatronDesignSystem

final class ImageDownloadTests: XCTestCase {
    func test_keepsANameThatHasAnExtension() {
        XCTAssertEqual(ImageDownload.suggestedFilename(name: "screen shot.png", type: .jpeg), "screen shot.png")
    }

    func test_addsTheSniffedExtensionToABareName() {
        XCTAssertEqual(ImageDownload.suggestedFilename(name: "diagram", type: .png), "diagram.png")
    }

    func test_namelessImageGetsAGenericName() {
        XCTAssertEqual(ImageDownload.suggestedFilename(name: nil, type: .jpeg), "Image.jpeg")
        XCTAssertEqual(ImageDownload.suggestedFilename(name: "  ", type: nil), "Image")
    }

    func test_pathSeparatorsAreDropped() {
        XCTAssertEqual(ImageDownload.suggestedFilename(name: "../../etc/x.png", type: nil), "..-..-etc-x.png")
    }

    func test_sniffsTheBytesNotTheName() throws {
        let data = try Self.pngData()
        let download = ImageDownload(data: data, name: "photo")
        XCTAssertEqual(download.contentType, .png)
        XCTAssertEqual(download.filename, "photo.png")
        XCTAssertEqual(download.data, data)
    }

    func test_unrecognisedBytesFallBackToTheNamesType() {
        let download = ImageDownload(data: Data([0, 1, 2, 3]), name: "pic.gif")
        XCTAssertEqual(download.contentType, .gif)
        XCTAssertEqual(download.filename, "pic.gif")
    }

    func test_temporaryFileHoldsTheOriginalBytes() throws {
        let data = try Self.pngData()
        let url = try ImageDownload(data: data, name: "a").writeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.lastPathComponent, "a.png")
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    private static func pngData() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }
}
