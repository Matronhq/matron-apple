import Foundation
import GRDB
import MatronModels

// Tracker cache (spec 2026-09-08-items-tracker-apps, task 4). Records and
// queries for the `item` / `item_comment` / `item_outbox` tables created by
// migration v9 (JournalStore.swift). This cache is filled from GET /items
// responses (ItemsSync, a later task), never from the event log — the
// `item` marker event is only an invalidation signal.

private let itemsEncoder = JSONEncoder()
private let itemsDecoder = JSONDecoder()

/// `TrackerItem.createdAt`/`updatedAt` and `TrackerComment.createdAt` are
/// non-optional `Date`, so a non-optional overload avoids force-unwrapping
/// at every call site (there is a separate optional overload below for the
/// genuinely-optional fields like `closedAt`).
private func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
private func ms(_ d: Date?) -> Int64? { d.map { Int64($0.timeIntervalSince1970 * 1000) } }
private func date(_ v: Int64) -> Date { Date(timeIntervalSince1970: Double(v) / 1000) }
private func date(_ v: Int64?) -> Date? { v.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
private func enc<T: Encodable>(_ v: T) -> String { (try? String(data: itemsEncoder.encode(v), encoding: .utf8)) ?? "[]" }
private func dec<T: Decodable>(_ s: String, _ t: T.Type) -> T? { s.data(using: .utf8).flatMap { try? itemsDecoder.decode(t, from: $0) } }

public struct ItemRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "item"
    public var id: String; public var num: Int; public var kind: String; public var state: String
    public var resolution: String?; public var awaiting: String?; public var rank: Double
    public var title: String; public var body: String
    public var labelsJson: String; public var linksJson: String; public var attachmentsJson: String
    public var supersedes: String?; public var originConvoId: String; public var createdBy: String
    public var createdAt: Int64; public var updatedAt: Int64; public var closedAt: Int64?
    public var commentCount: Int; public var lastCommentAt: Int64?; public var hasImage: Bool

    enum CodingKeys: String, CodingKey {
        case id, num, kind, state, resolution, awaiting, rank, title, body, supersedes
        case labelsJson = "labels_json", linksJson = "links_json", attachmentsJson = "attachments_json"
        case originConvoId = "origin_convo_id", createdBy = "created_by", createdAt = "created_at"
        case updatedAt = "updated_at", closedAt = "closed_at", commentCount = "comment_count"
        case lastCommentAt = "last_comment_at", hasImage = "has_image"
    }

    public init(_ i: TrackerItem) {
        id = i.id; num = i.num; kind = i.kind.rawValue; state = i.state.rawValue; resolution = i.resolution?.rawValue
        awaiting = i.awaiting?.rawValue; rank = i.rank; title = i.title; body = i.body
        labelsJson = enc(i.labels); linksJson = enc(i.links); attachmentsJson = enc(i.attachments)
        supersedes = i.supersedes; originConvoId = i.originConvoID; createdBy = i.createdBy.rawValue
        createdAt = ms(i.createdAt); updatedAt = ms(i.updatedAt); closedAt = ms(i.closedAt)
        commentCount = i.commentCount; lastCommentAt = ms(i.lastCommentAt); hasImage = i.hasImage
    }

    public var item: TrackerItem {
        TrackerItem(id: id, num: num, kind: ItemKind(rawValue: kind) ?? .task, state: ItemState(rawValue: state) ?? .open,
                    resolution: resolution.flatMap(ItemResolution.init(rawValue:)), awaiting: awaiting.flatMap(ItemAwaiting.init(rawValue:)),
                    rank: rank, title: title, body: body, labels: dec(labelsJson, [String].self) ?? [],
                    links: dec(linksJson, [TrackerLink].self) ?? [], attachments: dec(attachmentsJson, [TrackerAttachment].self) ?? [],
                    supersedes: supersedes, originConvoID: originConvoId, createdBy: ItemAuthor(rawValue: createdBy) ?? .agent,
                    createdAt: date(createdAt), updatedAt: date(updatedAt), closedAt: date(closedAt),
                    commentCount: commentCount, lastCommentAt: date(lastCommentAt), hasImage: hasImage)
    }
}

public struct ItemCommentRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "item_comment"
    public var id: String; public var itemId: String; public var author: String; public var deviceId: Int64
    public var kind: String; public var body: String; public var attachmentsJson: String; public var metaJson: String?
    public var createdAt: Int64
    enum CodingKeys: String, CodingKey {
        case id, author, kind, body
        case itemId = "item_id", deviceId = "device_id", attachmentsJson = "attachments_json", metaJson = "meta_json", createdAt = "created_at"
    }
    private struct Meta: Codable { var from: Snap?; var to: Snap? }
    private struct Snap: Codable { var state: String?; var resolution: String?; var awaiting: String? }

    public init(_ c: TrackerComment) {
        id = c.id; itemId = c.itemID; author = c.author.rawValue; deviceId = c.deviceID; kind = c.kind.rawValue
        body = c.body; attachmentsJson = enc(c.attachments); createdAt = ms(c.createdAt)
        if c.statusFrom != nil || c.statusTo != nil {
            let snap = { (s: TrackerItem.StatusSnapshot?) in s.map { Snap(state: $0.state?.rawValue, resolution: $0.resolution?.rawValue, awaiting: $0.awaiting?.rawValue) } }
            metaJson = enc(Meta(from: snap(c.statusFrom), to: snap(c.statusTo)))
        } else { metaJson = nil }
    }

    public var comment: TrackerComment {
        let meta = metaJson.flatMap { dec($0, Meta.self) }
        let snap = { (s: Snap?) -> TrackerItem.StatusSnapshot? in
            s.map { .init(state: $0.state.flatMap(ItemState.init(rawValue:)), resolution: $0.resolution.flatMap(ItemResolution.init(rawValue:)), awaiting: $0.awaiting.flatMap(ItemAwaiting.init(rawValue:))) }
        }
        return TrackerComment(id: id, itemID: itemId, author: ItemAuthor(rawValue: author) ?? .agent, deviceID: deviceId,
                              kind: TrackerComment.Kind(rawValue: kind) ?? .comment, body: body,
                              attachments: dec(attachmentsJson, [TrackerAttachment].self) ?? [],
                              statusFrom: snap(meta?.from), statusTo: snap(meta?.to), createdAt: date(createdAt))
    }
}

public struct ItemOutboxRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    public static let databaseTableName = "item_outbox"
    public var localID: String; public var itemID: String?; public var op: String; public var payloadJSON: String
    public var createdAt: Int64; public var attempts: Int; public var lastError: String?
    enum CodingKeys: String, CodingKey {
        case op, attempts
        case localID = "local_id", itemID = "item_id", payloadJSON = "payload_json", createdAt = "created_at", lastError = "last_error"
    }
    public init(localID: String, itemID: String?, op: String, payloadJSON: String, createdAt: Int64, attempts: Int, lastError: String?) {
        self.localID = localID; self.itemID = itemID; self.op = op; self.payloadJSON = payloadJSON
        self.createdAt = createdAt; self.attempts = attempts; self.lastError = lastError
    }
}

public enum ItemsScope: Equatable, Hashable, Sendable { case convo(String), all }

extension JournalStore {
    public func upsertItems(_ items: [TrackerItem]) throws {
        guard !items.isEmpty else { return }
        try dbQueue.write { db in for i in items { try ItemRecord(i).save(db) } }
    }

    public func replaceComments(itemID: String, _ comments: [TrackerComment]) throws {
        try dbQueue.write { db in
            try ItemCommentRecord.filter(Column("item_id") == itemID).deleteAll(db)
            for c in comments { try ItemCommentRecord(c).insert(db) }
        }
    }

    public func item(id: String) throws -> TrackerItem? {
        try dbQueue.read { db in try ItemRecord.fetchOne(db, key: id)?.item }
    }

    private static func itemsRequest(_ scope: ItemsScope) -> QueryInterfaceRequest<ItemRecord> {
        switch scope {
        case .all: return ItemRecord.order(Column("rank"), Column("num"))
        case .convo(let id): return ItemRecord.filter(Column("origin_convo_id") == id).order(Column("rank"), Column("num"))
        }
    }

    public func items(scope: ItemsScope) throws -> [TrackerItem] {
        try dbQueue.read { db in try Self.itemsRequest(scope).fetchAll(db).map(\.item) }
    }

    public func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> {
        let observation = ValueObservation.tracking { db in try Self.itemsRequest(scope).fetchAll(db).map(\.item) }
        return Self.stream(observation, in: dbQueue)
    }

    public func itemStream(id: String) -> AsyncStream<TrackerItem?> {
        let observation = ValueObservation.tracking { db in try ItemRecord.fetchOne(db, key: id)?.item }
        return Self.stream(observation, in: dbQueue)
    }

    public func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> {
        let observation = ValueObservation.tracking { db in
            try ItemCommentRecord.filter(Column("item_id") == itemID).order(Column("created_at"), Column("id")).fetchAll(db).map(\.comment)
        }
        return Self.stream(observation, in: dbQueue)
    }

    public func itemsMaxUpdatedAt() throws -> Date? {
        try dbQueue.read { db in date(try Int64.fetchOne(db, sql: "SELECT MAX(updated_at) FROM item")) }
    }

    private static func needsUserCountsQuery(_ db: Database) throws -> [String: Int] {
        let rows = try Row.fetchAll(db, sql: "SELECT origin_convo_id AS c, COUNT(*) AS n FROM item WHERE state='open' AND awaiting='user' GROUP BY origin_convo_id")
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["c"] as String, $0["n"] as Int) })
    }

    /// App-local: counts open items awaiting the user, grouped by origin
    /// conversation. The journal has no equivalent endpoint — this is a
    /// derived read over the local cache only.
    public func needsUserCounts() throws -> [String: Int] { try dbQueue.read(Self.needsUserCountsQuery) }

    public func needsUserCountsStream() -> AsyncStream<[String: Int]> {
        Self.stream(ValueObservation.tracking(Self.needsUserCountsQuery), in: dbQueue)
    }

    public func itemOutboxInsert(_ rec: ItemOutboxRecord) throws { try dbQueue.write { db in try rec.insert(db) } }
    public func itemOutboxPending() throws -> [ItemOutboxRecord] {
        try dbQueue.read { db in try ItemOutboxRecord.order(Column("created_at")).fetchAll(db) }
    }
    public func itemOutboxRows(itemID: String) throws -> [ItemOutboxRecord] {
        try dbQueue.read { db in try ItemOutboxRecord.filter(Column("item_id") == itemID).order(Column("created_at")).fetchAll(db) }
    }
    public func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> {
        Self.stream(ValueObservation.tracking { db in
            try ItemOutboxRecord.filter(Column("item_id") == itemID).order(Column("created_at")).fetchAll(db)
        }, in: dbQueue)
    }
    public func itemOutboxMarkAttempt(localID: String, error: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE item_outbox SET attempts = attempts + 1, last_error = ? WHERE local_id = ?", arguments: [error, localID])
        }
    }
    public func itemOutboxDelete(localID: String) throws {
        try dbQueue.write { db in _ = try ItemOutboxRecord.deleteOne(db, key: localID) }
    }

    /// Also invoked inline (not via this method — see its doc comment) from
    /// `wipe()`, the full sign-out wipe. Kept as a standalone public entry
    /// point too so callers that only need the tracker cache cleared
    /// (without touching the event mirror) can call it directly.
    public func wipeItems() throws {
        try dbQueue.write { db in
            try ItemCommentRecord.deleteAll(db); try ItemRecord.deleteAll(db); try ItemOutboxRecord.deleteAll(db)
        }
    }
}
