import Foundation

public enum ItemKind: String, Codable, Sendable, CaseIterable { case task, question, decision }
public enum ItemState: String, Codable, Sendable { case open, closed }
public enum ItemResolution: String, Codable, Sendable, CaseIterable { case done, answered, decided, reversed, cancelled }
public enum ItemAwaiting: String, Codable, Sendable { case user, agent }
public enum ItemAuthor: String, Codable, Sendable { case user, agent }

private func msDate(_ v: Any?) -> Date? {
    guard let n = v as? NSNumber else { return nil }
    return Date(timeIntervalSince1970: n.doubleValue / 1000)
}

public struct TrackerAttachment: Equatable, Hashable, Sendable, Codable {
    public let blobRef: String
    public let mime: String
    public let name: String
    public let size: Int64
    public var transcript: String?
    public init(blobRef: String, mime: String, name: String, size: Int64, transcript: String? = nil) {
        self.blobRef = blobRef; self.mime = mime; self.name = name; self.size = size; self.transcript = transcript
    }
    public init?(json: [String: Any]) {
        guard let blobRef = json["blob_ref"] as? String, let mime = json["mime"] as? String else { return nil }
        self.init(blobRef: blobRef, mime: mime, name: json["name"] as? String ?? "",
                  size: (json["size"] as? NSNumber)?.int64Value ?? 0, transcript: json["transcript"] as? String)
    }
    public var isImage: Bool { mime.hasPrefix("image/") }
    public var isAudio: Bool { mime.hasPrefix("audio/") }
    public var json: [String: Any] {
        var o: [String: Any] = ["blob_ref": blobRef, "mime": mime, "name": name, "size": size]
        if let transcript { o["transcript"] = transcript }
        return o
    }
}

public struct TrackerLink: Equatable, Hashable, Sendable, Codable {
    public let url: String
    public let title: String?
    public init(url: String, title: String? = nil) { self.url = url; self.title = title }
    public init?(json: [String: Any]) {
        guard let url = json["url"] as? String else { return nil }
        self.init(url: url, title: json["title"] as? String)
    }
}

public struct TrackerItem: Identifiable, Equatable, Hashable, Sendable {
    public struct StatusSnapshot: Equatable, Hashable, Sendable {
        public let state: ItemState?
        public let resolution: ItemResolution?
        public let awaiting: ItemAwaiting?
        public init(state: ItemState?, resolution: ItemResolution?, awaiting: ItemAwaiting?) {
            self.state = state; self.resolution = resolution; self.awaiting = awaiting
        }
        init?(json: [String: Any]?) {
            guard let json else { return nil }
            self.init(state: (json["state"] as? String).flatMap(ItemState.init(rawValue:)),
                      resolution: (json["resolution"] as? String).flatMap(ItemResolution.init(rawValue:)),
                      awaiting: (json["awaiting"] as? String).flatMap(ItemAwaiting.init(rawValue:)))
        }
    }

    public let id: String
    public let num: Int
    public let kind: ItemKind
    public let state: ItemState
    public let resolution: ItemResolution?
    public let awaiting: ItemAwaiting?
    public let rank: Double
    public let title: String
    public let body: String
    public let labels: [String]
    public let links: [TrackerLink]
    public let attachments: [TrackerAttachment]
    public let supersedes: String?
    public let originConvoID: String
    public let createdBy: ItemAuthor
    public let createdAt: Date
    public let updatedAt: Date
    public let closedAt: Date?
    public let commentCount: Int
    public let lastCommentAt: Date?
    public let hasImage: Bool

    public init(id: String, num: Int, kind: ItemKind, state: ItemState = .open, resolution: ItemResolution? = nil,
                awaiting: ItemAwaiting? = nil, rank: Double = 1024, title: String, body: String = "",
                labels: [String] = [], links: [TrackerLink] = [], attachments: [TrackerAttachment] = [],
                supersedes: String? = nil, originConvoID: String, createdBy: ItemAuthor = .agent,
                createdAt: Date = Date(), updatedAt: Date = Date(), closedAt: Date? = nil,
                commentCount: Int = 0, lastCommentAt: Date? = nil, hasImage: Bool = false) {
        self.id = id; self.num = num; self.kind = kind; self.state = state; self.resolution = resolution
        self.awaiting = awaiting; self.rank = rank; self.title = title; self.body = body; self.labels = labels
        self.links = links; self.attachments = attachments; self.supersedes = supersedes
        self.originConvoID = originConvoID; self.createdBy = createdBy; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.closedAt = closedAt; self.commentCount = commentCount
        self.lastCommentAt = lastCommentAt; self.hasImage = hasImage
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let num = (json["num"] as? NSNumber)?.intValue,
              let kind = (json["kind"] as? String).flatMap(ItemKind.init(rawValue:)),
              let state = (json["state"] as? String).flatMap(ItemState.init(rawValue:)),
              let title = json["title"] as? String, let origin = json["origin_convo_id"] as? String,
              let createdAt = msDate(json["created_at"]), let updatedAt = msDate(json["updated_at"])
        else { return nil }
        let hasImageRaw = json["has_image"]
        self.init(
            id: id, num: num, kind: kind, state: state,
            resolution: (json["resolution"] as? String).flatMap(ItemResolution.init(rawValue:)),
            awaiting: (json["awaiting"] as? String).flatMap(ItemAwaiting.init(rawValue:)),
            rank: (json["rank"] as? NSNumber)?.doubleValue ?? 0, title: title, body: json["body"] as? String ?? "",
            labels: json["labels"] as? [String] ?? [],
            links: (json["links"] as? [[String: Any]] ?? []).compactMap(TrackerLink.init(json:)),
            attachments: (json["attachments"] as? [[String: Any]] ?? []).compactMap(TrackerAttachment.init(json:)),
            supersedes: json["supersedes"] as? String, originConvoID: origin,
            createdBy: (json["created_by"] as? String).flatMap(ItemAuthor.init(rawValue:)) ?? .agent,
            createdAt: createdAt, updatedAt: updatedAt, closedAt: msDate(json["closed_at"]),
            commentCount: (json["comment_count"] as? NSNumber)?.intValue ?? 0,
            lastCommentAt: msDate(json["last_comment_at"]),
            hasImage: (hasImageRaw as? Bool) ?? (((hasImageRaw as? NSNumber)?.intValue ?? 0) != 0))
    }

    public var needsUser: Bool { state == .open && awaiting == .user }
}

public struct TrackerComment: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case comment, status }
    public let id: String
    public let itemID: String
    public let author: ItemAuthor
    public let deviceID: Int64
    public let kind: Kind
    public let body: String
    public let attachments: [TrackerAttachment]
    public let statusFrom: TrackerItem.StatusSnapshot?
    public let statusTo: TrackerItem.StatusSnapshot?
    public let createdAt: Date

    public init(id: String, itemID: String, author: ItemAuthor, deviceID: Int64 = 0, kind: Kind = .comment,
                body: String, attachments: [TrackerAttachment] = [], statusFrom: TrackerItem.StatusSnapshot? = nil,
                statusTo: TrackerItem.StatusSnapshot? = nil, createdAt: Date = Date()) {
        self.id = id; self.itemID = itemID; self.author = author; self.deviceID = deviceID; self.kind = kind
        self.body = body; self.attachments = attachments; self.statusFrom = statusFrom; self.statusTo = statusTo
        self.createdAt = createdAt
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let itemID = json["item_id"] as? String,
              let author = (json["author"] as? String).flatMap(ItemAuthor.init(rawValue:)),
              let kind = (json["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let createdAt = msDate(json["created_at"]) else { return nil }
        let meta = json["meta"] as? [String: Any]
        self.init(id: id, itemID: itemID, author: author, deviceID: (json["device_id"] as? NSNumber)?.int64Value ?? 0,
                  kind: kind, body: json["body"] as? String ?? "",
                  attachments: (json["attachments"] as? [[String: Any]] ?? []).compactMap(TrackerAttachment.init(json:)),
                  statusFrom: TrackerItem.StatusSnapshot(json: meta?["from"] as? [String: Any]),
                  statusTo: TrackerItem.StatusSnapshot(json: meta?["to"] as? [String: Any]), createdAt: createdAt)
    }
}
