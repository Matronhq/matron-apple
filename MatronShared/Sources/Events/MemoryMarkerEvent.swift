import Foundation
import MatronModels

/// The `memory` journal event (protocol: "Memories → Marker event"). An
/// invalidation signal — the Memories screen refetches the list — plus a
/// one-line timeline notice. The journal may append the same change to two
/// conversations (the writer's and the Coordinator's), so consumers dedupe
/// on `memoryID` / coalesce rather than count.
///
/// `name`, `type` and `description` are OPTIONAL: across a privacy boundary
/// (a memory saved from a private device, written to a conversation that
/// isn't private-owned) the payload carries only `memory_id`, `action`,
/// `created` and `by`.
public struct MemoryMarkerEvent: Equatable, Sendable {
    public enum Action: String, Sendable { case saved, deleted }
    public let memoryID: String
    public let action: Action
    public let created: Bool
    public let by: ItemAuthor
    public let name: String?
    public let type: MemoryType?
    public let description: String?

    public init(memoryID: String, action: Action, created: Bool = false, by: ItemAuthor = .agent,
                name: String? = nil, type: MemoryType? = nil, description: String? = nil) {
        self.memoryID = memoryID; self.action = action; self.created = created; self.by = by
        self.name = name; self.type = type; self.description = description
    }

    public static func parse(payload: [String: Any]) -> MemoryMarkerEvent? {
        guard let memoryID = payload["memory_id"] as? String, !memoryID.isEmpty,
              let action = (payload["action"] as? String).flatMap(Action.init(rawValue:))
        else { return nil }
        return MemoryMarkerEvent(memoryID: memoryID, action: action,
                                 created: payload["created"] as? Bool ?? false,
                                 by: (payload["by"] as? String).flatMap(ItemAuthor.init(rawValue:)) ?? .agent,
                                 name: payload["name"] as? String,
                                 type: (payload["type"] as? String).flatMap(MemoryType.init(rawValue:)),
                                 description: payload["description"] as? String)
    }

    /// The timeline's one-line notice — web's `MemoryNotice` copy:
    /// "You saved a memory · name — description", "Agent deleted a memory ·
    /// name", or just "Agent updated a memory" when the name was withheld.
    public var noticeText: String {
        let verb = action == .deleted ? "deleted" : (created ? "saved" : "updated")
        let who = by == .user ? "You" : "Agent"
        var text = "🧠 \(who) \(verb) a memory"
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedName.isEmpty else { return text }
        text += " · \(trimmedName)"
        let oneLine = (description ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if action != .deleted, !oneLine.isEmpty { text += " — \(oneLine)" }
        return text
    }
}
