import XCTest
@testable import MatronJournal

final class LegacyStoreFileMoveTests: XCTestCase {
    private var dir: URL!
    private var legacy: URL { dir.appendingPathComponent("alice.sqlite") }
    private var target: URL { dir.appendingPathComponent("alice.d7.sqlite") }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("legacy-move-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    private func write(_ path: String, _ text: String) {
        XCTAssertTrue(fm.createFile(atPath: path, contents: Data(text.utf8)))
    }

    private func read(_ path: String) -> String? {
        fm.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    private struct MoveFailed: Error {}

    func test_movesTheDatabaseWithItsSideFiles() {
        write(legacy.path, "main")
        write(legacy.path + "-wal", "wal")
        write(legacy.path + "-shm", "shm")

        XCTAssertEqual(LegacyStoreFileMove.adopt(legacy: legacy, target: target), target)

        XCTAssertEqual(read(target.path), "main")
        XCTAssertEqual(read(target.path + "-wal"), "wal")
        XCTAssertEqual(read(target.path + "-shm"), "shm")
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(fm.fileExists(atPath: legacy.path + suffix), "old \(suffix) left behind")
        }
    }

    func test_movesTheMainFileLast() {
        write(legacy.path, "main")
        write(legacy.path + "-wal", "wal")
        write(legacy.path + "-shm", "shm")
        var order: [String] = []

        LegacyStoreFileMove.adopt(legacy: legacy, target: target, move: { from, to in
            order.append(URL(fileURLWithPath: from).lastPathComponent)
            try FileManager.default.moveItem(atPath: from, toPath: to)
        })

        XCTAssertEqual(order.last, "alice.sqlite", "the main file moves after its -wal and -shm")
        XCTAssertEqual(order.count, 3)
    }

    /// The app stopped after the -wal moved but before the main file did.
    /// The next launch finishes the move instead of opening the new name
    /// without its log.
    func test_finishesAnInterruptedMove() {
        write(legacy.path, "main")
        write(target.path + "-wal", "wal")
        write(legacy.path + "-shm", "shm")

        XCTAssertEqual(LegacyStoreFileMove.adopt(legacy: legacy, target: target), target)

        XCTAssertEqual(read(target.path), "main")
        XCTAssertEqual(read(target.path + "-wal"), "wal")
        XCTAssertEqual(read(target.path + "-shm"), "shm")
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
    }

    /// The main file fails to move after its -wal did: the -wal goes back
    /// beside it and the caller opens the old file, whole, for now.
    func test_aFailedMove_putsTheSideFilesBackAndOpensTheOldFile() {
        write(legacy.path, "main")
        write(legacy.path + "-wal", "wal")
        write(legacy.path + "-shm", "shm")

        let opened = LegacyStoreFileMove.adopt(legacy: legacy, target: target, move: { from, to in
            if from == self.legacy.path { throw MoveFailed() }
            try FileManager.default.moveItem(atPath: from, toPath: to)
        })

        XCTAssertEqual(opened, legacy)
        XCTAssertEqual(read(legacy.path), "main")
        XCTAssertEqual(read(legacy.path + "-wal"), "wal")
        XCTAssertEqual(read(legacy.path + "-shm"), "shm")
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(fm.fileExists(atPath: target.path + suffix), "new \(suffix) left behind")
        }

        // The next launch tries again and succeeds.
        XCTAssertEqual(LegacyStoreFileMove.adopt(legacy: legacy, target: target), target)
        XCTAssertEqual(read(target.path + "-wal"), "wal")
    }

    /// A failed side-file move stops the move: nothing after it runs.
    func test_aFailedSideFileMove_stopsBeforeTheMainFile() {
        write(legacy.path, "main")
        write(legacy.path + "-wal", "wal")
        var tried: [String] = []

        let opened = LegacyStoreFileMove.adopt(legacy: legacy, target: target, move: { from, _ in
            tried.append(URL(fileURLWithPath: from).lastPathComponent)
            throw MoveFailed()
        })

        XCTAssertEqual(opened, legacy)
        XCTAssertEqual(tried, ["alice.sqlite-wal"])
        XCTAssertEqual(read(legacy.path), "main")
        XCTAssertEqual(read(legacy.path + "-wal"), "wal")
    }

    /// The main file fails to move and the -wal cannot be put back either:
    /// neither file opens (the caller uses an in-memory database), nothing
    /// is deleted, and the next launch finishes the move.
    func test_aFailedRollback_opensNeitherFile() {
        write(legacy.path, "main")
        write(legacy.path + "-wal", "wal")

        let opened = LegacyStoreFileMove.adopt(legacy: legacy, target: target, move: { from, to in
            if from == self.legacy.path { throw MoveFailed() }
            if to == self.legacy.path + "-wal" { throw MoveFailed() }
            try FileManager.default.moveItem(atPath: from, toPath: to)
        })

        XCTAssertNil(opened, "the old file without its -wal must not open")
        XCTAssertEqual(read(legacy.path), "main")
        XCTAssertEqual(read(target.path + "-wal"), "wal")

        XCTAssertEqual(LegacyStoreFileMove.adopt(legacy: legacy, target: target), target)
        XCTAssertEqual(read(target.path), "main")
        XCTAssertEqual(read(target.path + "-wal"), "wal")
    }

    func test_noOldFile_opensTheNewName() {
        XCTAssertEqual(LegacyStoreFileMove.adopt(legacy: legacy, target: target), target)
    }

    func test_aDatabaseAtTheNewName_isNeverOverwritten() {
        write(legacy.path, "old")
        write(target.path, "new")

        XCTAssertEqual(LegacyStoreFileMove.adopt(legacy: legacy, target: target), target)

        XCTAssertEqual(read(target.path), "new")
        XCTAssertEqual(read(legacy.path), "old")
    }
}
