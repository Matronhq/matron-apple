import Foundation

/// The session starts THIS device has asked for and not yet seen born: a
/// `start` agent RPC (New Chat) or a `/start` line sent from the composer.
///
/// The journal does not say who started a conversation. A spawned session's
/// first title is the same bare seed as the user's own (the bridge adds the
/// 🐣 marker only to titles it earns later), so the wire cannot tell "Dan
/// started this" from "an agent started this". What the client does know is
/// what it asked for itself — so a live-born conversation opens only when
/// it answers one of these, and every other one arrives quietly.
///
/// One intent per box, newest wins: a wake-and-retry `start` re-asks the
/// same box several times for one session, and leftover copies would let an
/// unrelated spawn on that box open a minute later.
struct LocalStartIntents {
    private struct Intent {
        let agentDeviceID: Int64?
        let at: ContinuousClock.Instant
    }

    /// How long an ask stays claimable. A session on an awake box is born
    /// within a second or two; by the time this has passed the user has
    /// moved on, and opening it then would be the interruption this exists
    /// to prevent — it lands in the list with its "New" marker instead.
    let window: Duration
    private var intents: [Intent] = []
    /// Conversations a `start` RPC answered with before their first frame
    /// arrived: this device's own by id, no clock needed.
    private var startedConvoIDs: Set<String> = []

    init(window: Duration = .seconds(60)) {
        self.window = window
    }

    /// Records an ask aimed at `agentDeviceID` (nil when the box isn't
    /// known: a `/start` sent in a conversation whose owner hasn't synced).
    mutating func note(agentDeviceID: Int64?, now: ContinuousClock.Instant = .now) {
        intents.removeAll { $0.agentDeviceID == agentDeviceID }
        intents.append(Intent(agentDeviceID: agentDeviceID, at: now))
    }

    /// Forgets the ask aimed at `agentDeviceID` — its `start` was refused,
    /// so no conversation is coming.
    mutating func drop(agentDeviceID: Int64?) {
        intents.removeAll { $0.agentDeviceID == agentDeviceID }
    }

    /// A `start` RPC to `agentDeviceID` answered with `convoID`. The ask
    /// is settled — that conversation is its answer, whenever it is born —
    /// so nothing else born on the box may claim it.
    mutating func noteStarted(convoID: String, agentDeviceID: Int64?) {
        drop(agentDeviceID: agentDeviceID)
        startedConvoIDs.insert(convoID)
    }

    /// Whether `convoID` is one a `start` RPC from this device answered
    /// with, consuming the record if so.
    mutating func claimStarted(convoID: String) -> Bool {
        startedConvoIDs.remove(convoID) != nil
    }

    /// Whether a conversation just born on `agentDeviceID` answers a live
    /// ask, consuming the ask if so. A box unknown on either side matches:
    /// the owner rides the titled `convo_meta`, and a conversation whose
    /// first frame is a message has not said yet.
    mutating func claim(agentDeviceID: Int64?, now: ContinuousClock.Instant = .now) -> Bool {
        intents.removeAll { now - $0.at > window }
        guard let index = intents.firstIndex(where: {
            $0.agentDeviceID == nil || agentDeviceID == nil || $0.agentDeviceID == agentDeviceID
        }) else { return false }
        intents.remove(at: index)
        return true
    }

    /// Whether a sent line is the bridge's start command: `/start` or
    /// `!start`, any case, with or without arguments.
    static func isStartCommand(_ body: String) -> Bool {
        let trimmed = body.drop(while: { $0.isWhitespace })
        guard let first = trimmed.first, first == "/" || first == "!" else { return false }
        let command = trimmed.dropFirst().prefix(while: { !$0.isWhitespace })
        return command.lowercased() == "start"
    }
}
