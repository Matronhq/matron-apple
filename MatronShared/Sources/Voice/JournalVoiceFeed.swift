import Foundation
import MatronJournal
import MatronModels

/// Markdown to speech, handed in by the app: the cleaner lives beside the
/// Markdown renderers (`SpeechCleaner` in MatronDesignSystem), which this
/// module never imports.
public struct VoiceTextMaker: Sendable {
    /// Level 1 when the bridge sent no spoken line.
    public var short: @Sendable (String) -> String
    /// Level 3: the message, about a minute a section.
    public var sections: @Sendable (String) -> [String]
    /// A question or title as it should be said.
    public var plain: @Sendable (String) -> String

    public init(short: @escaping @Sendable (String) -> String, sections: @escaping @Sendable (String) -> [String],
                plain: @escaping @Sendable (String) -> String) {
        self.short = short; self.sections = sections; self.plain = plain
    }
}

/// Watches the local mirror for what voice mode should say (spec
/// 2026-10-03 §3, "What is spoken", and §5): a watched conversation's
/// turn ending, and prompts and items that start or stop needing the user.
/// Reads only the store: nothing here talks to the network.
@MainActor
public final class JournalVoiceFeed: VoiceFeeding {
    public enum Scope: Equatable, Sendable {
        /// Started inside a conversation: only what happens in it.
        case conversation(String)
        /// Started from the app shell: everything that needs the user.
        case everything
    }

    public let events: AsyncStream<VoiceModeEngine.Event>
    private let continuation: AsyncStream<VoiceModeEngine.Event>.Continuation

    private let store: JournalStore
    private let text: VoiceTextMaker
    private let scope: Scope
    /// How long a turn's end waits for its `summary` event before the
    /// cleaner's version is used (spec: up to four seconds).
    private let summaryWait: TimeInterval
    private let poll: TimeInterval
    private let needsPoll: TimeInterval
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var watchers: [String: Task<Void, Never>] = [:]
    private var replies: [String: Task<Void, Never>] = [:]
    /// Per conversation: nothing at or below this seq is a new reply.
    private var floors: [String: Int64] = [:]
    private var needsTask: Task<Void, Never>?
    private var known: Set<String> = []
    private var permissionDeadlines: [String: Date] = [:]

    public init(store: JournalStore, text: VoiceTextMaker, scope: Scope, summaryWait: TimeInterval = 4,
                poll: TimeInterval = 0.25, needsPoll: TimeInterval = 2,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.store = store
        self.text = text
        self.scope = scope
        self.summaryWait = summaryWait
        self.poll = poll
        self.needsPoll = needsPoll
        self.now = now
        self.sleep = sleep
        (events, continuation) = AsyncStream.makeStream(of: VoiceModeEngine.Event.self)
    }

    // MARK: The queue

    /// "What needs you" as entries the engine can read out, in the
    /// queue's order. Call before `start(.queue…)`.
    public func initialQueue() -> [VoiceEntry] {
        let entries = (try? store.needsYouEntries(now: now())) ?? []
        remember(entries)
        return entries.compactMap(voiceEntry)
    }

    /// The conversation voice mode falls back to once the queue is empty:
    /// the one used last, other than `excluding` (the Coordinator's).
    public func lastConversation(excluding: String? = nil) -> (id: String, title: String, boxName: String?)? {
        guard let record = (try? store.conversations(now: now()))?.first(where: { $0.id != excluding }) else { return nil }
        return (record.id, NeedsYouQueue.cleanTitle(record.title), boxName(record.agentDeviceID))
    }

    /// Starts telling the engine about prompts and items as they start and
    /// stop needing the user.
    public func startWatchingNeeds() {
        guard needsTask == nil else { return }
        if case .conversation = scope {
            // Items already waiting when voice mode opened inside a
            // conversation are not read out; a prompt there is.
            let items = ((try? store.needsYouEntries(now: now())) ?? []).filter {
                if case .item = $0.kind { return true } else { return false }
            }
            known.formUnion(items.map(\.id))
        }
        let interval = needsPoll
        let sleep = self.sleep
        needsTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshNeeds()
                do { try await sleep(interval) } catch { return }
            }
        }
    }

    private func inScope(_ entry: NeedsYouEntry) -> Bool {
        switch scope {
        case .everything: return true
        case .conversation(let id): return entry.convoID == id
        }
    }

    private func remember(_ entries: [NeedsYouEntry]) {
        for entry in entries {
            known.insert(entry.id)
            if case .permission(let prompt) = entry.kind, permissionDeadlines[entry.id] == nil,
               let ts = (try? store.events(convoID: prompt.convoID, beforeSeq: prompt.seq + 1, limit: 1))?.last?.ts {
                permissionDeadlines[entry.id] = ts.addingTimeInterval(NeedsYouQueue.permissionTTL)
            }
        }
    }

    func refreshNeeds() {
        let entries = ((try? store.needsYouEntries(now: now())) ?? []).filter { entry in
            if case .unseenReply = entry.kind { return false }
            return inScope(entry)
        }
        let ids = Set(entries.map(\.id))
        let fresh = entries.filter { !known.contains($0.id) }
        let gone = known.subtracting(ids).filter { !$0.hasPrefix("convo:") }
        remember(fresh)
        for entry in fresh {
            if let voice = voiceEntry(entry) { continuation.yield(.arrived(voice)) }
        }
        for id in gone.sorted() {
            known.remove(id)
            let expired = permissionDeadlines.removeValue(forKey: id).map { now() >= $0 } ?? false
            continuation.yield(.resolved(id: id, expired: expired))
        }
    }

    private func boxName(_ deviceID: Int64?) -> String? {
        guard let deviceID else { return nil }
        return (try? store.agentNames())?[deviceID]
    }

    func voiceEntry(_ entry: NeedsYouEntry) -> VoiceEntry? {
        switch entry.kind {
        case .permission(let prompt), .prompt(let prompt):
            let said = VoicePrompt(convoID: prompt.convoID, seq: prompt.seq, question: text.plain(prompt.question),
                                   options: prompt.options, allowsFreeText: prompt.allowsFreeText, permission: prompt.permission)
            return .prompt(said, convoTitle: entry.convoTitle, boxName: entry.boxName)
        case .item(let item):
            return .item(VoiceItem(item, sections: text.sections(item.body)), convoTitle: entry.convoTitle, boxName: entry.boxName)
        case .unseenReply:
            let read = (try? store.conversation(id: entry.convoID))?.readUpToSeq ?? 0
            guard let reply = try? store.lastAgentReply(convoID: entry.convoID, afterSeq: read),
                  let spoken = spokenReply(reply, convoID: entry.convoID) else { return nil }
            floors[entry.convoID] = (try? store.maxSeq(convoID: entry.convoID)) ?? reply.seq
            return .reply(spoken, convoTitle: entry.convoTitle, boxName: entry.boxName)
        }
    }

    // MARK: Turns

    public func watch(convoID: String) {
        guard watchers[convoID] == nil else { return }
        if floors[convoID] == nil {
            // Whatever is already there has been seen (or was just read
            // out as a queue entry): only later replies are spoken.
            floors[convoID] = ((try? store.maxSeq(convoID: convoID)) ?? nil) ?? 0
        }
        let stream = store.sessionStateStream(convoID: convoID)
        watchers[convoID] = Task { [weak self] in
            var wasRunning: Bool?
            // One value per change to the conversation's row, so a turn
            // that started and ended between two deliveries is still seen:
            // every quiet delivery looks for a reply above the floor.
            for await state in stream {
                guard let self, !Task.isCancelled else { return }
                let running = state == "running"
                if running, wasRunning != true { self.continuation.yield(.turnStarted(convoID: convoID)) }
                if !running {
                    if wasRunning == true { self.continuation.yield(.turnEnded(convoID: convoID)) }
                    self.lookForReply(convoID)
                }
                wasRunning = running
            }
        }
    }

    private func lookForReply(_ convoID: String) {
        guard let reply = try? store.lastAgentReply(convoID: convoID, afterSeq: floors[convoID] ?? 0) else { return }
        floors[convoID] = ((try? store.maxSeq(convoID: convoID)) ?? nil) ?? reply.seq
        replies[convoID]?.cancel()
        let wait = summaryWait
        let step = poll
        let sleep = self.sleep
        replies[convoID] = Task { [weak self] in
            // The summary pass lands a second or three after the turn
            // ends. A reply with no ref can have no spoken line: no wait.
            var waited: TimeInterval = 0
            while reply.messageRef != nil, waited < wait, !Task.isCancelled {
                if (try? self?.store.spokenSummary(convoID: convoID, for: reply)) ?? nil != nil { break }
                do { try await sleep(step) } catch { return }
                waited += step
            }
            guard let self, !Task.isCancelled, let spoken = self.spokenReply(reply, convoID: convoID) else { return }
            let record = try? self.store.conversation(id: convoID)
            self.continuation.yield(.arrived(.reply(spoken, convoTitle: NeedsYouQueue.cleanTitle(record?.title ?? ""),
                                                    boxName: self.boxName(record?.agentDeviceID))))
        }
    }

    /// The bridge's spoken lines when its summary names this reply, else
    /// the cleaner's short form. `nil` when there is nothing sayable.
    func spokenReply(_ reply: AgentReplyRow, convoID: String) -> SpokenReply? {
        let sections = text.sections(reply.body)
        if let summary = try? store.spokenSummary(convoID: convoID, for: reply), let spoken = summary.spoken {
            return SpokenReply(convoID: convoID, seq: reply.seq, short: spoken, more: summary.spokenMore, sections: sections)
        }
        let short = text.short(reply.body)
        guard !short.isEmpty else { return nil }
        // A message short enough to be its own summary has nothing more.
        let whole = sections.joined(separator: " ")
        return SpokenReply(convoID: convoID, seq: reply.seq, short: short, more: nil, sections: whole == short ? [] : sections)
    }

    public func stop() {
        for task in watchers.values { task.cancel() }
        for task in replies.values { task.cancel() }
        watchers = [:]
        replies = [:]
        needsTask?.cancel()
        needsTask = nil
        continuation.finish()
    }
}
