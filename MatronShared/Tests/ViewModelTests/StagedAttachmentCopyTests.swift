import XCTest
@testable import MatronModels

final class StagedAttachmentCopyTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("stage-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testCopiesTheFileAndKeepsTheOriginal() throws {
        let source = scratch.appendingPathComponent("clip.mov")
        try Data("moving pictures".utf8).write(to: source)
        let staged = try StagedAttachment.stage(copying: source)
        defer { staged.deleteStagedCopy() }
        XCTAssertEqual(staged.filename, "clip.mov")
        XCTAssertEqual(staged.sizeBytes, 15)
        XCTAssertEqual(try Data(contentsOf: staged.url), Data("moving pictures".utf8))
        XCTAssertNotEqual(staged.url, source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testFollowsALinkToItsFileUnderTheLinksName() throws {
        let target = scratch.appendingPathComponent("real.txt")
        try Data("abc".utf8).write(to: target)
        let link = scratch.appendingPathComponent("shown.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let staged = try StagedAttachment.stage(copying: link)
        defer { staged.deleteStagedCopy() }
        XCTAssertEqual(staged.filename, "shown.txt")
        XCTAssertEqual(staged.sizeBytes, 3)
        let values = try staged.url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        XCTAssertEqual(values.isSymbolicLink, false)
        XCTAssertEqual(values.isRegularFile, true)
    }

    func testRefusesAFolderAndLeavesNothingStaged() throws {
        let folder = scratch.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let before = (try? FileManager.default.contentsOfDirectory(atPath: StagedAttachment.stagingDirectory.path)) ?? []
        XCTAssertThrowsError(try StagedAttachment.stage(copying: folder))
        let after = (try? FileManager.default.contentsOfDirectory(atPath: StagedAttachment.stagingDirectory.path)) ?? []
        XCTAssertEqual(Set(after), Set(before))
    }
}
