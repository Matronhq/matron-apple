import Foundation

public enum StoragePaths {

    #if os(iOS)
    public static let appGroupIdentifier = "group.chat.matron"

    /// Force-unwrapped because every shipped iOS build has the App Group
    /// entitlement; the only environment in which this is `nil` is the SPM
    /// test runner, which never touches this property.
    public static let groupContainer: URL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
    )!

    public static let cryptoStorePath = groupContainer.appendingPathComponent("crypto-store")
    public static let searchDBPath   = groupContainer.appendingPathComponent("matron-search.sqlite")

    /// Pure helper for tests / fallback paths.
    public static func cryptoStore(in container: URL) -> URL {
        container.appendingPathComponent("crypto-store")
    }
    public static func searchDB(in container: URL) -> URL {
        container.appendingPathComponent("matron-search.sqlite")
    }

    #elseif os(macOS)
    public static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("chat.matron.mac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static let cryptoStorePath = appSupport.appendingPathComponent("crypto-store")
    public static let searchDBPath   = appSupport.appendingPathComponent("matron-search.sqlite")
    #endif
}
