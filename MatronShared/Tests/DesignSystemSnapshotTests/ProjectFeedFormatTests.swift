import XCTest
import MatronModels
@testable import MatronDesignSystem

/// A project's files in words: a tile's caption, name and extension.
final class ProjectFeedFormatTests: XCTestCase {
    typealias F = ProjectsSnapshotTests

    // MARK: Files

    func testFileLabels() {
        let pdf = ProjectFile(blobID: "b1", name: "Claims list.pdf", contentType: "application/pdf",
                              source: .item(num: 5090), postedAt: F.ago(2 * 86_400))
        XCTAssertEqual(ProjectFeedFormat.fileMeta(pdf, now: F.now), "#5090 · 2d")
        XCTAssertEqual(ProjectFeedFormat.fileExtension(pdf), "PDF")
        let chat = ProjectFile(blobID: "b2", contentType: "image/png", caption: "Hero: slate\nflat-lay",
                               source: .chat(convoID: "c", seq: 4), postedAt: nil)
        XCTAssertEqual(ProjectFeedFormat.fileMeta(chat, now: F.now), "chat", "no age without posted_at")
        XCTAssertEqual(ProjectFeedFormat.fileName(chat), "Hero: slate flat-lay")
        let bare = ProjectFile(blobID: "b3", contentType: "application/vnd.openxmlformats-officedocument",
                               source: .item(num: 1), postedAt: nil)
        XCTAssertEqual(ProjectFeedFormat.fileName(bare), "File")
        XCTAssertEqual(ProjectFeedFormat.fileExtension(bare), "FILE", "an unreadable subtype is not a label")
        XCTAssertEqual(ProjectFeedFormat.fileExtension(ProjectFile(blobID: "b4", contentType: "application/zip",
                                                                   source: .item(num: 1), postedAt: nil)), "ZIP")
    }
}
