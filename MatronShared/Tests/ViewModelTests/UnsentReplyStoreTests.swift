import XCTest
import MatronModels
@testable import MatronViewModels

@MainActor
final class UnsentReplyStoreTests: XCTestCase {
    private func temporaryDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func stage(_ name: String) throws -> StagedAttachment {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())-\(name)")
        try Data([1]).write(to: source)
        return try StagedAttachment.stage(moving: source, filename: name)
    }

    /// At launch, staged files no saved box refers to (left by a crash
    /// between staging and saving) are deleted; the rest stay.
    func testSweepDeletesOnlyFilesNoBoxRefersTo() throws {
        let previous = StagedAttachment.stagingDirectory
        StagedAttachment.useStagingDirectory(temporaryDirectory("staging"))
        defer { StagedAttachment.useStagingDirectory(previous) }
        let store = UnsentReplyStore(directory: temporaryDirectory("unsent"))
        let kept = try stage("kept.png")
        let sending = try stage("sending.m4a")
        let orphan = try stage("orphan.png")
        store.save(UnsentReply(attachments: [kept]), for: .item("it_1"), epoch: store.epoch)
        store.beginSend("local-1", UnsentReply(attachments: [sending]), for: .conversation("c1"), epoch: store.epoch)

        UnsentReplyStore(directory: store.directory).sweepOrphans()

        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sending.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.url.path))
    }

    /// An id with characters a file name can't hold still gets its own box.
    func testIdsAreSafeFileNames() {
        let store = UnsentReplyStore(directory: temporaryDirectory("unsent"))
        store.save(UnsentReply(text: "a"), for: .conversation("../x/y"), epoch: store.epoch)
        store.save(UnsentReply(text: "b"), for: .conversation("x/y"), epoch: store.epoch)
        let reread = UnsentReplyStore(directory: store.directory)
        XCTAssertEqual(reread.reply(for: .conversation("../x/y")).text, "a")
        XCTAssertEqual(reread.reply(for: .conversation("x/y")).text, "b")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count, 2)
    }

    /// An empty box leaves no file behind.
    func testAnEmptyBoxDeletesItsFile() {
        let store = UnsentReplyStore(directory: temporaryDirectory("unsent"))
        store.save(UnsentReply(text: "a"), for: .item("it_1"), epoch: store.epoch)
        store.save(UnsentReply(), for: .item("it_1"), epoch: store.epoch)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [])
    }
}
