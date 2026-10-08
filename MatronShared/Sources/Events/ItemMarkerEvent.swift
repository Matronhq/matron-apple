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
        /// The label when the comment is an action tap, and the comment
        /// whose buttons it answered (`nil` for the item's own buttons) —
        /// together, enough to mark the choice without a refetch.
        public let action: String?
        public let replyTo: String?
        public init(id: String, body: String, attachments: [TrackerAttachment] = [], action: String? = nil, replyTo: String? = nil) {
            self.id = id; self.body = body; self.attachments = attachments
            self.action = action; self.replyTo = replyTo
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
    /// Set on a consent mirror's markers: `"chat"` or `"spawn"` (the
    /// journal's `consent` extra), `nil` on an ordinary item's.
    public let consent: String?
    /// Which ask a consent mirror stands for — `<room_id>/<target_device_id>`
    /// for a chat, the `request_id` for a spawn. Journals before
    /// matron-journal's `consent_ask` extra omit it.
    public let consentAsk: String?
    /// How the ask ended, on the marker that closes a consent mirror:
    /// `approved`, `denied`, `expired`, `left`, `gone`… (`consent_outcome`;
    /// absent from older journals, which only say it in the closing note).
    public let consentOutcome: String?
    /// `"coordinator"` when the Coordinator, not a tap, decided the ask.
    public let decidedBy: String?

    public init(itemID: String, num: Int, kind: ItemKind, title: String, action: Action, by: ItemAuthor,
                awaiting: ItemAwaiting? = nil, resolution: ItemResolution? = nil, comment: Comment? = nil,
                consent: String? = nil, consentAsk: String? = nil, consentOutcome: String? = nil,
                decidedBy: String? = nil) {
        self.itemID = itemID; self.num = num; self.kind = kind; self.title = title; self.action = action
        self.by = by; self.awaiting = awaiting; self.resolution = resolution; self.comment = comment
        self.consent = consent; self.consentAsk = consentAsk; self.consentOutcome = consentOutcome
        self.decidedBy = decidedBy
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
                              attachments: (c["attachments"] as? [[String: Any]] ?? []).compactMap(TrackerAttachment.init(json:)),
                              action: c["action"] as? String, replyTo: c["reply_to"] as? String)
        }
        return ItemMarkerEvent(itemID: itemID, num: num, kind: kind, title: title, action: action, by: by,
                               awaiting: (payload["awaiting"] as? String).flatMap(ItemAwaiting.init(rawValue:)),
                               resolution: (payload["resolution"] as? String).flatMap(ItemResolution.init(rawValue:)),
                               comment: comment,
                               consent: nonEmpty(payload["consent"]),
                               consentAsk: nonEmpty(payload["consent_ask"]),
                               consentOutcome: nonEmpty(payload["consent_outcome"]),
                               decidedBy: nonEmpty(payload["decided_by"]))
    }

    private static func nonEmpty(_ raw: Any?) -> String? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        return s
    }

    /// Whether the item is closed as of this marker. A `closed` marker says
    /// so by its action; any later marker carries the item's resolution,
    /// which a reopen clears.
    public var leavesItemClosed: Bool {
        action == .closed || (action != .reopened && resolution != nil)
    }

    /// This card-shaped marker (`created`/`closed`) re-stated in the item's
    /// state as of `latest`, a later marker for the same item — what the one
    /// card the timeline keeps per item shows. Returns `self` when nothing
    /// it draws changed. A closed card keeps its closing comment; a card
    /// whose item has been reopened since drops it, with the "Done" pill.
    public func restated(as latest: ItemMarkerEvent) -> ItemMarkerEvent {
        let closed = latest.leavesItemClosed
        let restated = ItemMarkerEvent(
            itemID: itemID, num: num, kind: kind, title: latest.title,
            action: closed ? .closed : .created, by: by,
            awaiting: latest.awaiting,
            resolution: closed ? (latest.resolution ?? resolution) : nil,
            comment: closed == (action == .closed) ? comment : nil,
            consent: consent, consentAsk: consentAsk, consentOutcome: consentOutcome,
            decidedBy: decidedBy)
        return restated == self ? self : restated
    }
}
