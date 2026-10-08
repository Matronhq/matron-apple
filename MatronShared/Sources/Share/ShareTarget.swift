import Foundation

/// A conversation the share sheet can send into.
public struct ShareTarget: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    /// A short second line, such as the name of the box the conversation
    /// runs on. Nil when there is nothing worth saying.
    public let detail: String?
    public let isCoordinator: Bool
    public let lastActivity: Date?

    public init(id: String, title: String, detail: String? = nil,
                isCoordinator: Bool = false, lastActivity: Date? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isCoordinator = isCoordinator
        self.lastActivity = lastActivity
    }
}

public enum ShareTargets {
    /// How many conversations the picker offers. The share sheet is for
    /// reaching something recent; anything older is found in the app.
    public static let limit = 300

    /// The picker's order: the Coordinator first, then newest activity
    /// first, conversations with no activity last. Ties keep a stable
    /// order by id so the list does not shuffle between two loads.
    public static func ordered(_ targets: [ShareTarget], limit: Int = ShareTargets.limit) -> [ShareTarget] {
        let sorted = targets.sorted { lhs, rhs in
            if lhs.isCoordinator != rhs.isCoordinator { return lhs.isCoordinator }
            switch (lhs.lastActivity, rhs.lastActivity) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.id < rhs.id
            }
        }
        return Array(sorted.prefix(limit))
    }

    /// Case- and accent-insensitive match on the title, every word of the
    /// query required. An empty query matches everything.
    public static func filter(_ targets: [ShareTarget], query: String) -> [ShareTarget] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return targets }
        return targets.filter { target in
            words.allSatisfy {
                target.title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}

/// The app's list of conversations, left where the share extension can
/// read it. The extension runs in its own process and may be opened with no
/// network, so the app writes what it already knows and the extension shows
/// that at once.
public enum ShareTargetsCache {
    struct File: Codable {
        var userID: String
        var targets: [ShareTarget]
    }

    static func url(in container: URL) -> URL {
        container.appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("targets.json")
    }

    public static func write(_ targets: [ShareTarget], userID: String, in container: URL) throws {
        let url = url(in: container)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(File(userID: userID, targets: targets))
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        // Readable from the first unlock on, like the session beside it:
        // the extension can be opened while the app is not running.
        try? (url as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
        #endif
    }

    /// The cached list for `userID`, or nil when there is none: nothing
    /// written yet, unreadable, or written for another account.
    public static func read(userID: String, in container: URL) -> [ShareTarget]? {
        guard let data = try? Data(contentsOf: url(in: container)),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.userID == userID else { return nil }
        return file.targets
    }

    /// Removes the list, for sign-out.
    public static func clear(in container: URL) {
        try? FileManager.default.removeItem(at: url(in: container))
    }
}
