import Foundation
import MatronChat
import MatronModels
import MatronJournal

/// The store reads the missions surfaces need, as a protocol so tests fake
/// the store (`JournalStore` conforms; the conformance is declared here
/// because `MatronJournal` cannot import this module).
public protocol MissionsStoreReading: Sendable {
    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]>
    func missionStream(id: String) -> AsyncStream<Mission?>
    func milestonesStream(missionID: String) -> AsyncStream<[Milestone]>
    func itemsStream(missionID: String) -> AsyncStream<[TrackerItem]>
    func missionConversationsStream(missionID: String) -> AsyncStream<[MissionConversation]>
    /// The `A:bc` tag halves for one conversation, or `nil` when this
    /// device has no cached row for it (a milestone can name a
    /// conversation that has never synced here — it renders untagged).
    /// The batch form's one-element caller (MINOR-5).
    func sessionTag(convoID: String) -> SessionTagInputs?
    /// The `A:bc` tag halves for several conversations, keyed by id, with
    /// no entry for a conversation this device has no cached row for. The
    /// box roster and letter overrides are read ONCE for the whole batch,
    /// not once per conversation — a mission page re-derives every tag on
    /// every milestone-stream emission, so that part is not irreducible
    /// the way the per-conversation `conversation(id:)` read is (MINOR-5).
    func sessionTags(convoIDs: Set<String>) -> [String: SessionTagInputs]
    /// Live id → `session_state` for every conversation: the mission
    /// page's On it now dots and order read it over the detail row's
    /// (possibly stale) `state`, as the dashboard cards do.
    func sessionStatesStream() -> AsyncStream<[String: String]>
}

/// A mission's closed items, most recently closed first — the Mac mission
/// board's Done column. Its own protocol (not a `MissionsStoreReading`
/// requirement) because only the Mac page reads it: the iOS host passes
/// nothing and its fakes need no stub.
public protocol MissionClosedItemsReading: Sendable {
    func closedItemsStream(missionID: String, limit: Int) -> AsyncStream<[TrackerItem]>
    func closedItemsCountStream(missionID: String) -> AsyncStream<Int>
}

extension JournalStore: MissionClosedItemsReading {}

extension JournalStore: MissionsStoreReading {
    public func sessionTag(convoID: String) -> SessionTagInputs? {
        sessionTags(convoIDs: [convoID])[convoID]
    }

    /// Derived from reads the store already has: the conversation row
    /// (`conversation(id:)`, one per id), the box roster (`agentNames()`)
    /// and the journal-held tag overrides (`agentTagChars()`) — the latter
    /// two hoisted out of the per-conversation loop. This is the same
    /// derivation `JournalChatService.summary(from:boxNames:boxLetters:)`
    /// runs for a chat-list row — restated here because that one is
    /// internal to `MatronChat` — including its two gates: a box letter
    /// only means something when the user has two or more boxes, and the
    /// session short is peeled off the stored title by
    /// `SessionTag.splitTitle`. Also restates `JournalChatService.roomTags`
    /// for a multi-agent room (Bugbot: the mission page used to carry only
    /// the single-box halves, so a room conversation rendered as an
    /// owner-box `A:bc` there instead of `A↔B:bc` — chat headers and list
    /// rows already try `SessionTagText.room` before `.run`). Cheap enough
    /// to call on the main actor (a handful of indexed row reads), like
    /// `conversationOriginLabels()`.
    public func sessionTags(convoIDs: Set<String>) -> [String: SessionTagInputs] {
        guard !convoIDs.isEmpty else { return [:] }
        let names = (try? agentNames()) ?? [:]
        let letters = SessionTag.boxLetters(for: names, overrides: (try? agentTagChars()) ?? [:])
        var tags: [String: SessionTagInputs] = [:]
        for convoID in convoIDs {
            guard let record = try? conversation(id: convoID) else { continue }
            let boxName = names.count >= 2 ? record.agentDeviceID.flatMap { names[$0] } : nil
            let boxLetter = boxName != nil ? record.agentDeviceID.flatMap { letters[$0] } : nil
            let sessionShort = SessionTag.splitTitle(record.title).sessionShort
            let room = Self.roomTags(participantIDs: record.participantIDs, names: names, letters: letters)
            guard boxLetter != nil || sessionShort != nil || !room.isEmpty else { continue }
            tags[convoID] = SessionTagInputs(boxLetter: boxLetter, boxName: boxName, sessionShort: sessionShort,
                                             roomBoxNames: room.map(\.name), roomBoxShorts: room.map(\.letter))
        }
        return tags
    }

    /// Restates `JournalChatService.roomTags(for:boxNames:boxLetters:)`:
    /// every participant id resolved to its box name AND display letter,
    /// deduped by name in journal order, empty unless at least two
    /// DISTINCT boxes resolve — same two-box gate as the single-box tag,
    /// so a local room (both ends share one box) or a single-box user
    /// falls through to `run(...)`.
    private static func roomTags(
        participantIDs: [Int64], names: [Int64: String], letters: [Int64: String]
    ) -> [(name: String, letter: String)] {
        guard names.count >= 2, participantIDs.count >= 2 else { return [] }
        var seen = Set<String>()
        var tags: [(name: String, letter: String)] = []
        for id in participantIDs {
            guard let name = names[id], seen.insert(name).inserted else { continue }
            tags.append((name: name, letter: letters[id] ?? "?"))
        }
        return tags.count >= 2 ? tags : []
    }
}

/// The write/refresh surface, mirroring `ItemsSyncing`. `supportedStream` is
/// `async` because `MissionsSync` is an actor and the method is isolated.
public protocol MissionsSyncing: Sendable {
    @discardableResult
    func refresh() async -> MissionsRefreshOutcome
    @discardableResult
    func refreshMission(id: String) async -> MissionsRefreshOutcome
    @discardableResult
    func closeMission(id: String, summary: String) async throws -> Mission
    func supportedStream() async -> AsyncStream<Bool>
}
extension MissionsSync: MissionsSyncing {}
