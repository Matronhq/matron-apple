import Foundation
import MatronModels

public struct ChatSummary: Equatable, Hashable, Identifiable, Sendable {
    /// The fields, in one immutable box shared by every copy: the chat
    /// list copies and compares every summary on each snapshot, and a
    /// summary has about fifteen reference-counted fields, so a copy costs
    /// one retain instead of one per field, and comparing a summary with
    /// itself (an unchanged row reused from the last snapshot) is a
    /// pointer check.
    private let storage: Storage

    private final class Storage: Sendable {
        let fields: Fields
        init(_ fields: Fields) { self.fields = fields }
    }

    private struct Fields: Hashable, Sendable {
        let id: String
        let title: String
        let bot: BotIdentity
        /// `nil` when the room's timeline hasn't been hydrated yet — e.g. a Phase
        /// 1 sliding-sync snapshot before any timeline events have been pulled.
        /// UI should hide the relative-time label and grouping when nil.
        let lastActivity: Date?
        let unreadCount: Int
        /// One-line preview of the newest message (the server/store `snippet`).
        /// Empty when the conversation has no messages yet — rows hide the
        /// preview line rather than showing a blank.
        let snippet: String
        /// The parent conversation's id when this is a subagent child chat,
        /// else `nil`. Immutable server-side (once a child, always a child).
        /// Children never appear in the main chat list — they are reachable
        /// only through their parent's running-subagent strip — so the chat-
        /// list query filters `parentConvoID == nil`. Carried here so any
        /// summary consumer can defend in depth (no badges / notifications
        /// for children) alongside the server's own silence rule.
        let parentConvoID: String?
        /// Display name of the agent box that owns this conversation, or `nil`
        /// when no chip should be shown — which covers all three of: the user
        /// has fewer than two boxes (nothing to disambiguate), the conversation
        /// has no recorded box, and the recorded box no longer exists. Resolving
        /// the gate upstream keeps every row view a dumb renderer.
        let boxName: String?
        /// Two characters of the session/room id, peeled off the title's
        /// `[bc] ` (or `🔗 [bc] `) prefix (SessionTag.splitTitle). `title` is
        /// always the CLEAN remainder — rows compose the styled tag from this
        /// instead.
        let sessionShort: String?
        /// The box's one-letter display tag (SessionTag.boxLetters), gated
        /// exactly like `boxName`: nil unless the user has two or more boxes.
        let boxShort: String?
        /// Every participating box of a multi-agent room, resolved and deduped
        /// upstream (JournalChatService), or empty when this is not a known
        /// multi-box room. Two or more entries by construction — a room whose
        /// members collapse to one box falls back to the single-box tag.
        let roomBoxNames: [String]
        /// One display letter per `roomBoxNames` entry (parallel arrays, same
        /// order) — what the colored `A↔B` room tag actually prints. The name
        /// array carries the hue, this one the glyphs.
        let roomBoxShorts: [String]
        /// A room's participant conversation ids (each participant agent's own
        /// session, journal-ordered, starter first), or empty when this is not
        /// a room or its participants are unknown. Places the room under the
        /// missions its participants are actively on (MissionsDashboardAssembly).
        let roomConvoIDs: [String]
        /// Open items on this conversation still awaiting the user, from the
        /// local items cache (`JournalStore.needsUserCountsStream()`) — the
        /// journal has no such endpoint, so this is app-local and derived, not
        /// server-carried like `unreadCount`. Feeds the orange `NeedsYouBadge`
        /// on chat-list rows, alongside the existing unread pill.
        let needsUserCount: Int
    }

    public var id: String { storage.fields.id }
    public var title: String { storage.fields.title }
    public var bot: BotIdentity { storage.fields.bot }
    public var lastActivity: Date? { storage.fields.lastActivity }
    public var unreadCount: Int { storage.fields.unreadCount }
    public var snippet: String { storage.fields.snippet }
    public var parentConvoID: String? { storage.fields.parentConvoID }
    public var boxName: String? { storage.fields.boxName }
    public var sessionShort: String? { storage.fields.sessionShort }
    public var boxShort: String? { storage.fields.boxShort }
    public var roomBoxNames: [String] { storage.fields.roomBoxNames }
    public var roomBoxShorts: [String] { storage.fields.roomBoxShorts }
    public var roomConvoIDs: [String] { storage.fields.roomConvoIDs }
    public var needsUserCount: Int { storage.fields.needsUserCount }

    public init(
        id: String,
        title: String,
        bot: BotIdentity,
        lastActivity: Date?,
        unreadCount: Int,
        snippet: String = "",
        parentConvoID: String? = nil,
        boxName: String? = nil,
        sessionShort: String? = nil,
        boxShort: String? = nil,
        roomBoxNames: [String] = [],
        roomBoxShorts: [String] = [],
        roomConvoIDs: [String] = [],
        needsUserCount: Int = 0
    ) {
        storage = Storage(Fields(
            id: id, title: title, bot: bot, lastActivity: lastActivity, unreadCount: unreadCount,
            snippet: snippet, parentConvoID: parentConvoID, boxName: boxName, sessionShort: sessionShort,
            boxShort: boxShort, roomBoxNames: roomBoxNames, roomBoxShorts: roomBoxShorts,
            roomConvoIDs: roomConvoIDs, needsUserCount: needsUserCount
        ))
    }

    public static func == (lhs: ChatSummary, rhs: ChatSummary) -> Bool {
        lhs.storage === rhs.storage || lhs.storage.fields == rhs.storage.fields
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(storage.fields) }

    /// Whether both share one box: the same summary carried over from an
    /// earlier snapshot, not just an equal one.
    public func isSameInstance(as other: ChatSummary) -> Bool { storage === other.storage }
}

/// A subagent child conversation as surfaced in its parent's running-
/// subagent strip and the sub-chat switcher menu. Deliberately smaller than
/// `ChatSummary`: the strip needs only identity, a label, and whether the
/// subagent is still running (spinner vs. done). The child's model / context
/// gauge come free from the per-convo session-status stream once the viewer
/// subscribes with `id`, so they're not duplicated here.
public struct SubChatSummary: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    /// `true` while the subagent is active (`session_state == "running"`),
    /// `false` once finished (`"done"`). The strip shows only running
    /// children; the mini-header renders running/finished state.
    public let isRunning: Bool

    public init(id: String, title: String, isRunning: Bool) {
        self.id = id
        self.title = title
        self.isRunning = isRunning
    }
}

public enum ChatRecencyGroup: String, CaseIterable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case lastSevenDays = "Last 7 days"
    case earlier = "Earlier"
    /// Used for chats whose timeline isn't hydrated yet (Phase 1) so we don't
    /// stamp them with a misleading "Today" label.
    case noActivity = "No recent activity"

    public static func bucket(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> ChatRecencyGroup {
        guard let date else { return .noActivity }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        return date >= sevenDaysAgo ? .lastSevenDays : .earlier
    }
}
