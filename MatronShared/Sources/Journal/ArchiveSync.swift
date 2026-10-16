import Foundation
import os

/// One change in the journal's archive feed (protocol "Archived
/// conversations"): a conversation archived at `archivedAt` (ms), or
/// unarchived when that is `nil`. `auto` is true when the journal's idle
/// sweep archived it rather than the user.
public struct ArchiveChange: Equatable, Sendable {
    public var convoID: String
    public var archivedAt: Int64?
    public var auto: Bool

    public init(convoID: String, archivedAt: Int64?, auto: Bool = false) {
        self.convoID = convoID
        self.archivedAt = archivedAt
        self.auto = auto
    }

    /// One `{convo_id, archived_at, auto}` object, or `nil` when it lacks
    /// an id or carries an `archived_at` that is neither a number nor null.
    static func decode(_ raw: Any) -> ArchiveChange? {
        guard let obj = raw as? [String: Any], let id = obj["convo_id"] as? String, !id.isEmpty else { return nil }
        let archivedAt: Int64?
        switch obj["archived_at"] {
        case is NSNull: archivedAt = nil
        case let number as NSNumber where !(number === kCFBooleanTrue || number === kCFBooleanFalse):
            archivedAt = number.int64Value
        default: return nil
        }
        return ArchiveChange(convoID: id, archivedAt: archivedAt, auto: obj["auto"] as? Bool ?? false)
    }
}

/// `{changes, at}`: what `hello_ok.archive`, an `archive` frame and
/// `GET /archive` carry. `at` is the value to send as `archive_since` next
/// time.
public struct ArchiveDelta: Equatable, Sendable {
    public var changes: [ArchiveChange]
    public var at: Int64

    public init(changes: [ArchiveChange], at: Int64) {
        self.changes = changes
        self.at = at
    }

    /// `nil` when `raw` is not an object with a `changes` array — a
    /// journal without archiving sends no `archive` key at all. Malformed
    /// changes are dropped; a missing or bad `at` reads as 0.
    public static func decode(_ raw: Any?) -> ArchiveDelta? {
        guard let obj = raw as? [String: Any], let changes = obj["changes"] as? [Any] else { return nil }
        let at = (obj["at"] as? NSNumber).map(\.int64Value).flatMap { $0 >= 0 ? $0 : nil } ?? 0
        return ArchiveDelta(changes: changes.compactMap(ArchiveChange.decode), at: at)
    }
}

/// `POST /archive`. A protocol so `ArchiveSync` tests fake the journal.
public protocol ArchiveWriting: Sendable {
    /// Archives (or unarchives) up to `ArchiveSync.batchLimit` ids at once.
    func setArchived(_ convoIDs: [String], archived: Bool) async throws
}

extension JournalAPI: ArchiveWriting {
    public func setArchived(_ convoIDs: [String], archived: Bool) async throws {
        _ = try await request(path: "/archive", method: "POST",
                              body: ["convo_ids": convoIDs, "archived": archived])
    }
}

/// The user's archived conversations, kept in step with the journal.
///
/// The local mirror's `archived_at` column is what the apps read. On a
/// journal that syncs the archive it is a cache of the journal's set, kept
/// current by `hello_ok.archive` and live `archive` frames, and every
/// Archive/Unarchive is also sent with `POST /archive`. A journal without
/// archiving never answers `archive_since`, and the archive stays on this
/// device, as `hidden` did.
///
/// The cursor is the store's `archive_since` meta value. No cursor means
/// this device has not synced the archive yet: the hello asks for the whole
/// set, the ids archived only here (the old `hidden` rows, moved over by a
/// migration) are carried over to the journal once, and only then is the
/// cursor stored, so a carry-over that fails is tried again next connect.
///
/// Writes go out one `POST` at a time, always with the latest choice for
/// each conversation, so the journal ends where the user did. A refused
/// write puts the row back, but only while it is still the user's latest
/// choice.
public actor ArchiveSync {
    /// The journal takes at most this many ids per `POST /archive`.
    public static let batchLimit = 500

    private let store: JournalStore
    private let writer: any ArchiveWriting
    private let now: @Sendable () -> Date
    /// Whether this journal syncs the archive: learnt from each `hello_ok`,
    /// and assumed from a stored cursor until the first one, so an Archive
    /// tapped before the socket is up still reaches a journal this device
    /// has synced with.
    public private(set) var syncsWithJournal: Bool
    /// The state the user last chose for each conversation whose write has
    /// not landed yet.
    private var wanted: [String: Bool] = [:]
    /// The first sync's carry-over still to send: the ids archived only on
    /// this device, and the cursor to store once they are on the journal.
    private var carryOver: (ids: [String], at: Int64)?
    /// The one task that sends: the carry-over first, then the user's
    /// choices. One sender, so no two `POST`s for a conversation race.
    private var worker: Task<Void, Never>?
    private static let logger = Logger(subsystem: "chat.matron", category: "archive-sync")

    public init(store: JournalStore, writer: any ArchiveWriting, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.writer = writer
        self.now = now
        syncsWithJournal = (try? store.archiveSince()) != nil
    }

    /// The `archive_since` to send in `hello`: the stored cursor, or 0 for
    /// the whole set.
    public nonisolated func helloArchiveSince() -> Int64 {
        (try? store.archiveSince()) ?? 0
    }

    /// Archive or Unarchive, from the user. Shown at once; sent to the
    /// journal when it syncs the archive.
    public func setArchived(_ convoIDs: [String], archived: Bool) {
        guard !convoIDs.isEmpty else { return }
        do {
            try store.setArchived(convoIDs, archived: archived, now: now())
        } catch {
            Self.logger.error("archive write failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard syncsWithJournal else { return }
        for id in convoIDs { wanted[id] = archived }
        startWorker()
    }

    /// `hello_ok`'s `archive`, or `nil` when the journal sent none (it does
    /// not sync the archive: the archive stays on this device).
    public func applyHello(_ delta: ArchiveDelta?) {
        guard let delta else {
            syncsWithJournal = false
            return
        }
        syncsWithJournal = true
        let synced = (try? store.archiveSince()) != nil
        if synced {
            apply(delta)
            return
        }
        // First sync on this device: adopt the journal's set, keep what is
        // archived only here, and send that over before storing a cursor.
        do {
            let toImport = try store.adoptArchiveSet(delta.changes.filter { wanted[$0.convoID] == nil })
            carryOver = (toImport, delta.at)
        } catch {
            Self.logger.error("archive adopt failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        startWorker()
    }

    /// An `archive` frame, or `hello_ok`'s changes since the stored cursor.
    /// A conversation with a write of the user's still going out keeps the
    /// user's choice: that write is what the journal will end on.
    public func apply(_ delta: ArchiveDelta) {
        syncsWithJournal = true
        do {
            try store.applyArchiveChanges(delta.changes.filter { wanted[$0.convoID] == nil }, advancingSinceTo: delta.at)
        } catch {
            Self.logger.error("archive frame not applied: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startWorker() {
        if worker == nil { worker = Task { await self.drain() } }
    }

    /// Sends the carry-over, then the pending choices, one batch of
    /// conversations wanting the same state at a time, until none is left.
    private func drain() async {
        defer { worker = nil }
        while true {
            if let pending = carryOver {
                carryOver = nil
                await sendCarryOver(pending)
            } else if let first = wanted.first {
                await send(state: first.value)
            } else {
                return
            }
        }
    }

    /// A conversation the user has changed since is left to the user's own
    /// write, which follows.
    private func sendCarryOver(_ pending: (ids: [String], at: Int64)) async {
        do {
            for start in stride(from: 0, to: pending.ids.count, by: Self.batchLimit) {
                let batch = pending.ids[start..<min(start + Self.batchLimit, pending.ids.count)]
                    .filter { wanted[$0] == nil }
                if !batch.isEmpty { try await writer.setArchived(batch, archived: true) }
            }
            try store.setArchiveSince(pending.at)
        } catch {
            Self.logger.warning("archive carry-over failed, retried next connect: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func send(state: Bool) async {
        let batch = Array(wanted.filter { $0.value == state }.keys.sorted().prefix(Self.batchLimit))
        do {
            try await writer.setArchived(batch, archived: state)
            for id in batch where wanted[id] == state { wanted[id] = nil }
        } catch {
            Self.logger.warning("POST /archive failed: \(error.localizedDescription, privacy: .public)")
            let refused = batch.filter { wanted[$0] == state }
            for id in refused { wanted[id] = nil }
            try? store.setArchived(refused, archived: !state, now: now())
        }
    }

    /// Returns once every write already chosen has been sent or refused.
    /// For tests.
    func waitUntilIdle() async {
        while let task = worker { await task.value }
    }
}
