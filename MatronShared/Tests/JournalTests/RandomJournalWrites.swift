import Foundation
@testable import MatronJournal

/// A small, seedable generator (SplitMix64), so a failing random sequence
/// can be replayed exactly from the seed in the failure message.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Drives a `JournalStore` through a random sequence of its real write
/// APIs: the calls the sync engine makes to apply live frames, catch-up
/// batches, snapshots and history pages, plus the local writes (hide,
/// mute, placeholder rows, the tombstone sweeps, the outbox) and the
/// occasional wipe.
///
/// The values are drawn from deliberately small pools (a dozen ids, a few
/// timestamps a second apart, a handful of `last_seq` values in snapshots)
/// so the interesting cases happen often: ties in the chat-list order,
/// rows that move between top level, child and hidden, rooms that gain
/// and lose participants, tool output crossing its 24 h TTL.
struct RandomJournalWrites {
    let store: JournalStore
    var rng: SeededGenerator

    /// The simulated wall clock every write and every TTL check uses.
    /// Advances a little per step, and sometimes by most of a day.
    private(set) var now = Date(timeIntervalSince1970: 1_900_000_000)
    /// The next live journal seq. Starts high so history pages
    /// (`insertHistory`) can use the seqs below it without colliding.
    private var nextSeq: Int64 = 1_000_000
    private var nextHistorySeq: Int64 = 1

    static let convoIDs = (1...12).map { "c\($0)" }
    /// Conversations no journal frame ever touches: they exist only through
    /// snapshots and placeholder rows, so their `last_seq` and activity time
    /// come from small pools and often tie exactly, the case where the
    /// chat-list order falls back to rowid.
    static let quietIDs = (1...6).map { "q\($0)" }
    static let states = ["running", "waiting", "done"]
    static let ownSender = "user:alice"

    init(store: JournalStore, seed: UInt64) {
        self.store = store
        self.rng = SeededGenerator(seed: seed)
    }

    /// Runs one random write and returns a short description of it, for
    /// the failure message. Every call commits at most one transaction.
    @discardableResult
    mutating func step() throws -> String {
        now = now.addingTimeInterval(Double(Int.random(in: 0...3, using: &rng)))
        if Int.random(in: 0..<40, using: &rng) == 0 {
            // A jump of most of a day, so live tool output crosses the TTL.
            now = now.addingTimeInterval(Double(Int.random(in: 20...26, using: &rng)) * 3600)
        }
        switch Int.random(in: 0..<100, using: &rng) {
        case 0..<35:
            let e = event()
            try store.applyJournal(e, now: now)
            return "applyJournal \(e.type) \(e.convoID)"
        case 35..<50:
            let events = (0..<Int.random(in: 1...6, using: &rng)).map { _ in event() }
            _ = try store.applyJournalBatch(events, now: now)
            return "applyJournalBatch \(events.count)"
        case 50..<57:
            let rows = summaries()
            try store.refreshSummaries(rows)
            return "refreshSummaries \(rows.count)"
        case 57..<60:
            let rows = summaries()
            try store.applyColdSnapshot(rows, headSeq: nextSeq - 1)
            return "applyColdSnapshot \(rows.count)"
        case 60..<66:
            let events = (0..<Int.random(in: 1...4, using: &rng)).map { _ in historyEvent() }
            try store.insertHistory(events, now: now)
            return "insertHistory \(events.count)"
        case 66..<72:
            let id = anyConvoID()
            let archived = Bool.random(using: &rng)
            try store.setArchived([id], archived: archived, now: now)
            return "setArchived \(archived) \(id)"
        case 72..<76:
            let id = convoID()
            try store.setMuted(Bool.random(using: &rng), convoID: id)
            return "setMuted \(id)"
        case 76..<80:
            let id = anyConvoID()
            try store.ensureConversation(id: id, title: "Placeholder \(id)", now: now)
            return "ensureConversation \(id)"
        case 80..<84:
            try store.purgeExpiredToolOutputSnippets(now: now)
            return "purgeExpiredToolOutputSnippets"
        case 84..<86:
            try store.applyRetention(now: now.addingTimeInterval(31 * 24 * 3600))
            return "applyRetention"
        case 86..<92:
            try store.outboxInsert(localID: UUID().uuidString, convoID: convoID(), body: "queued", now: now)
            return "outboxInsert"
        case 92..<94:
            try store.wipe()
            return "wipe"
        default:
            // An own-sender text: also confirms (deletes) a queued outbox
            // row in the same transaction when the body matches.
            let e = event(type: JournalEventType.text, sender: Self.ownSender, payload: ["body": "queued"])
            try store.applyJournal(e, now: now)
            return "applyJournal own text \(e.convoID)"
        }
    }

    // MARK: Values

    private mutating func convoID() -> String {
        Self.convoIDs.randomElement(using: &rng)!
    }

    private mutating func anyConvoID() -> String {
        (Self.convoIDs + Self.quietIDs).randomElement(using: &rng)!
    }

    /// An event timestamp: usually "now" give or take a few seconds (so
    /// activity times tie), sometimes a day or more old (so tool output
    /// lands already expired, or expires soon).
    private mutating func eventTS() -> Date {
        if Int.random(in: 0..<6, using: &rng) == 0 {
            return now.addingTimeInterval(-Double(Int.random(in: 23...49, using: &rng)) * 3600)
        }
        return now.addingTimeInterval(-Double(Int.random(in: 0...2, using: &rng)))
    }

    private mutating func event(type: String? = nil, sender: String? = nil,
                                payload: [String: Any]? = nil) -> JournalEvent {
        let type = type ?? [
            JournalEventType.text, JournalEventType.text, JournalEventType.toolOutput,
            JournalEventType.sessionStatus, JournalEventType.readMarker, JournalEventType.convoMeta,
            JournalEventType.convoMeta, JournalEventType.diff,
        ].randomElement(using: &rng)!
        let payload = payload ?? self.payload(for: type)
        let seq = nextSeq
        nextSeq += 1
        return JournalEvent(
            seq: seq, convoID: convoID(), ts: eventTS(),
            sender: sender ?? (Bool.random(using: &rng) ? "agent:box-2" : Self.ownSender), type: type,
            payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    private mutating func historyEvent() -> JournalEvent {
        let type = [JournalEventType.text, JournalEventType.toolOutput].randomElement(using: &rng)!
        let seq = nextHistorySeq
        nextHistorySeq += 1
        return JournalEvent(
            seq: seq, convoID: convoID(), ts: eventTS(), sender: "agent:box-2", type: type,
            payloadData: try! JSONSerialization.data(withJSONObject: payload(for: type)))
    }

    private mutating func payload(for type: String) -> [String: Any] {
        switch type {
        case JournalEventType.toolOutput:
            var p: [String: Any] = ["command": "make \(Int.random(in: 1...3, using: &rng))",
                                    "snippet": "building…"]
            if Bool.random(using: &rng) { p["live_log"] = true }
            return p
        case JournalEventType.sessionStatus:
            return ["state": Self.states.randomElement(using: &rng)!]
        case JournalEventType.readMarker:
            return ["up_to_seq": Int.random(in: 999_990...Int(nextSeq), using: &rng)]
        case JournalEventType.convoMeta:
            var p: [String: Any] = [:]
            if Bool.random(using: &rng) { p["title"] = "Title \(Int.random(in: 1...4, using: &rng))" }
            if Int.random(in: 0..<3, using: &rng) == 0 { p["parent_convo_id"] = convoID() }
            if Bool.random(using: &rng) { p["agent_device_id"] = Int.random(in: 1...3, using: &rng) }
            switch Int.random(in: 0..<4, using: &rng) {
            case 0: p["participant_convos"] = [String]()
            case 1: p["participant_convos"] = [convoID(), convoID()]
                p["participants"] = [1, 2]
            default: break
            }
            return p
        case JournalEventType.diff:
            return ["path": "a.swift", "snippet": "+1 −0"]
        default:
            return ["body": "message \(Int.random(in: 1...5, using: &rng))"]
        }
    }

    private mutating func summaries() -> [ConvoSummaryDTO] {
        let ids = (Self.convoIDs + Self.quietIDs).shuffled(using: &rng).prefix(Int.random(in: 1...6, using: &rng))
        return ids.map { id in
            let roomKnown = Int.random(in: 0..<3, using: &rng) == 0
            return ConvoSummaryDTO(
                id: id, title: "Snapshot \(id)", sessionState: Self.states.randomElement(using: &rng)!,
                lastSeq: Self.quietIDs.contains(id)
                    ? Int64.random(in: 0...2, using: &rng)
                    : Int64.random(in: 999_990...1_000_000, using: &rng),
                snippet: "from snapshot",
                createdAt: Int64.random(in: 0...3, using: &rng),
                lastTS: Bool.random(using: &rng) ? nil : Int64(now.timeIntervalSince1970 * 1000)
                    - Int64.random(in: 0...2, using: &rng) * 1000,
                parentConvoID: Int.random(in: 0..<4, using: &rng) == 0 ? convoID() : nil,
                agentDeviceID: Bool.random(using: &rng) ? Int64.random(in: 1...3, using: &rng) : nil,
                participants: roomKnown ? [1, 2] : nil,
                participantConvos: roomKnown ? [convoID()] : nil,
                missionID: Bool.random(using: &rng) ? "m1" : nil,
                missionIDKnown: Bool.random(using: &rng))
        }
    }
}
