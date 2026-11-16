import Foundation

/// What a notification says, as the journal sealed it for this device
/// (matron-journal `docs/protocol.md`, "Sealed notification content").
/// Unknown keys are ignored; a version this build does not know does not
/// decode, and the notification keeps its fixed text.
public struct PushContent: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let id: String
        public let number: Int
        public let kind: String
        /// The buttons the item offers now, at most four.
        public let actions: [String]
        /// The comment the buttons belong to; nil for the item's own.
        public let replyTo: String?

        public init(id: String, number: Int, kind: String, actions: [String], replyTo: String?) {
            self.id = id
            self.number = number
            self.kind = kind
            self.actions = actions
            self.replyTo = replyTo
        }
    }

    public let title: String
    public let subtitle: String?
    public let body: String
    public let convoID: String
    public let seq: Int64?
    public let kind: String
    public let item: Item?

    public init(title: String, subtitle: String?, body: String, convoID: String, seq: Int64?, kind: String, item: Item?) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.convoID = convoID
        self.seq = seq
        self.kind = kind
        self.item = item
    }

    public static let supportedVersion = 1
    public static let maxActions = 4

    /// Decodes the opened plaintext: UTF-8 JSON, padded with spaces.
    public init?(plaintext: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              (object["v"] as? NSNumber)?.intValue == Self.supportedVersion,
              let title = object["title"] as? String,
              let body = object["body"] as? String,
              let convoID = object["convo_id"] as? String, !convoID.isEmpty
        else { return nil }
        self.title = title
        self.body = body
        self.convoID = convoID
        subtitle = (object["subtitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        seq = (object["seq"] as? NSNumber).map(\.int64Value).flatMap { $0 > 0 ? $0 : nil }
        kind = object["kind"] as? String ?? ""
        if let raw = object["item"] as? [String: Any], let id = raw["id"] as? String, !id.isEmpty {
            let actions = (raw["actions"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
            item = Item(
                id: id,
                number: (raw["num"] as? NSNumber)?.intValue ?? 0,
                kind: raw["kind"] as? String ?? "",
                actions: Array(actions.prefix(Self.maxActions)),
                replyTo: (raw["reply_to"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        } else {
            item = nil
        }
    }
}
