import Foundation

public enum StoragePaths {

    #if os(iOS)
    public static let appGroupIdentifier = "group.chat.matron"

    /// Optional — `nil` when the App Group entitlement isn't provisioned
    /// (e.g. SPM test runner, or a build with `CODE_SIGNING_ALLOWED=NO` that
    /// strips the entitlement). Callers must handle the `nil` case; the
    /// previous force-unwrap was a footgun for any future code path that
    /// reaches here outside the entitled iOS app target.
    public static var groupContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    public static var cryptoStorePath: URL? { groupContainer?.appendingPathComponent("crypto-store") }
    public static var searchDBPath: URL?   { groupContainer?.appendingPathComponent("matron-search.sqlite") }

    /// Pure helper for tests / fallback paths.
    public static func cryptoStore(in container: URL) -> URL {
        container.appendingPathComponent("crypto-store")
    }
    public static func searchDB(in container: URL) -> URL {
        container.appendingPathComponent("matron-search.sqlite")
    }

    #elseif os(macOS)
    public static let appSupport: URL = {
        #if DEBUG
        // Test-only isolation seam. The Mac app is UNSANDBOXED, so it
        // resolves Application Support from the logged-in account — a
        // screenshot / UI-test run launched on the developer's own machine
        // would otherwise open the developer's REAL session and mirror
        // (and a `$HOME` launch-env override does NOT redirect it, because
        // `.applicationSupportDirectory` comes from the password database,
        // not `$HOME`). This override lets the marketing-screenshot harness
        // point the app at a throwaway container holding demo data. Never
        // set in a shipping build (DEBUG-gated) and unset in normal runs.
        if let override = ProcessInfo.processInfo.environment["MATRON_APP_SUPPORT_OVERRIDE"],
           !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Named after the (unified) bundle ID. Renamed from
        // `chat.matron.mac` with the bundle-ID unification — existing
        // installs start a fresh store and re-sign-in rather than
        // migrating, an accepted one-time cost while the tester pool is
        // the developer.
        let dir = base.appendingPathComponent("chat.matron.app")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static let cryptoStorePath = appSupport.appendingPathComponent("crypto-store")
    public static let searchDBPath   = appSupport.appendingPathComponent("matron-search.sqlite")
    #endif
}
