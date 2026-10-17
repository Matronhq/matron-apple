import XCTest
@testable import MatronStorage

/// The fallback session file: kept out of backups, and owner-only on macOS.
final class FileSessionStoreTests: XCTestCase {
    private var root: URL!
    private var directory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-session-\(UUID().uuidString)", isDirectory: true)
        directory = root.appendingPathComponent("sessions", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func test_setGetDelete_roundTrips() throws {
        let store = FileSessionStore(directory: directory)
        try store.set("alice-session", forKey: "k")
        XCTAssertEqual(try store.get(key: "k"), "alice-session")
        try store.delete(key: "k")
        XCTAssertNil(try store.get(key: "k"))
    }

    func test_set_excludesTheDirectoryFromBackup() throws {
        try FileSessionStore(directory: directory).set("alice-session", forKey: "k")

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func test_set_excludesAnExistingDirectoryFromBackup() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try FileSessionStore(directory: directory).set("alice-session", forKey: "k")

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    #if os(macOS)
    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func test_set_makesTheFileAndDirectoryOwnerOnly() throws {
        try FileSessionStore(directory: directory).set("alice-session", forKey: "k")

        XCTAssertEqual(try permissions(directory.appendingPathComponent("k.json")), 0o600)
        XCTAssertEqual(try permissions(directory), 0o700)
    }

    func test_set_tightensAnExistingDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])

        try FileSessionStore(directory: directory).set("alice-session", forKey: "k")

        XCTAssertEqual(try permissions(directory), 0o700)
    }

    func test_get_tightensAFileWrittenByAnEarlierVersion() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("k.json")
        try "alice-session".write(to: legacy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: legacy.path)

        XCTAssertEqual(try FileSessionStore(directory: directory).get(key: "k"), "alice-session")
        XCTAssertEqual(try permissions(legacy), 0o600)
    }
    #endif
}
