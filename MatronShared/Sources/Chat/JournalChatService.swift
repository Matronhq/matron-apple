import Foundation
import MatronJournal
import MatronModels

public enum JournalChatError: Error, LocalizedError, Equatable {
    case creationNotSupported
    case mediaNotSupported
    case invalidPromptReference(String)

    public var errorDescription: String? {
        switch self {
        case .creationNotSupported:
            return "Creating conversations from the app needs server support (convo_create) — coming soon."
        case .mediaNotSupported:
            return "Attachments need the server's /media endpoint — coming soon."
        case .invalidPromptReference(let id):
            return "Can't answer this prompt — its reference (\"\(id)\") isn't a journal row."
        }
    }
}

/// ChatService over the local journal mirror. The chat list is a pure
/// read of the store; freshness is the sync engine's job.
public final class JournalChatService: ChatService, @unchecked Sendable {
    private let store: JournalStore
    private let engine: JournalSyncEngine
    private let coalesceInterval: Duration

    public init(store: JournalStore, engine: JournalSyncEngine, coalesceInterval: Duration = .milliseconds(250)) {
        self.store = store
        self.engine = engine
        self.coalesceInterval = coalesceInterval
    }

    public func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        let store = store
        let interval = coalesceInterval
        return AsyncThrowingStream { continuation in
            // A reconnect replay applies each missed journal frame in its
            // own store transaction, so a catch-up burst yields one
            // conversations snapshot per frame — rendered raw, the chat
            // list visibly pops row by row. Coalesce: the first snapshot
            // goes out immediately (instant paint from the local mirror),
            // then at most one per `interval`, always the newest. The
            // signal stream is a one-slot doorbell (`bufferingNewest(1)`)
            // over `inputs`, so every ring that lands while the pacer
            // sleeps collapses into one wake-up on the newest state — and,
            // unlike buffering the snapshots themselves, a conversations
            // burst can never crowd out a pending roster change.
            let inputs = SummaryInputs()
            let (signal, signalCont) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let producer = Task {
                for await records in store.conversationsStream() {
                    inputs.setRecords(records)
                    signalCont.yield(())
                }
                signalCont.finish()
            }
            // The roster is its own observation because a GRDB observation
            // only re-fires for the tables its fetch reads: a rename writes
            // `agent`, which the conversations fetch never touches, so
            // without this every open chip would keep the old label until
            // some unrelated conversation write happened to re-fire the
            // list. Roster-only, so it never `finish()`es the signal — the
            // conversations stream ending is what ends the summaries.
            let roster = Task {
                for await names in store.agentNamesStream() {
                    inputs.setBoxNames(names)
                    signalCont.yield(())
                }
            }
            // A tag-character override (Settings → Devices) writes only
            // UserDefaults — no journal record, no GRDB re-fire — so its
            // change notification rings the same doorbell to re-derive.
            let overridesWatch = Task {
                for await _ in NotificationCenter.default.notifications(named: BoxLetterOverrides.didChange) {
                    signalCont.yield(())
                }
            }
            let consumer = Task {
                for await _ in signal {
                    guard let records = inputs.records else { continue }
                    // The roster observation delivers its first value on a
                    // main-queue hop, which may land after the first
                    // conversations snapshot; read through so the very
                    // first paint still carries its chips.
                    let boxNames = inputs.boxNames ?? (try? store.agentNames()) ?? [:]
                    // Derived once per snapshot, not per row — the letters
                    // depend on the whole name set (common-prefix strip).
                    let boxLetters = SessionTag.boxLetters(
                        for: boxNames, overrides: BoxLetterOverrides.all())
                    continuation.yield(records.map { Self.summary(from: $0, boxNames: boxNames, boxLetters: boxLetters) })
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                producer.cancel()
                roster.cancel()
                overridesWatch.cancel()
                consumer.cancel()
            }
        }
    }

    /// `boxNames` is the id → name map of the user's agent boxes. The chip
    /// gate lives here: fewer than two boxes means no chip on any row.
    static func summary(from record: ConversationRecord, boxNames: [Int64: String], boxLetters: [Int64: String] = [:]) -> ChatSummary {
        let activityMS = record.lastActivityTS ?? (record.createdAt > 0 ? record.createdAt : nil)
        // The bridge bakes a `[bc] ` session short into earned titles —
        // peel it off so rows show the clean title and restyle the short
        // as part of the leading `A:bc` tag.
        let (sessionShort, cleanTitle) = SessionTag.splitTitle(record.title)
        let boxName = Self.boxName(for: record, boxNames: boxNames)
        let roomTags = Self.roomTags(for: record, boxNames: boxNames, boxLetters: boxLetters)
        return ChatSummary(
            id: record.id,
            title: cleanTitle.isEmpty ? record.id : cleanTitle,
            bot: BotIdentity(matrixID: "agent:claude", displayName: "Claude", avatarURL: nil),
            lastActivity: activityMS.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            unreadCount: record.unreadCount,
            snippet: record.snippet,
            parentConvoID: record.parentConvoID,
            boxName: boxName,
            sessionShort: sessionShort,
            // Same gate as the chip: a letter only means something when
            // there is more than one box to tell apart.
            boxShort: boxName != nil ? record.agentDeviceID.flatMap { boxLetters[$0] } : nil,
            roomBoxNames: roomTags.map(\.name),
            roomBoxShorts: roomTags.map(\.letter)
        )
    }

    /// The chip rule for a single conversation: named only when the user has
    /// two or more boxes AND this conversation's box resolves. Pure, so it
    /// is unit-testable without a live sync engine.
    static func boxName(for record: ConversationRecord?, boxNames: [Int64: String]) -> String? {
        guard boxNames.count >= 2, let id = record?.agentDeviceID else { return nil }
        return boxNames[id]
    }

    /// The tag for a multi-agent room: every participant id resolved to its
    /// box name AND display letter, deduped by name in journal order. Same
    /// two-box gate as `boxName(for:)` — one box means nothing to
    /// disambiguate. Empty unless at least two DISTINCT boxes resolve (a
    /// local room's two ends share one box, and a participant whose device
    /// was revoked resolves to nothing), so rows can fall back to the
    /// single-box tag.
    static func roomTags(
        for record: ConversationRecord?,
        boxNames: [Int64: String],
        boxLetters: [Int64: String]
    ) -> [(name: String, letter: String)] {
        guard boxNames.count >= 2, let ids = record?.participantIDs, ids.count >= 2 else { return [] }
        var seen = Set<String>()
        var tags: [(name: String, letter: String)] = []
        for id in ids {
            guard let name = boxNames[id], seen.insert(name).inserted else { continue }
            tags.append((name: name, letter: boxLetters[id] ?? "?"))
        }
        return tags.count >= 2 ? tags : []
    }

    static func childSummary(from record: ConversationRecord) -> SubChatSummary {
        SubChatSummary(
            id: record.id,
            title: record.title.isEmpty ? record.id : record.title,
            isRunning: record.sessionState == "running"
        )
    }

    public func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        let store = store
        return AsyncStream { continuation in
            let producer = Task {
                for await records in store.childrenStream(of: parentConvoID) {
                    continuation.yield(records.map(Self.childSummary(from:)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    public func createChat(with botID: String) async throws -> String {
        throw JournalChatError.creationNotSupported
    }

    public func refresh() async throws {
        try await engine.waitUntilReady()
    }

    public func forceSnapshot() async throws {
        await engine.refreshSummaries()
    }

    public func mute(roomID: String) async throws {
        try store.setMuted(true, convoID: roomID)
    }

    public func leave(roomID: String) async throws {
        try store.setHidden(true, convoID: roomID)
    }
}

/// Latest value from each of the two observations feeding `chatSummaries()`,
/// written by their producer tasks and read by the paced consumer. Holding
/// the state here (rather than buffering it in the signal stream) is what
/// lets the doorbell coalesce to one slot without a conversations burst
/// dropping a roster change, or vice versa. `nil` means "hasn't delivered
/// yet", which the consumer distinguishes from an empty roster.
private final class SummaryInputs: @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [ConversationRecord]?
    private var _boxNames: [Int64: String]?

    var records: [ConversationRecord]? {
        lock.withLock { _records }
    }

    var boxNames: [Int64: String]? {
        lock.withLock { _boxNames }
    }

    func setRecords(_ records: [ConversationRecord]) {
        lock.withLock { _records = records }
    }

    func setBoxNames(_ names: [Int64: String]) {
        lock.withLock { _boxNames = names }
    }
}
