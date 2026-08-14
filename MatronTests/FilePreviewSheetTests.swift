import QuickLook
import XCTest

@testable import Matron

/// Pins the QuickLook-vs-share decision for the file preview sheet.
/// `QuickLookPreview.canPreview` routes video/audio/PDF into the
/// embedded QuickLook player; anything QuickLook can't handle keeps the
/// share-only fallback. The fixtures are real (empty) files on disk
/// because `QLPreviewController.canPreview` consults the URL's type,
/// not its bytes.
final class FilePreviewSheetTests: XCTestCase {
    private var fixtureDir: URL!

    override func setUpWithError() throws {
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quicklook-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: fixtureDir)
    }

    private func fixture(named name: String) throws -> URL {
        let url = fixtureDir.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    func testVideoIsPreviewable() throws {
        XCTAssertTrue(QuickLookPreview.canPreview(try fixture(named: "clip.mp4")))
        XCTAssertTrue(QuickLookPreview.canPreview(try fixture(named: "clip.mov")))
    }

    func testAudioIsPreviewable() throws {
        XCTAssertTrue(QuickLookPreview.canPreview(try fixture(named: "voice.m4a")))
        XCTAssertTrue(QuickLookPreview.canPreview(try fixture(named: "voice.mp3")))
    }

    func testPDFIsPreviewable() throws {
        XCTAssertTrue(QuickLookPreview.canPreview(try fixture(named: "report.pdf")))
    }

    func testUnknownBinaryFallsBackToShare() throws {
        XCTAssertFalse(QuickLookPreview.canPreview(try fixture(named: "blob.matrondat")))
    }
}
