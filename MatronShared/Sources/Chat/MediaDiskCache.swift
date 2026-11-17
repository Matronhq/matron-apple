import Foundation
import CryptoKit

/// On-disk cache of media blobs, keyed by the journal's blob id.
///
/// Blob ids are immutable — the bytes behind one never change — so an entry
/// never goes stale; it only ages out. An entry is kept for `maxAge` after it
/// was last read or written (reading one renews it), and the whole cache is
/// held under `byteLimit` by evicting the least recently used entries first.
///
/// Without this, a chat's images lived only in that chat's in-memory LRU:
/// leaving the chat or relaunching the app fetched every image again. The
/// shared `URLCache` the API client goes through is too small to help (it
/// refuses any response over 5% of its disk size, which is most
/// screenshots).
///
/// One cache per signed-in account, in its own directory under Caches,
/// excluded from backups. Sign-out calls `removeAll()` on each live cache
/// and `removeAllOnDisk()` for anything left by earlier launches.
public actor MediaDiskCache {
    /// How long an entry stays after it was last used.
    public static let defaultMaxAge: TimeInterval = 7 * 24 * 60 * 60
    /// Total size the cache is held under.
    public static let defaultByteLimit: Int = {
        #if os(macOS)
        return 500 * 1024 * 1024
        #else
        return 250 * 1024 * 1024
        #endif
    }()
    /// Larger blobs (long videos, big PDFs) are not cached: one would push
    /// out hundreds of images.
    public static let defaultMaxEntryBytes: Int = 20 * 1024 * 1024

    private let directory: URL
    private let maxAge: TimeInterval
    private let byteLimit: Int
    private let maxEntryBytes: Int
    private let now: @Sendable () -> Date
    private let fileManager = FileManager.default

    /// Running total of the bytes on disk; nil until the first write scans
    /// the directory.
    private var totalBytes: Int?
    /// Set by `removeAll()`: a fetch that was in flight at sign-out must not
    /// write the previous account's image back to disk.
    private var isClosed = false

    public init(directory: URL,
                maxAge: TimeInterval = MediaDiskCache.defaultMaxAge,
                byteLimit: Int = MediaDiskCache.defaultByteLimit,
                maxEntryBytes: Int = MediaDiskCache.defaultMaxEntryBytes,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.maxAge = maxAge
        self.byteLimit = byteLimit
        self.maxEntryBytes = maxEntryBytes
        self.now = now
    }

    /// Root of every account's media cache, under the app's own folder in
    /// Caches: an unsandboxed (debug) Mac build shares `~/Library/Caches`
    /// with every other app.
    public static var rootDirectory: URL {
        #if DEBUG
        // The Mac unit tests run inside the unsandboxed app, so without this
        // a test that wipes the cache would wipe the developer's real one.
        // Same seam as `StoragePaths.appSupport`.
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("matron-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                .appendingPathComponent("MatronMedia", isDirectory: true)
        }
        #endif
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Matron", isDirectory: true)
            .appendingPathComponent("MatronMedia", isDirectory: true)
    }

    /// The directory for one account. Named by a hash so the account id
    /// does not appear in the file system.
    public static func directory(forAccount accountID: String) -> URL {
        rootDirectory.appendingPathComponent(hash(accountID), isDirectory: true)
    }

    /// Deletes every account's cache. Sign-out runs it after closing the
    /// live caches, to catch directories left by earlier launches.
    public static func removeAllOnDisk() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    /// The cached bytes for `blobRef`, or nil when absent or expired.
    /// A hit renews the entry's age.
    public func data(for blobRef: String) -> Data? {
        guard !isClosed else { return nil }
        let url = fileURL(for: blobRef)
        guard let modified = modificationDate(of: url) else { return nil }
        if now().timeIntervalSince(modified) > maxAge {
            let size = size(of: url) ?? 0
            if remove(url), let total = totalBytes { totalBytes = max(0, total - size) }
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
        return data
    }

    /// Stores `data` under `blobRef`, then evicts the oldest entries if the
    /// cache has grown past its limit.
    public func store(_ data: Data, for blobRef: String) {
        guard !isClosed, !data.isEmpty, data.count <= maxEntryBytes, data.count <= byteLimit else { return }
        guard prepareDirectory() else { return }
        var total = totalBytes ?? scan()
        let url = fileURL(for: blobRef)
        let existing = size(of: url) ?? 0
        // A failed atomic write leaves the old file in place, so the total
        // changes only once the write has landed.
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
        total += data.count - existing
        totalBytes = total
        if total > byteLimit { evict() }
    }

    /// Deletes this cache's files and stops it writing again. Sign-out.
    public func removeAll() {
        isClosed = true
        try? fileManager.removeItem(at: directory)
        totalBytes = 0
    }

    // MARK: - Private

    private func fileURL(for blobRef: String) -> URL {
        directory.appendingPathComponent(Self.hash(blobRef))
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func prepareDirectory() -> Bool {
        if fileManager.fileExists(atPath: directory.path) { return true }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }
        // Caches is already left out of backups; say so explicitly so a
        // future move of the directory can't quietly change that.
        for var url in [Self.rootDirectory, directory] {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return true
    }

    private struct Entry {
        let url: URL
        let size: Int
        let modified: Date
    }

    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Entry(url: url, size: values.fileSize ?? 0,
                         modified: values.contentModificationDate ?? .distantPast)
        }
    }

    /// Totals the directory, deleting expired entries on the way.
    private func scan() -> Int {
        let cutoff = now().addingTimeInterval(-maxAge)
        var total = 0
        for entry in entries() {
            if entry.modified < cutoff, remove(entry.url) { continue }
            total += entry.size
        }
        totalBytes = total
        return total
    }

    /// Deletes least recently used entries until the cache is at 90% of its
    /// limit, so the next few writes don't each trigger another pass.
    private func evict() {
        let target = byteLimit / 10 * 9
        let sorted = entries().sorted { $0.modified < $1.modified }
        var total = sorted.reduce(0) { $0 + $1.size }
        for entry in sorted where total > target {
            if remove(entry.url) { total -= entry.size }
        }
        totalBytes = total
    }

    /// True when the file is gone, so callers only count bytes actually
    /// reclaimed.
    @discardableResult
    private func remove(_ url: URL) -> Bool {
        (try? fileManager.removeItem(at: url)) != nil
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func size(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}
