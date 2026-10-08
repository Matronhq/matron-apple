import Foundation

/// Where a tracker item lives, for the item detail's header: the
/// mission it is on and the conversation that owns it — the one that filed
/// it. Built by `make(...)` from what the item and the local store know, so
/// every surface draws the same rows.
public struct ItemContext: Equatable, Sendable {
    /// The item's mission. `label` is `#61 Launch plan` when this device has
    /// the mission, else `Mission #61` — an item can name a mission this
    /// device has not loaded or cannot see.
    public struct MissionRow: Equatable, Sendable {
        public let num: Int
        public let label: String
        public init(num: Int, label: String) { self.num = num; self.label = label }
    }

    /// The owner conversation (`originConvoID`). `isOpenable` is whether
    /// this device has a row for it: one it has never synced is still named
    /// — the question is which conversation, and the answer stands — but
    /// not offered as a tap that would land on a chat with nothing behind
    /// it (the conversation-link pills' rule).
    public struct OwnerRow: Equatable, Sendable {
        public let id: String
        public let label: String
        public let isOpenable: Bool
        public init(id: String, label: String, isOpenable: Bool = true) {
            self.id = id; self.label = label; self.isOpenable = isOpenable
        }
    }

    public var mission: MissionRow?
    public var owner: OwnerRow?

    public init(mission: MissionRow? = nil, owner: OwnerRow? = nil) {
        self.mission = mission; self.owner = owner
    }

    public var isEmpty: Bool { mission == nil && owner == nil }

    /// The label when nothing names the owner conversation: no local row,
    /// and no title from the journal.
    public static let unnamedConversation = "Conversation"

    /// - Parameters:
    ///   - currentConvoID: the conversation the detail is shown inside, if
    ///     any. The owner row would only point back at the screen
    ///     underneath, so it is left out there. The mission row always
    ///     shows.
    ///   - mission: the local copy of `item.missionID`, if this device has it.
    ///   - ownerLabel: the owner's local label
    ///     (`JournalStore.conversationOriginStream(id:)`); `nil` falls back to the
    ///     journal's `originConvoTitle`, then to `unnamedConversation`.
    ///   - ownerIsOpenable: whether this device has a row for the owner.
    public static func make(item: TrackerItem, currentConvoID: String?, mission: Mission?,
                            ownerLabel: String?, ownerIsOpenable: Bool) -> ItemContext {
        var context = ItemContext()
        if let num = item.missionNum {
            let label = mission.map { "#\($0.num) \($0.name ?? $0.title)" } ?? "Mission #\(num)"
            context.mission = MissionRow(num: num, label: label)
        }
        // A granted item's origin is "": it was filed in someone else's
        // conversation, which this user cannot open.
        let origin = item.originConvoID
        if !origin.isEmpty, origin != currentConvoID {
            context.owner = OwnerRow(id: origin, label: ownerLabel ?? item.originConvoTitle ?? unnamedConversation,
                                     isOpenable: ownerIsOpenable)
        }
        return context
    }
}
