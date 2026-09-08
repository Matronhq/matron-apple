import Foundation
import MatronModels

public struct ItemsListQuery: Equatable, Sendable {
    public enum Sort: String, Sendable { case rank, updated }
    public var convoID: String?
    public var kind: ItemKind?
    /// Optional and omitted from the query when nil — the journal has no
    /// `state=any`; leaving it off means "don't filter by state" server-side.
    public var state: ItemState?
    public var awaiting: ItemAwaiting?
    public var label: String?
    public var sort: Sort = .rank
    public var since: Date?
    public var limit: Int = 100
    public var cursor: String?
    public init() {}

    var queryItems: [URLQueryItem] {
        var q: [URLQueryItem] = [.init(name: "sort", value: sort.rawValue), .init(name: "limit", value: String(limit))]
        if let convoID { q.append(.init(name: "convo", value: convoID)) }
        if let kind { q.append(.init(name: "kind", value: kind.rawValue)) }
        if let state { q.append(.init(name: "state", value: state.rawValue)) }
        if let awaiting { q.append(.init(name: "awaiting", value: awaiting.rawValue)) }
        if let label { q.append(.init(name: "label", value: label)) }
        if let since { q.append(.init(name: "since", value: String(Int64(since.timeIntervalSince1970 * 1000)))) }
        if let cursor { q.append(.init(name: "cursor", value: cursor)) }
        return q
    }
}

public struct ItemsPage: Equatable, Sendable {
    public let items: [TrackerItem]
    public let nextCursor: String?
    public init(items: [TrackerItem], nextCursor: String?) { self.items = items; self.nextCursor = nextCursor }
}

/// Attachments never carry a transcript out of the app: the journal strips
/// the field on the way in anyway, and only the bridge is allowed to set
/// transcripts. Deliberately not `TrackerAttachment.json` (which does emit
/// `transcript` when present) — this always drops it, even if a caller's
/// local `TrackerAttachment` happens to have one set.
private func outgoingAttachmentJSON(_ a: TrackerAttachment) -> [String: Any] {
    ["blob_ref": a.blobRef, "mime": a.mime, "name": a.name, "size": a.size]
}

private func linkJSON(_ l: TrackerLink) -> [String: Any] {
    var d: [String: Any] = ["url": l.url]
    if let t = l.title { d["title"] = t }
    return d
}

public struct NewItem: Equatable, Sendable {
    public var kind: ItemKind
    public var title: String
    public var body: String
    public var labels: [String]
    public var links: [TrackerLink]
    public var attachments: [TrackerAttachment]
    public var awaiting: ItemAwaiting??
    public var position: String?
    public var convoID: String
    public var supersedes: String?
    public init(kind: ItemKind, title: String, body: String = "", labels: [String] = [], links: [TrackerLink] = [],
                attachments: [TrackerAttachment] = [], awaiting: ItemAwaiting?? = nil, position: String? = nil,
                convoID: String, supersedes: String? = nil) {
        self.kind = kind; self.title = title; self.body = body; self.labels = labels; self.links = links
        self.attachments = attachments; self.awaiting = awaiting; self.position = position; self.convoID = convoID
        self.supersedes = supersedes
    }
    var json: [String: Any] {
        var o: [String: Any] = ["kind": kind.rawValue, "title": title, "body": body, "convo_id": convoID]
        if !labels.isEmpty { o["labels"] = labels }
        if !links.isEmpty { o["links"] = links.map(linkJSON) }
        if !attachments.isEmpty { o["attachments"] = attachments.map(outgoingAttachmentJSON) }
        if let awaiting { o["awaiting"] = awaiting?.rawValue ?? NSNull() }
        if let position { o["position"] = position }
        if let supersedes { o["supersedes"] = supersedes }
        return o
    }
}

public struct ItemPatch: Equatable, Sendable {
    public var title: String?
    public var body: String?
    public var labels: [String]?
    public var links: [TrackerLink]?
    public var awaiting: ItemAwaiting??
    public init(title: String? = nil, body: String? = nil, labels: [String]? = nil, links: [TrackerLink]? = nil, awaiting: ItemAwaiting?? = nil) {
        self.title = title; self.body = body; self.labels = labels; self.links = links; self.awaiting = awaiting
    }
    var json: [String: Any] {
        var o: [String: Any] = [:]
        if let title { o["title"] = title }
        if let body { o["body"] = body }
        if let labels { o["labels"] = labels }
        if let links { o["links"] = links.map(linkJSON) }
        if let awaiting { o["awaiting"] = awaiting?.rawValue ?? NSNull() }
        return o
    }
}

public struct ItemRankChange: Equatable, Sendable {
    public var position: String?
    public var after: String?
    public var before: String?
    public init(position: String? = nil, after: String? = nil, before: String? = nil) {
        self.position = position; self.after = after; self.before = before
    }
    var json: [String: Any] {
        var o: [String: Any] = [:]
        if let position { o["position"] = position }
        if let after { o["after"] = after }
        if let before { o["before"] = before }
        return o
    }
}

public protocol ItemsProviding: Sendable {
    func listItems(_ query: ItemsListQuery) async throws -> ItemsPage
    func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment])
    func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem
    func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem
    func commentItem(id: String, body: String, attachments: [TrackerAttachment], idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment)
    func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem
    func reopenItem(id: String, comment: String?) async throws -> TrackerItem
    func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem
    func uploadMedia(_ data: Data, contentType: String) async throws -> String
}

extension JournalAPI: ItemsProviding {
    private func decodeItem(_ obj: [String: Any]) throws -> TrackerItem {
        guard let item = (obj["item"] as? [String: Any]).flatMap(TrackerItem.init(json:)) else {
            throw JournalAPIError.transport("malformed item response")
        }
        return item
    }

    public func listItems(_ query: ItemsListQuery) async throws -> ItemsPage {
        let obj = try await request(path: "/items", query: query.queryItems)
        let items = (obj["items"] as? [[String: Any]] ?? []).compactMap(TrackerItem.init(json:))
        return ItemsPage(items: items, nextCursor: obj["next_cursor"] as? String)
    }

    public func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) {
        let obj = try await request(path: "/items/\(Self.pathSegment(id))")
        let comments = (obj["comments"] as? [[String: Any]] ?? []).compactMap(TrackerComment.init(json:))
        return (try decodeItem(obj), comments)
    }

    public func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem {
        let headers = idempotencyKey.map { ["Idempotency-Key": $0] } ?? [:]
        return try decodeItem(try await request(path: "/items", method: "POST", body: new.json, accept: [200, 201], headers: headers))
    }

    public func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem {
        try decodeItem(try await request(path: "/items/\(Self.pathSegment(id))", method: "PATCH", body: patch.json))
    }

    public func commentItem(id: String, body: String, attachments: [TrackerAttachment], idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) {
        var json: [String: Any] = ["body": body]
        if !attachments.isEmpty { json["attachments"] = attachments.map(outgoingAttachmentJSON) }
        let headers = idempotencyKey.map { ["Idempotency-Key": $0] } ?? [:]
        let obj = try await request(path: "/items/\(Self.pathSegment(id))/comments", method: "POST", body: json, accept: [200, 201], headers: headers)
        guard let comment = (obj["comment"] as? [String: Any]).flatMap(TrackerComment.init(json:)) else {
            throw JournalAPIError.transport("malformed comment response")
        }
        return (try decodeItem(obj), comment)
    }

    public func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem {
        var json: [String: Any] = ["resolution": resolution.rawValue]
        if let comment { json["comment"] = comment }
        return try decodeItem(try await request(path: "/items/\(Self.pathSegment(id))/close", method: "POST", body: json))
    }

    public func reopenItem(id: String, comment: String?) async throws -> TrackerItem {
        var json: [String: Any] = [:]
        if let comment { json["comment"] = comment }
        return try decodeItem(try await request(path: "/items/\(Self.pathSegment(id))/reopen", method: "POST", body: json))
    }

    public func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem {
        try decodeItem(try await request(path: "/items/\(Self.pathSegment(id))/rank", method: "POST", body: change.json))
    }
}
