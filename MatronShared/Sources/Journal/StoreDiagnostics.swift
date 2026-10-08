import Foundation

/// On-demand answers for Settings › Storage. Nothing here runs unless the
/// user opens that screen: the whole point of this work was to stop doing
/// store-sized reads on the launch path.
///
/// Presentation lives in `StorageSettingsRows` (`MatronDesignSystem`); this
/// type deliberately owns only the store reads plus the one formatter that
/// needs a clock, so the design system keeps no dependency on this module.
public enum StoreDiagnostics {
    public struct Sizes: Equatable, Sendable {
        /// `.sqlite` + `-wal` + `-shm` for the journal mirror.
        public let journalBytes: Int64
        /// The same three files for the FTS index.
        public let searchBytes: Int64
        public let eventCount: Int
        public let conversationCount: Int
        /// `meta.maintenance_last_run`, or `nil` when no sweep has finished
        /// on this device yet.
        public let lastMaintenance: Date?

        public init(journalBytes: Int64, searchBytes: Int64, eventCount: Int,
                    conversationCount: Int, lastMaintenance: Date?) {
            self.journalBytes = journalBytes
            self.searchBytes = searchBytes
            self.eventCount = eventCount
            self.conversationCount = conversationCount
            self.lastMaintenance = lastMaintenance
        }
    }

    /// Not `@MainActor`: this does file stats and two `COUNT(*)`s, and the
    /// caller is a SwiftUI `.task` that must not block a paint.
    public static func sizes(store: JournalStore, searchURL: URL?) async -> Sizes {
        let counts = (try? store.rowCounts()) ?? (events: 0, conversations: 0)
        return Sizes(
            journalBytes: fileGroupSize(store.databaseURL),
            searchBytes: fileGroupSize(searchURL),
            eventCount: counts.events,
            conversationCount: counts.conversations,
            lastMaintenance: try? store.maintenanceLastRun())
    }

    /// A SQLite database is three files in WAL mode; reporting only the main
    /// one understates a busy store by the whole write-ahead log.
    private static func fileGroupSize(_ url: URL?) -> Int64 {
        guard let url else { return 0 }
        let paths = [url.path, url.path + "-wal", url.path + "-shm"]
        return paths.reduce(into: Int64(0)) { total, path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else { return }
            total += size.int64Value
        }
    }

    /// "Never", or a relative time like "1 hour ago".
    public static func lastMaintenanceText(_ date: Date?, now: Date) -> String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
