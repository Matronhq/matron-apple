import XCTest
@testable import MatronViewModels

final class AttachmentTempFilesTests: XCTestCase {
    /// Fix wave, item H: a path-traversal filename must never reach
    /// `appendingPathComponent` raw — `lastPathComponent` collapses the
    /// leading `../../` tree, leaving just the basename.
    func testSanitisedFilenameStripsPathTraversal() {
        XCTAssertEqual(AttachmentTempFiles.sanitisedFilename("../../x"), "x")
        XCTAssertEqual(AttachmentTempFiles.sanitisedFilename("/etc/passwd"), "passwd")
        XCTAssertFalse(AttachmentTempFiles.sanitisedFilename("..").contains("/"))
        XCTAssertEqual(AttachmentTempFiles.sanitisedFilename(""), AttachmentTempFiles.sanitisedFilename(""), "degenerate names sanitise deterministically")
    }

    func testEmptyNameRoundTripsThroughExistingFile() throws {
        let blob = "blob-\(UUID().uuidString)"
        XCTAssertNil(AttachmentTempFiles.existingFile(name: "", blobRef: blob))
        let written = try AttachmentTempFiles.write(Data([1]), name: "", blobRef: blob)
        XCTAssertEqual(AttachmentTempFiles.existingFile(name: "", blobRef: blob), written)
        XCTAssertEqual(AttachmentTempFiles.destination(name: "..", blobRef: blob), AttachmentTempFiles.destination(name: "..", blobRef: blob))
    }

    /// Fix wave, item H: two attachments sharing a display filename must
    /// not collide — uniqueness comes from a digest of `blobRef`, a
    /// distinct subdirectory per attachment.
    func testSameNameDifferentBlobRefsGetDifferentURLs() throws {
        let a = try AttachmentTempFiles.write(Data([1]), name: "a.pdf", blobRef: "blob-1")
        let b = try AttachmentTempFiles.write(Data([2]), name: "a.pdf", blobRef: "blob-2")
        defer {
            try? FileManager.default.removeItem(at: a.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try Data(contentsOf: a), Data([1]))
        XCTAssertEqual(try Data(contentsOf: b), Data([2]))
    }
}
