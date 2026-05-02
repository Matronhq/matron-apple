import Foundation

public enum AppGroup {
    public static let identifier = "group.chat.matron"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public static func cryptoStorePath(in container: URL) -> URL {
        container.appendingPathComponent("crypto-store")
    }

    public static func searchDBPath(in container: URL) -> URL {
        container.appendingPathComponent("matron-search.sqlite")
    }
}
