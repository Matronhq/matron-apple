import XCTest
@testable import MatronChat

final class MediaDiskCacheTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// A clock the test moves by hand.
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func makeCache(clock: Clock = Clock(), byteLimit: Int = 1_000,
                           maxEntryBytes: Int = 1_000) -> MediaDiskCache {
        MediaDiskCache(directory: directory, maxAge: 7 * 24 * 3600, byteLimit: byteLimit,
                       maxEntryBytes: maxEntryBytes, now: { clock.now })
    }

    private func bytes(_ count: Int, _ fill: UInt8 = 1) -> Data { Data(repeating: fill, count: count) }

    func testStoredBytesReadBackAcrossInstances() async {
        await makeCache().store(Data("PNG".utf8), for: "blob-1")
        let data = await makeCache().data(for: "blob-1")
        XCTAssertEqual(data, Data("PNG".utf8))
        let missing = await makeCache().data(for: "blob-2")
        XCTAssertNil(missing)
    }

    func testFileNamesDoNotContainTheBlobID() async throws {
        await makeCache().store(Data("PNG".utf8), for: "blob-secret-name")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.count, 1)
        XCTAssertFalse(names[0].contains("blob"))
    }

    func testEntryExpiresAfterSevenDaysUnused() async {
        let clock = Clock()
        let cache = makeCache(clock: clock)
        await cache.store(Data("PNG".utf8), for: "blob-1")
        clock.now += 6 * 24 * 3600
        let early = await cache.data(for: "blob-1")
        XCTAssertNotNil(early, "still fresh at six days")
        // The read renewed it: six more days is still inside the week.
        clock.now += 6 * 24 * 3600
        let renewed = await cache.data(for: "blob-1")
        XCTAssertNotNil(renewed)
        clock.now += 8 * 24 * 3600
        let expired = await cache.data(for: "blob-1")
        XCTAssertNil(expired)
    }

    func testOverLimitEvictsLeastRecentlyUsed() async {
        let clock = Clock()
        let cache = makeCache(clock: clock, byteLimit: 1_000)
        await cache.store(bytes(400), for: "a")
        clock.now += 60
        await cache.store(bytes(400), for: "b")
        clock.now += 60
        _ = await cache.data(for: "a")   // a is now the most recent
        clock.now += 60
        await cache.store(bytes(400), for: "c")
        let a = await cache.data(for: "a")
        let b = await cache.data(for: "b")
        let c = await cache.data(for: "c")
        XCTAssertNotNil(a)
        XCTAssertNil(b, "least recently used goes first")
        XCTAssertNotNil(c)
    }

    func testBlobOverEntryLimitIsNotStored() async {
        let cache = makeCache(maxEntryBytes: 100)
        await cache.store(bytes(101), for: "big")
        let data = await cache.data(for: "big")
        XCTAssertNil(data)
    }

    func testRemoveAllDeletesFilesAndStopsLaterWrites() async {
        let cache = makeCache()
        await cache.store(Data("PNG".utf8), for: "blob-1")
        await cache.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        // A fetch that was in flight at sign-out finishes afterwards.
        await cache.store(Data("PNG".utf8), for: "blob-2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let data = await makeCache().data(for: "blob-1")
        XCTAssertNil(data)
    }

    func testDirectoryIsExcludedFromBackup() async throws {
        await makeCache().store(Data("PNG".utf8), for: "blob-1")
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testTestRunsUseAThrowawayRoot() {
        XCTAssertTrue(MediaDiskCache.rootDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    func testAccountDirectoryDoesNotContainTheAccountID() {
        let url = MediaDiskCache.directory(forAccount: "alice")
        XCTAssertFalse(url.path.contains("alice"))
        XCTAssertNotEqual(url, MediaDiskCache.directory(forAccount: "bob"))
    }
}
