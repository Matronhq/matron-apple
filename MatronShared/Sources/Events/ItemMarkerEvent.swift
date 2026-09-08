import Foundation
import MatronModels

/// The `item` journal event (spec: Marker event) — what the conversation
/// log records about a tracker item. Not the item itself: the apps refetch
/// the row from `/items/:id` on receipt. `reordered` and `updated` markers
/// exist only to invalidate the local cache and never render.
public struct ItemMarkerEvent: Equatable, Sendable {
    public enum Action: String, Sendable { case created, commented, closed, reopened, reordered, updated }
    public struct Comment: Equatable, Sendable {
        public let id: String
        public let body: String
        public let attachments: [TrackerAttachment]
        public init(id: String, body: String, attachments: [TrackerAttachment] = []) {
            self.id = id; self.body = body; self.attachments = attachments
        }
    }
    public let itemID: String
    public let num: Int
    public let kind: ItemKind
    public let title: String
    public let action: Action
    public let by: ItemAuthor
    public let awaiting: ItemAwaiting?
    public let resolution: ItemResolution?
    public let comment: Comment?

    public init(itemID: String, num: Int, kind: ItemKind, title: String, action: Action, by: ItemAuthor,
                awaiting: ItemAwaiting? = nil, resolution: ItemResolution? = nil, comment: Comment? = nil) {
        self.itemID = itemID; self.num = num; self.kind = kind; self.title = title; self.action = action
        self.by = by; self.awaiting = awaiting; self.resolution = resolution; self.comment = comment
    }

    public static func parse(payload: [String: Any]) -> ItemMarkerEvent? {
        guard let itemID = payload["item_id"] as? String, let num = (payload["num"] as? NSNumber)?.intValue,
              let kind = (payload["kind"] as? String).flatMap(ItemKind.init(rawValue:)),
              let title = payload["title"] as? String,
              let action = (payload["action"] as? String).flatMap(Action.init(rawValue:)),
              let by = (payload["by"] as? String).flatMap(ItemAuthor.init(rawValue:)) else { return nil }
        var comment: Comment?
        if let c = payload["comment"] as? [String: Any], let cid = c["id"] as? String {
            comment = Comment(id: cid, body: c["body"] as? String ?? "",
                              attachments: (c["attachments"] as? [[String: Any]] ?? []).compactMap(TrackerAttachment.init(json:)))
        }
        return ItemMarkerEvent(itemID: itemID, num: num, kind: kind, title: title, action: action, by: by,
                               awaiting: (payload["awaiting"] as? String).flatMap(ItemAwaiting.init(rawValue:)),
                               resolution: (payload["resolution"] as? String).flatMap(ItemResolution.init(rawValue:)),
                               comment: comment)
    }
}
