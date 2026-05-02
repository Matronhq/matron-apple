# Matron iOS — Phase 6 (Search) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Prereq:** Phase 5 (Custom events) merged and CI green.

**Goal:** Local full-text search across every chat. Each decrypted message text is indexed into SQLite FTS5. A unified search UI shows two sections — Chats (title/bot match) and Messages (FTS match) — with snippets and tap-to-open behaviour. Backfill runs asynchronously on first launch per room.

**Architecture:** New `MatronSearch` library with a `SearchService` protocol and a SQLite-backed `SearchServiceLive`. Indexing hook lives in `ChatServiceLive`'s timeline listener: every `m.text` (and tool-call result text) gets inserted into `messages_fts`. Backfill is a Task per room that paginates the SDK timeline backward until depth limit. UI: a `SearchView` invoked from the chat list's search bar.

**Tech Stack:** Same as prior phases. Use **GRDB.swift** (https://github.com/groue/GRDB.swift, MIT) for the SQLite wrapper — easier than raw `sqlite3` for FTS5 + WAL + Data Protection. No other new deps.

**Reference:** Spec §5.8 (search UX), §6.2 (decryption hook), §9 (search storage schema).

---

## File structure (Phase 6 deliverables)

```
matron-iOS-app/
├── MatronShared/Sources/Search/
│   ├── SearchService.swift                  NEW — protocol
│   ├── SearchServiceLive.swift              NEW — SQLite/GRDB impl
│   ├── SearchSchema.swift                   NEW — migrations
│   ├── SearchModels.swift                   NEW — DTOs (incl. BackfillProgress)
│   ├── TimelinePager.swift                  NEW — pagination seam (protocol + BackfillItem DTO)
│   ├── BackfillRunner.swift                 NEW — backfill loop, depends on TimelinePager
│   └── TimelinePagerLive.swift              NEW — SDK-backed pager (only file importing MatrixRustSDK)
├── MatronShared/Sources/Chat/
│   └── ChatServiceLive.swift                MODIFIED — call SearchService.index from timeline listener
├── Matron/Features/Search/
│   ├── SearchView.swift                     NEW
│   ├── SearchViewModel.swift                NEW
│   └── SearchResultRow.swift                NEW
├── Matron/Features/ChatList/
│   └── ChatListView.swift                   MODIFIED — searchBar + presentation
├── MatronShared/Tests/SearchTests/
│   ├── SearchSchemaTests.swift              NEW
│   ├── SearchServiceLiveTests.swift         NEW
│   └── BackfillTests.swift                  NEW
└── MatronTests/
    └── SearchViewModelTests.swift           NEW
```

---

## Tasks

### Task 1: Add GRDB and create MatronSearch library

**Files:**
- Modify: `MatronShared/Package.swift`
- Modify: `project.yml`

- [ ] **Step 1: Add dependency + library + test target**

```swift
.package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
```

```swift
.library(name: "MatronSearch", targets: ["MatronSearch"]),
.target(
    name: "MatronSearch",
    dependencies: [
        "MatronModels",
        "MatronStorage",
        .product(name: "GRDB", package: "GRDB.swift"),
    ],
    path: "Sources/Search"
),
.testTarget(name: "SearchTests", dependencies: ["MatronSearch"], path: "Tests/SearchTests"),
```

- [ ] **Step 2: Add MatronSearch to the Matron app target in project.yml**

```yaml
  - package: MatronShared
    product: MatronSearch
```

- [ ] **Step 3: Commit**

```bash
git add MatronShared/Package.swift project.yml
git commit -m "build: add GRDB.swift and MatronSearch library product"
git push
```

---

### Task 2: SearchSchema (migrations)

**Files:**
- Create: `MatronShared/Sources/Search/SearchSchema.swift`
- Create: `MatronShared/Tests/SearchTests/SearchSchemaTests.swift`

- [ ] **Step 1: Implement the migration**

> **Schema note:** FTS5's `DELETE … WHERE event_id = ?` is a silent no-op on `UNINDEXED` columns — the rows stay in the index. We instead use a content-table FTS5 design: a normal `messages` table holds the indexable columns, `messages_fts` is an FTS5 mirror of just `body` (with `content='messages'`), and triggers keep the two in sync. This makes `INSERT OR REPLACE INTO messages` and `DELETE FROM messages WHERE event_id = ?` behave correctly for idempotency and redactions.

```swift
import Foundation
import GRDB

public enum SearchSchema {
    public static func migrate(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1: messages + messages_fts + indexed_rooms") { db in
            try db.execute(sql: """
                CREATE TABLE messages (
                    rowid INTEGER PRIMARY KEY,
                    room_id TEXT NOT NULL,
                    event_id TEXT NOT NULL UNIQUE,
                    sender TEXT NOT NULL,
                    timestamp INTEGER NOT NULL,
                    body TEXT NOT NULL
                );
            """)
            try db.execute(sql: "CREATE INDEX idx_messages_event_id ON messages(event_id);")
            try db.execute(sql: "CREATE INDEX idx_messages_room_id ON messages(room_id);")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE messages_fts USING fts5(
                    body,
                    content='messages',
                    content_rowid='rowid',
                    tokenize='porter unicode61'
                );
            """)

            try db.execute(sql: """
                CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
                    INSERT INTO messages_fts(rowid, body) VALUES (new.rowid, new.body);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, body) VALUES('delete', old.rowid, old.body);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, body) VALUES('delete', old.rowid, old.body);
                    INSERT INTO messages_fts(rowid, body) VALUES (new.rowid, new.body);
                END;
            """)

            try db.execute(sql: """
                CREATE TABLE indexed_rooms (
                    room_id TEXT PRIMARY KEY,
                    backfill_complete INTEGER NOT NULL DEFAULT 0,
                    backfill_oldest_event_id TEXT,
                    backfill_event_count INTEGER NOT NULL DEFAULT 0
                );
            """)
        }
    }

    /// Opens (or creates) a database at `path` with Data Protection set to complete.
    /// The protection attribute is applied at file-creation time so the file is never
    /// briefly written without it.
    public static func makeDatabase(at path: URL) throws -> DatabaseQueue {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Pre-create the file with NSFileProtectionComplete so the attribute is set
        // before GRDB writes any bytes. setAttributes-after-open leaves a small window
        // where the file exists without protection.
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(
                atPath: path.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(path: path.path, configuration: config)
        // Defensive check: confirm protection is set on the resulting file.
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        assert((attrs[.protectionKey] as? FileProtectionType) == .complete, "matron-search.sqlite missing NSFileProtectionComplete")
        var migrator = DatabaseMigrator()
        migrate(&migrator)
        try migrator.migrate(queue)
        return queue
    }
}
```

- [ ] **Step 2: Tests**

```swift
import XCTest
import GRDB
@testable import MatronSearch

final class SearchSchemaTests: XCTestCase {
    var dbURL: URL!

    override func setUp() {
        dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("matron-search-test-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dbURL)
    }

    func test_migrationCreatesTables() throws {
        let queue = try SearchSchema.makeDatabase(at: dbURL)
        try queue.read { db in
            let messages = try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE name = 'messages'")
            XCTAssertEqual(messages, true)
            let fts = try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE name = 'messages_fts'")
            XCTAssertEqual(fts, true)
            let rooms = try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE name = 'indexed_rooms'")
            XCTAssertEqual(rooms, true)
        }
    }

    func test_canInsertAndQueryFTS() throws {
        let queue = try SearchSchema.makeDatabase(at: dbURL)
        try queue.write { db in
            // Insert into messages — the AFTER INSERT trigger mirrors body into messages_fts.
            try db.execute(sql: "INSERT INTO messages(room_id, event_id, sender, timestamp, body) VALUES (?, ?, ?, ?, ?)",
                           arguments: ["!r:s", "$1", "@a:s", 1745000000, "the quick brown fox jumps over the lazy dog"])
        }
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'fox'")
            XCTAssertEqual(count, 1)
        }
    }

    func test_deleteRemovesFromFTS() throws {
        // Verifies the AFTER DELETE trigger keeps messages_fts in sync — this is the
        // bug that motivated switching to the content-table design.
        let queue = try SearchSchema.makeDatabase(at: dbURL)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO messages(room_id, event_id, sender, timestamp, body) VALUES (?, ?, ?, ?, ?)",
                           arguments: ["!r:s", "$1", "@a:s", 1745000000, "secret payload"])
            try db.execute(sql: "DELETE FROM messages WHERE event_id = ?", arguments: ["$1"])
        }
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'secret'")
            XCTAssertEqual(count, 0)
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
cd MatronShared && swift test --filter SearchSchemaTests
git add MatronShared/Sources/Search/SearchSchema.swift MatronShared/Tests/SearchTests/SearchSchemaTests.swift
git commit -m "feat: SearchSchema with FTS5 messages table and indexed_rooms tracker"
git push
```

---

### Task 3: SearchModels — DTOs

**Files:**
- Create: `MatronShared/Sources/Search/SearchModels.swift`

- [ ] **Step 1: Define DTOs**

```swift
import Foundation

public struct SearchHit: Equatable, Identifiable, Sendable {
    public let id: String                  // event ID
    public let roomID: String
    public let sender: String
    public let timestamp: Date
    public let snippet: String             // contains <mark>…</mark> markup

    public init(id: String, roomID: String, sender: String, timestamp: Date, snippet: String) {
        self.id = id; self.roomID = roomID; self.sender = sender; self.timestamp = timestamp; self.snippet = snippet
    }
}

public struct BackfillProgress: Equatable, Sendable {
    public let roomID: String
    public let eventsIndexed: Int
    public let isComplete: Bool

    public init(roomID: String, eventsIndexed: Int, isComplete: Bool) {
        self.roomID = roomID; self.eventsIndexed = eventsIndexed; self.isComplete = isComplete
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add MatronShared/Sources/Search/SearchModels.swift
git commit -m "feat: SearchHit + BackfillProgress DTOs"
git push
```

---

### Task 4: SearchService protocol + Live impl

**Files:**
- Create: `MatronShared/Sources/Search/SearchService.swift`
- Create: `MatronShared/Sources/Search/SearchServiceLive.swift`
- Create: `MatronShared/Tests/SearchTests/SearchServiceLiveTests.swift`

- [ ] **Step 1: Protocol**

```swift
import Foundation

public protocol SearchService: Sendable {
    /// Inserts a single message into the index. Idempotent on (roomID, eventID).
    func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws

    /// Removes a single event (used for redactions).
    func remove(eventID: String) async throws

    /// Queries by free-text. Returns at most `limit` hits, newest first.
    func query(_ text: String, limit: Int) async throws -> [SearchHit]

    /// Wipes all data (used on sign-out).
    func wipe() async throws

    /// Records progress for a room's backfill.
    func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws

    /// True if backfill has previously completed for `roomID`.
    func backfillComplete(roomID: String) async throws -> Bool

    /// Number of indexed events for `roomID` (used by BackfillRunner to resume).
    func eventCount(roomID: String) async throws -> Int

    /// True if an event with `eventID` is already indexed (used by BackfillRunner to skip duplicates).
    func contains(eventID: String) async throws -> Bool
}
```

- [ ] **Step 2: Implementation**

```swift
import Foundation
import GRDB

public final class SearchServiceLive: SearchService, @unchecked Sendable {
    private let queue: DatabaseQueue

    public init(databaseURL: URL) throws {
        self.queue = try SearchSchema.makeDatabase(at: databaseURL)
    }

    public func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {
        try await queue.write { db in
            // INSERT OR REPLACE on `messages` fires the AFTER DELETE + AFTER INSERT triggers,
            // keeping messages_fts in sync. event_id is UNIQUE so a re-index of the same event
            // produces a fresh row (and a refreshed FTS entry) — true idempotency.
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO messages(room_id, event_id, sender, timestamp, body)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [roomID, eventID, sender, Int(timestamp.timeIntervalSince1970), body]
            )
        }
    }

    public func remove(eventID: String) async throws {
        try await queue.write { db in
            // DELETE on `messages` fires the AFTER DELETE trigger which removes the FTS row.
            try db.execute(sql: "DELETE FROM messages WHERE event_id = ?", arguments: [eventID])
        }
    }

    public func query(_ text: String, limit: Int) async throws -> [SearchHit] {
        let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
        let pattern = "\"\(escaped)\"*"
        return try await queue.read { db in
            // FTS5 now contains only `body` (column index 0). Sender/timestamp/room_id
            // come from the joined `messages` table.
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.room_id, m.event_id, m.sender, m.timestamp,
                       snippet(messages_fts, 0, '<mark>', '</mark>', '…', 32) AS snippet
                FROM messages_fts
                JOIN messages m ON m.rowid = messages_fts.rowid
                WHERE messages_fts MATCH ?
                ORDER BY m.timestamp DESC
                LIMIT ?
            """, arguments: [pattern, limit])

            return rows.map { row in
                SearchHit(
                    id: row["event_id"],
                    roomID: row["room_id"],
                    sender: row["sender"],
                    timestamp: Date(timeIntervalSince1970: TimeInterval(row["timestamp"] as Int)),
                    snippet: row["snippet"]
                )
            }
        }
    }

    public func wipe() async throws {
        try await queue.write { db in
            // Deleting from `messages` fires the AFTER DELETE trigger for each row,
            // keeping messages_fts in sync.
            try db.execute(sql: "DELETE FROM messages")
            try db.execute(sql: "DELETE FROM indexed_rooms")
        }
    }

    public func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO indexed_rooms(room_id, backfill_complete, backfill_oldest_event_id, backfill_event_count)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(room_id) DO UPDATE SET
                    backfill_complete = excluded.backfill_complete,
                    backfill_oldest_event_id = excluded.backfill_oldest_event_id,
                    backfill_event_count = excluded.backfill_event_count
            """, arguments: [roomID, complete ? 1 : 0, oldestEventID, indexedCount])
        }
    }

    public func backfillComplete(roomID: String) async throws -> Bool {
        try await queue.read { db in
            let value = try Int.fetchOne(db, sql: "SELECT backfill_complete FROM indexed_rooms WHERE room_id = ?", arguments: [roomID]) ?? 0
            return value == 1
        }
    }

    public func eventCount(roomID: String) async throws -> Int {
        try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE room_id = ?", arguments: [roomID]) ?? 0
        }
    }

    public func contains(eventID: String) async throws -> Bool {
        try await queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT 1 FROM messages WHERE event_id = ?", arguments: [eventID])) != nil
        }
    }
}
```

- [ ] **Step 3: Tests**

```swift
import XCTest
@testable import MatronSearch

final class SearchServiceLiveTests: XCTestCase {
    var url: URL!
    var svc: SearchServiceLive!

    override func setUp() async throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("svc-\(UUID().uuidString).sqlite")
        svc = try SearchServiceLive(databaseURL: url)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url)
    }

    func test_indexAndQuery_roundTrip_preservesAllFields() async throws {
        let ts = Date(timeIntervalSince1970: 1_745_000_000)
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s",
                            timestamp: ts, body: "the auth bug is in src/auth.rs")
        let hits = try await svc.query("auth bug", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].id, "$1")
        XCTAssertEqual(hits[0].roomID, "!r:s")
        XCTAssertEqual(hits[0].sender, "@a:s")
        XCTAssertEqual(hits[0].timestamp.timeIntervalSince1970, ts.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertTrue(hits[0].snippet.contains("<mark>auth"))
    }

    func test_indexIsIdempotent_replaceUpdatesBody() async throws {
        // Re-indexing the same eventID must replace the old row in BOTH messages and
        // messages_fts. This guards against the FTS5 UNINDEXED-DELETE silent no-op.
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: Date(), body: "first")
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: Date(), body: "second")
        let hits = try await svc.query("first", limit: 10)
        XCTAssertEqual(hits.count, 0, "old body must not remain in FTS after re-index")
        let hits2 = try await svc.query("second", limit: 10)
        XCTAssertEqual(hits2.count, 1)
    }

    func test_remove_clearsFTSRow() async throws {
        // Redaction path: `remove(eventID:)` must purge both messages and messages_fts.
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: Date(), body: "secret payload")
        try await svc.remove(eventID: "$1")
        let hits = try await svc.query("secret", limit: 10)
        XCTAssertEqual(hits.count, 0, "redacted event must no longer match in FTS")
        let exists = try await svc.contains(eventID: "$1")
        XCTAssertFalse(exists)
    }

    func test_eventCount_perRoom() async throws {
        try await svc.index(roomID: "!a:s", eventID: "$1", sender: "@x:s", timestamp: Date(), body: "one")
        try await svc.index(roomID: "!a:s", eventID: "$2", sender: "@x:s", timestamp: Date(), body: "two")
        try await svc.index(roomID: "!b:s", eventID: "$3", sender: "@x:s", timestamp: Date(), body: "three")
        let a = try await svc.eventCount(roomID: "!a:s")
        let b = try await svc.eventCount(roomID: "!b:s")
        XCTAssertEqual(a, 2)
        XCTAssertEqual(b, 1)
    }

    func test_recordAndReadBackfill() async throws {
        try await svc.recordBackfillProgress(roomID: "!r:s", indexedCount: 100, oldestEventID: "$old", complete: true)
        let done = try await svc.backfillComplete(roomID: "!r:s")
        XCTAssertTrue(done)
    }
}
```

- [ ] **Step 4: Commit**

```bash
cd MatronShared && swift test --filter SearchServiceLiveTests
git add MatronShared/Sources/Search/SearchService.swift MatronShared/Sources/Search/SearchServiceLive.swift \
        MatronShared/Tests/SearchTests/SearchServiceLiveTests.swift
git commit -m "feat: SearchService protocol + GRDB-backed Live impl"
git push
```

---

### Task 5: Wire indexing into ChatServiceLive timeline listener

**Files:**
- Modify: `MatronShared/Sources/Chat/ChatServiceLive.swift`

- [ ] **Step 1: ChatServiceLive accepts an optional `SearchService`**

```swift
public init(provider: ClientProvider, session: UserSession, search: SearchService? = nil) {
    self.provider = provider
    self.session = session
    self.search = search
}
```

- [ ] **Step 2: In the per-room timeline listener (Phase 2 Task 5), call `search?.index(...)` for every `.text` event**

```swift
// Inside TimelineListener.onUpdate:
for item in newItems {
    if case .text(let body, _) = item.kind, let search = self.search {
        Task {
            try? await search.index(
                roomID: roomID, eventID: item.id,
                sender: item.sender, timestamp: item.timestamp, body: body
            )
        }
    }
    // For tool_call results too:
    if case .toolCall(let eventID, let evt) = item.kind, let search = self.search,
       let result = evt.resultText {
        Task {
            try? await search.index(
                roomID: roomID, eventID: eventID,
                sender: item.sender, timestamp: item.timestamp,
                body: "[\(evt.tool)] \(result)"
            )
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git commit -am "feat: ChatServiceLive indexes text + tool_call results into SearchService"
git push
```

---

### Task 6: BackfillRunner — async backfill per room

**Files:**
- Create: `MatronShared/Sources/Search/TimelinePager.swift`
- Create: `MatronShared/Sources/Search/BackfillRunner.swift`
- Create: `MatronShared/Sources/Search/TimelinePagerLive.swift`
- Create: `MatronShared/Tests/SearchTests/BackfillTests.swift`

- [ ] **Step 1: Failing test first — define a fake `TimelinePager` and assert backfill behaviour**

Per TDD: write the test before the implementation, against a `TimelinePager` protocol the runner depends on. The fake yields three batches, mixing indexable and non-indexable items, plus duplicates of an already-indexed event.

```swift
import XCTest
import GRDB
@testable import MatronSearch

/// Minimal fake pager: returns pre-canned batches in order, then `hitStartOfTimeline = true`.
actor FakePager: TimelinePager {
    var batches: [[BackfillItem]]
    var hitStartAfterLast: Bool

    init(batches: [[BackfillItem]], hitStartAfterLast: Bool = true) {
        self.batches = batches
        self.hitStartAfterLast = hitStartAfterLast
    }

    func paginateBackward(roomID: String, batchSize: Int) async throws -> (items: [BackfillItem], hitStartOfTimeline: Bool) {
        if batches.isEmpty { return ([], hitStartAfterLast) }
        let next = batches.removeFirst()
        return (next, batches.isEmpty && hitStartAfterLast)
    }
}

final class BackfillTests: XCTestCase {
    var url: URL!
    var svc: SearchServiceLive!

    override func setUp() async throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bf-\(UUID().uuidString).sqlite")
        svc = try SearchServiceLive(databaseURL: url)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url)
    }

    func test_recordsProgressAndCompletion() async throws {
        try await svc.recordBackfillProgress(roomID: "!r:s", indexedCount: 20, oldestEventID: "$o", complete: false)
        XCTAssertFalse(try await svc.backfillComplete(roomID: "!r:s"))

        try await svc.recordBackfillProgress(roomID: "!r:s", indexedCount: 50, oldestEventID: "$o2", complete: true)
        XCTAssertTrue(try await svc.backfillComplete(roomID: "!r:s"))
    }

    func test_backfill_indexesAllIndexableEventsAcrossBatches_andTracksOldest() async throws {
        // Three batches, walking backward in time. Mix in one non-indexable item per batch
        // (image/state/etc) — the runner must skip those.
        let now = Date(timeIntervalSince1970: 1_745_000_000)
        let batches: [[BackfillItem]] = [
            [
                BackfillItem(eventID: "$3", sender: "@a:s", timestamp: now.addingTimeInterval(-30), body: "third newest", indexable: true),
                BackfillItem(eventID: "$skipA", sender: "@a:s", timestamp: now.addingTimeInterval(-31), body: "", indexable: false),
            ],
            [
                BackfillItem(eventID: "$2", sender: "@a:s", timestamp: now.addingTimeInterval(-60), body: "older mid", indexable: true),
            ],
            [
                BackfillItem(eventID: "$1", sender: "@a:s", timestamp: now.addingTimeInterval(-90), body: "oldest event", indexable: true),
                BackfillItem(eventID: "$skipB", sender: "@a:s", timestamp: now.addingTimeInterval(-91), body: "", indexable: false),
            ],
        ]
        let pager = FakePager(batches: batches)
        let runner = BackfillRunner(timeline: pager, search: svc)

        try await runner.backfill(roomID: "!r:s", depthLimit: 1000, sinceCutoff: .distantPast)

        // All three indexable events present.
        XCTAssertEqual(try await svc.eventCount(roomID: "!r:s"), 3)
        XCTAssertEqual(try await svc.query("oldest", limit: 10).count, 1)
        XCTAssertEqual(try await svc.query("mid", limit: 10).count, 1)

        // Oldest tracked correctly + completion flag set.
        XCTAssertTrue(try await svc.backfillComplete(roomID: "!r:s"))
        // (We can't introspect oldestEventID directly via the protocol; verify via SQL.)
        let queue = try DatabaseQueue(path: url.path)
        try await queue.read { db in
            let oldest = try String.fetchOne(db, sql: "SELECT backfill_oldest_event_id FROM indexed_rooms WHERE room_id = ?", arguments: ["!r:s"])
            XCTAssertEqual(oldest, "$1")
        }
    }

    func test_backfill_skipsAlreadyIndexedEvents() async throws {
        let now = Date(timeIntervalSince1970: 1_745_000_000)
        // Pre-index $1 with body "previous-body".
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s",
                            timestamp: now.addingTimeInterval(-90), body: "previous-body")
        let batches: [[BackfillItem]] = [
            [
                BackfillItem(eventID: "$1", sender: "@a:s", timestamp: now.addingTimeInterval(-90), body: "stale-overwrite", indexable: true),
                BackfillItem(eventID: "$2", sender: "@a:s", timestamp: now.addingTimeInterval(-60), body: "fresh", indexable: true),
            ],
        ]
        let runner = BackfillRunner(timeline: FakePager(batches: batches), search: svc)
        try await runner.backfill(roomID: "!r:s", depthLimit: 1000, sinceCutoff: .distantPast)

        // $1 must not be re-indexed (still has "previous-body"), $2 added.
        XCTAssertEqual(try await svc.query("previous-body", limit: 10).count, 1)
        XCTAssertEqual(try await svc.query("stale-overwrite", limit: 10).count, 0)
        XCTAssertEqual(try await svc.query("fresh", limit: 10).count, 1)
    }

    func test_backfill_honoursDepthLimit() async throws {
        let now = Date(timeIntervalSince1970: 1_745_000_000)
        // Five indexable events in one batch, but depth limit = 3.
        let batches: [[BackfillItem]] = [
            (1...5).map {
                BackfillItem(eventID: "$\($0)", sender: "@a:s", timestamp: now.addingTimeInterval(Double(-$0) * 10), body: "msg-\($0)", indexable: true)
            }
        ]
        let runner = BackfillRunner(timeline: FakePager(batches: batches, hitStartAfterLast: false), search: svc)
        try await runner.backfill(roomID: "!r:s", depthLimit: 3, sinceCutoff: .distantPast)

        XCTAssertEqual(try await svc.eventCount(roomID: "!r:s"), 3)
    }

    func test_backfill_stopsAtSinceCutoff() async throws {
        let now = Date(timeIntervalSince1970: 1_745_000_000)
        let cutoff = now.addingTimeInterval(-45) // accept events newer than this
        // Two events newer than cutoff, two older. Older must NOT be indexed.
        let batches: [[BackfillItem]] = [
            [
                BackfillItem(eventID: "$new1", sender: "@a:s", timestamp: now.addingTimeInterval(-10), body: "new1", indexable: true),
                BackfillItem(eventID: "$new2", sender: "@a:s", timestamp: now.addingTimeInterval(-30), body: "new2", indexable: true),
                BackfillItem(eventID: "$old1", sender: "@a:s", timestamp: now.addingTimeInterval(-60), body: "old1", indexable: true),
                BackfillItem(eventID: "$old2", sender: "@a:s", timestamp: now.addingTimeInterval(-90), body: "old2", indexable: true),
            ]
        ]
        let runner = BackfillRunner(timeline: FakePager(batches: batches, hitStartAfterLast: false), search: svc)
        try await runner.backfill(roomID: "!r:s", depthLimit: 1000, sinceCutoff: cutoff)

        XCTAssertEqual(try await svc.query("new1", limit: 10).count, 1)
        XCTAssertEqual(try await svc.query("new2", limit: 10).count, 1)
        XCTAssertEqual(try await svc.query("old1", limit: 10).count, 0)
        XCTAssertEqual(try await svc.query("old2", limit: 10).count, 0)
    }
}
```

- [ ] **Step 2: Define `TimelinePager` protocol + `BackfillItem` DTO**

`TimelinePager` is the seam between `BackfillRunner` and the SDK. Tests pass a fake; production uses `TimelinePagerLive` which wraps `MatrixRustSDK`.

```swift
import Foundation

public struct BackfillItem: Sendable {
    public let eventID: String
    public let sender: String
    public let timestamp: Date
    public let body: String
    /// Text events and tool-call results are indexable. Images, state, redactions are not.
    public let indexable: Bool

    public init(eventID: String, sender: String, timestamp: Date, body: String, indexable: Bool) {
        self.eventID = eventID; self.sender = sender; self.timestamp = timestamp
        self.body = body; self.indexable = indexable
    }
}

public protocol TimelinePager: Sendable {
    /// Paginate one batch backward. Returns the new items revealed and whether
    /// the start of the timeline was reached.
    func paginateBackward(roomID: String, batchSize: Int) async throws -> (items: [BackfillItem], hitStartOfTimeline: Bool)
}
```

- [ ] **Step 3: Implement `BackfillRunner` with a real loop**

```swift
import Foundation

public final class BackfillRunner: @unchecked Sendable {
    private let timeline: TimelinePager
    private let search: SearchService

    public init(timeline: TimelinePager, search: SearchService) {
        self.timeline = timeline
        self.search = search
    }

    /// Indexes history for `roomID` until depth limit, sinceCutoff, or start-of-timeline.
    /// `sinceCutoff` is the oldest timestamp we care about — once an indexable event is
    /// older than this, the loop terminates.
    public func backfill(roomID: String, depthLimit: Int = 1000, sinceCutoff: Date) async throws {
        if try await search.backfillComplete(roomID: roomID) { return }

        // Resume-aware: count what's already indexed for this room.
        var indexedCount = (try? await search.eventCount(roomID: roomID)) ?? 0
        var oldestEventID: String? = nil
        var oldestTimestamp: Date = .distantFuture

        outer: while indexedCount < depthLimit {
            let result = try await timeline.paginateBackward(roomID: roomID, batchSize: 50)
            if result.items.isEmpty { break }

            for item in result.items where item.indexable {
                if try await search.contains(eventID: item.eventID) { continue }
                try await search.index(
                    roomID: roomID,
                    eventID: item.eventID,
                    sender: item.sender,
                    timestamp: item.timestamp,
                    body: item.body
                )
                indexedCount += 1
                if item.timestamp < oldestTimestamp {
                    oldestTimestamp = item.timestamp
                    oldestEventID = item.eventID
                }
                if oldestTimestamp < sinceCutoff { break outer }
                if indexedCount >= depthLimit { break outer }
            }

            if result.hitStartOfTimeline { break }
            if oldestTimestamp < sinceCutoff { break }
        }

        try await search.recordBackfillProgress(
            roomID: roomID,
            indexedCount: indexedCount,
            oldestEventID: oldestEventID,
            complete: true
        )
    }
}
```

- [ ] **Step 4: Production `TimelinePagerLive` wraps the SDK**

Lives next to `BackfillRunner` and is the only file that imports `MatrixRustSDK`. Keeping the SDK out of `BackfillRunner` makes the tests above possible.

```swift
import Foundation
import MatronSync
import MatronModels
import MatrixRustSDK

public final class TimelinePagerLive: TimelinePager, @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession

    public init(provider: ClientProvider, session: UserSession) {
        self.provider = provider
        self.session = session
    }

    public func paginateBackward(roomID: String, batchSize: Int) async throws -> (items: [BackfillItem], hitStartOfTimeline: Bool) {
        let client = try await provider.client(for: session)
        let room = try await client.getRoom(roomId: roomID)
        let timeline = try await room.timeline()
        let result = try await timeline.paginateBackwards(opts: .untilNumItems(eventLimit: UInt16(batchSize), items: UInt16(batchSize)))
        // Implementer: convert SDK items to `BackfillItem`s. Map `.text` and tool-call
        // result text to `indexable: true`; everything else to `indexable: false`.
        // The exact accessor name may vary by SDK version — adjust per Package.resolved.
        let items: [BackfillItem] = [] // TODO: map from result/timeline snapshot
        return (items, result.hitStartOfTimeline ?? false)
    }
}
```

> **Implementer note:** the SDK's pagination + snapshot APIs are the most volatile part of this task. The shape above (paginate → walk → record progress → repeat) is what matters; adjust the SDK-mapping inside `TimelinePagerLive` to match `Package.resolved`. `BackfillRunner` itself is fully covered by the fake-pager tests above.

- [ ] **Step 5: Commit**

```bash
cd MatronShared && swift test --filter BackfillTests
git add MatronShared/Sources/Search/TimelinePager.swift \
        MatronShared/Sources/Search/BackfillRunner.swift \
        MatronShared/Sources/Search/TimelinePagerLive.swift \
        MatronShared/Tests/SearchTests/BackfillTests.swift
git commit -m "feat: BackfillRunner indexes existing room history per-room"
git push
```

---

### Task 7: AppDependencies wires SearchService and triggers backfill

**Files:**
- Modify: `Matron/App/AppDependencies.swift`
- Modify: `Matron/App/MatronApp.swift`

- [ ] **Step 1: Add `search` to dependencies**

```swift
let search: SearchService

init() throws {
    let container = AppGroup.containerURL
        ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("matron-fallback")
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    let dbURL = AppGroup.searchDBPath(in: container)
    self.search = try SearchServiceLive(databaseURL: dbURL)
    // ... existing inits
}

func chatService(for session: UserSession) -> ChatService {
    ChatServiceLive(provider: clientProvider, session: session, search: search)
}
```

- [ ] **Step 2: After sign-in, kick off backfill for every known room**

Construct a `BackfillRunner` once per signed-in session, wired with the SDK-backed `TimelinePagerLive`:

```swift
let pager = TimelinePagerLive(provider: clientProvider, session: session)
let runner = BackfillRunner(timeline: pager, search: search)
let cutoff = Date().addingTimeInterval(-90 * 86_400) // 90-day window per spec §9.3
```

In `MatronApp`'s post-login `.task`, observe the chat list snapshot once and queue `runner.backfill(roomID:depthLimit:sinceCutoff:)` for each room. Run them serially (or `withTaskGroup` of N=2 concurrent) to avoid hammering the homeserver. Surface aggregate progress (rooms completed / rooms total) via an `AsyncStream<AggregateBackfillProgress>` consumed by `SearchViewModel.observeBackfill(_:)` — see Task 8 Step 6.

- [ ] **Step 3: On sign-out, call `search.wipe()`**

Wire into the sign-out flow.

- [ ] **Step 4: Commit**

```bash
git commit -am "feat: AppDependencies owns SearchService + kicks off backfill per room"
git push
```

---

### Task 8: SearchViewModel + SearchView

**Files:**
- Create: `Matron/Features/Search/SearchViewModel.swift`
- Create: `Matron/Features/Search/SearchView.swift`
- Create: `Matron/Features/Search/SearchResultRow.swift`
- Create: `MatronTests/SearchViewModelTests.swift`

- [ ] **Step 1: ViewModel tests (failing first, per TDD)**

```swift
import XCTest
@testable import Matron
import MatronSearch
import MatronChat
import MatronModels

actor FakeSearchService: SearchService {
    var hits: [SearchHit] = []
    func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {}
    func remove(eventID: String) async throws {}
    func query(_ text: String, limit: Int) async throws -> [SearchHit] { hits }
    func wipe() async throws {}
    func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {}
    func backfillComplete(roomID: String) async throws -> Bool { true }
    func eventCount(roomID: String) async throws -> Int { 0 }
    func contains(eventID: String) async throws -> Bool { false }
}

final class SearchViewModelTests: XCTestCase {
    @MainActor
    func test_query_populatesResults() async {
        let fakeSearch = FakeSearchService()
        await fakeSearch.hits = [
            SearchHit(id: "$1", roomID: "!r:s", sender: "@a:s", timestamp: Date(), snippet: "<mark>hello</mark> world")
        ]
        let vm = SearchViewModel(search: fakeSearch, allChats: [])
        vm.query = "hello"
        await vm.search()
        XCTAssertEqual(vm.messageHits.count, 1)
    }

    @MainActor
    func test_chatHits_filterByTitleOrBotName() {
        let claude = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        let chats = [
            ChatSummary(id: "!1:s", title: "Auth bug", bot: claude, lastActivity: Date(), unreadCount: 0),
            ChatSummary(id: "!2:s", title: "Refactor", bot: claude, lastActivity: Date(), unreadCount: 0),
        ]
        let vm = SearchViewModel(search: FakeSearchService(), allChats: chats)
        vm.query = "auth"
        XCTAssertEqual(vm.chatHits.map(\.id), ["!1:s"])
    }

    @MainActor
    func test_chatTitle_resolvesViaAllChats() {
        let claude = BotIdentity(matrixID: "@claude:s", displayName: "Claude", avatarURL: nil)
        let chats = [
            ChatSummary(id: "!a:s", title: "Auth bug", bot: claude, lastActivity: Date(), unreadCount: 0),
            ChatSummary(id: "!b:s", title: "Refactor", bot: claude, lastActivity: Date(), unreadCount: 0),
        ]
        let vm = SearchViewModel(search: FakeSearchService(), allChats: chats)
        XCTAssertEqual(vm.chatTitle(for: "!a:s"), "Auth bug")
        XCTAssertEqual(vm.chatTitle(for: "!b:s"), "Refactor")
        XCTAssertEqual(vm.chatTitle(for: "!unknown:s"), "!unknown:s", "falls back to room ID when not found")
    }

    @MainActor
    func test_emptyState_whenBackfillInProgress_showsIndexingMessage() async {
        let vm = SearchViewModel(search: FakeSearchService(), allChats: [])
        vm.query = "anything"
        vm.applyBackfillProgress(.init(roomsCompleted: 3, roomsTotal: 10))
        await vm.search()
        XCTAssertEqual(vm.emptyResultsMessage, "Indexing chats… (3 of 10 rooms)")
    }

    @MainActor
    func test_emptyState_whenBackfillComplete_showsNoResults() async {
        let vm = SearchViewModel(search: FakeSearchService(), allChats: [])
        vm.query = "anything"
        vm.applyBackfillProgress(.init(roomsCompleted: 10, roomsTotal: 10))
        await vm.search()
        XCTAssertEqual(vm.emptyResultsMessage, "No results.")
    }
}
```

- [ ] **Step 2: ViewModel**

```swift
import Foundation
import MatronSearch
import MatronChat
import MatronModels

/// Aggregate backfill progress across all rooms (different from MatronSearch.BackfillProgress
/// which is per-room). Surfaced to the UI for the "Indexing chats…" empty state.
struct AggregateBackfillProgress: Equatable, Sendable {
    let roomsCompleted: Int
    let roomsTotal: Int
    var inProgress: Bool { roomsCompleted < roomsTotal }
}

@Observable
@MainActor
final class SearchViewModel {
    var query: String = ""
    private(set) var messageHits: [SearchHit] = []
    private(set) var isSearching = false
    private(set) var backfillProgress: AggregateBackfillProgress?

    let allChats: [ChatSummary]
    private let search: SearchService

    init(search: SearchService, allChats: [ChatSummary]) {
        self.search = search
        self.allChats = allChats
    }

    var chatHits: [ChatSummary] {
        guard !query.isEmpty else { return [] }
        let lower = query.lowercased()
        return allChats.filter {
            $0.title.lowercased().contains(lower) || $0.bot.displayName.lowercased().contains(lower)
        }
    }

    /// Resolves a room ID to its display title using `allChats`. Falls back to the raw
    /// room ID if the chat isn't in the snapshot (e.g. a search hit from a left room).
    func chatTitle(for roomID: String) -> String {
        allChats.first(where: { $0.id == roomID })?.title ?? roomID
    }

    /// Text to display when the query has no chat or message hits.
    /// During an in-progress backfill, "Indexing chats… (X of Y rooms)" is more accurate
    /// than "No results." since older messages may simply not be indexed yet.
    var emptyResultsMessage: String {
        if let p = backfillProgress, p.inProgress {
            return "Indexing chats… (\(p.roomsCompleted) of \(p.roomsTotal) rooms)"
        }
        return "No results."
    }

    func applyBackfillProgress(_ progress: AggregateBackfillProgress) {
        self.backfillProgress = progress
    }

    /// Subscribes to the runner's progress stream and republishes onto this @MainActor VM.
    func observeBackfill(_ stream: AsyncStream<AggregateBackfillProgress>) async {
        for await progress in stream {
            self.applyBackfillProgress(progress)
        }
    }

    func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { messageHits = []; return }
        isSearching = true
        defer { isSearching = false }
        messageHits = (try? await search.query(q, limit: 100)) ?? []
    }
}
```

- [ ] **Step 3: SearchResultRow**

```swift
import SwiftUI
import MatronSearch

struct SearchResultRow: View {
    let hit: SearchHit
    let chatTitle: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(chatTitle).font(.callout).bold()
                    Spacer()
                    Text(hit.timestamp, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
                attributedSnippet(hit.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .buttonStyle(.plain)
    }

    private func attributedSnippet(_ raw: String) -> Text {
        // Crude but effective: split on <mark>...</mark> and render highlighted parts bold.
        var result = Text("")
        var remaining = raw[...]
        while let openRange = remaining.range(of: "<mark>") {
            result = result + Text(remaining[..<openRange.lowerBound])
            remaining = remaining[openRange.upperBound...]
            if let closeRange = remaining.range(of: "</mark>") {
                result = result + Text(remaining[..<closeRange.lowerBound]).bold().foregroundColor(.accentColor)
                remaining = remaining[closeRange.upperBound...]
            } else {
                break
            }
        }
        result = result + Text(remaining)
        return result
    }
}
```

- [ ] **Step 4: SearchView**

```swift
import SwiftUI
import MatronSearch
import MatronChat
import MatronModels

struct SearchView: View {
    @State var viewModel: SearchViewModel
    let onSelectChat: (ChatSummary) -> Void
    let onSelectMessage: (SearchHit) -> Void

    var body: some View {
        List {
            if !viewModel.chatHits.isEmpty {
                Section("Chats") {
                    ForEach(viewModel.chatHits) { chat in
                        Button { onSelectChat(chat) } label: {
                            VStack(alignment: .leading) {
                                Text(chat.title)
                                Text(chat.bot.displayName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !viewModel.messageHits.isEmpty {
                Section("Messages") {
                    ForEach(viewModel.messageHits) { hit in
                        SearchResultRow(
                            hit: hit,
                            chatTitle: viewModel.chatTitle(for: hit.roomID),
                            onTap: { onSelectMessage(hit) }
                        )
                    }
                }
            }
            if viewModel.query.isEmpty {
                Section { Text("Search across chat titles, bots, and messages.").foregroundStyle(.secondary) }
            } else if viewModel.chatHits.isEmpty && viewModel.messageHits.isEmpty && !viewModel.isSearching {
                Section { Text(viewModel.emptyResultsMessage).foregroundStyle(.secondary) }
            }
        }
        .searchable(text: $viewModel.query, placement: .navigationBarDrawer(displayMode: .always))
        .onChange(of: viewModel.query) { _, _ in
            Task { await viewModel.search() }
        }
        .navigationTitle("Search")
    }
}
```

- [ ] **Step 5: Wire `chatTitle(for:)` lookup + drop the SearchView stub**

Confirm the `SearchView` body uses `viewModel.chatTitle(for: hit.roomID)` (no local stub), and that `SearchViewModel` is constructed with the current chat-list snapshot (passed in from `ChatListView` when presenting the `SearchView`). The unit test added in Step 1 (`test_chatTitle_resolvesViaAllChats`) covers the lookup contract.

- [ ] **Step 6: Wire `BackfillRunner` progress into the ViewModel**

Add an `AsyncStream<AggregateBackfillProgress>` on `BackfillRunner` (or a small `BackfillCoordinator` that owns the runner + a continuation). When constructing the `SearchView`, kick off:

```swift
.task {
    await viewModel.observeBackfill(backfillCoordinator.progressStream)
}
```

so the empty state flips between "Indexing chats… (X of Y rooms)" and "No results." as rooms finish backfilling.

- [ ] **Step 7: Commit**

```bash
git add Matron/Features/Search/ MatronTests/SearchViewModelTests.swift
git commit -m "feat: SearchView + SearchViewModel + SearchResultRow with snippet highlighting"
git push
```

---

### Task 9: Wire SearchView into ChatList navigation

**Files:**
- Modify: `Matron/Features/ChatList/ChatListView.swift`

- [ ] **Step 1: Replace the placeholder search bar with a NavigationLink to `SearchView`**

In `ChatListView`, add a search-button toolbar item or a `.searchable` modifier that pushes onto `SearchView` when tapped. Wire `onSelectChat` and `onSelectMessage`:

- `onSelectChat(chat)` → navigate to that chat
- `onSelectMessage(hit)` → navigate to that chat AND scroll to the event ID once loaded (pass the event ID into `ChatViewModel` and have it call `Timeline.focusedAt(eventID)` after start)

- [ ] **Step 2: Commit**

```bash
git commit -am "feat: wire SearchView from chat list; jump-to-message in chat"
git push
```

---

### Task 10: Indexing-progress indicator on first run

**Files:**
- Modify: `Matron/Features/ChatList/ChatListView.swift`

- [ ] **Step 1: Show a small "Indexing chats…" footer**

If any room has `backfillComplete(roomID:) == false`, display a footer at the bottom of the list with a `ProgressView` and a count: "Indexing chats… (24 done)". Hide once all complete.

- [ ] **Step 2: Commit**

```bash
git commit -am "feat: ChatListView shows indexing footer until backfill completes"
git push
```

---

### Task 11: Manual test additions

Append to `manual-tests.md`:

```markdown
## Phase 6 (Search)

### Indexing

- [ ] On first launch after upgrade, footer shows "Indexing chats…" with a count.
- [ ] After ~minutes, footer disappears.
- [ ] Send a new message → it's searchable within seconds.

### Search UI

- [ ] Tap the search bar → SearchView appears.
- [ ] Type "auth" — see Chats section with chats whose title or bot matches; Messages section with FTS hits.
- [ ] Tap a Chat result → opens that chat.
- [ ] Tap a Message result → opens the chat scrolled to that event; the event flashes briefly.
- [ ] Empty query → "Search across chat titles…" placeholder.
- [ ] No matches with backfill complete → "No results."
- [ ] No matches while backfill in progress → "Indexing chats… (X of Y rooms)" instead of "No results."

### Sign-out

- [ ] After sign-out + sign-in, search returns no hits until backfill re-runs.

### File protection

- [ ] On a locked, powered-off device, the matron-search.sqlite file is encrypted (verify via diagnostic profile or by attempting to read it pre-unlock — should fail).
```

Commit:

```bash
git add manual-tests.md
git commit -m "docs: phase 6 manual test additions"
git push
```

---

## Phase 6 acceptance

1. All 11 tasks committed and pushed.
2. CI green.
3. Manual checklist passes — search returns results from both new and backfilled messages, snippets highlighted, jump-to-message works.
4. SQLite file verified to have `NSFileProtectionComplete`.

After acceptance, write Phase 7 plan (polish).

---

## Plan self-review

- **§5.8 Search UX:** Tasks 8–10. SearchView resolves room IDs to chat titles via `viewModel.chatTitle(for:)` (Task 8 Step 5). Empty-state text reflects backfill progress: "Indexing chats… (X of Y rooms)" while in flight, "No results." once complete (Task 8 Steps 1–2 + 6).
- **§6.2 Decryption hook:** Task 5.
- **§9.1 Schema:** Task 2. Uses content-table FTS5: a `messages` table holds the indexable columns + UNIQUE `event_id`, `messages_fts` mirrors only `body`, and three triggers (`messages_ai`/`messages_ad`/`messages_au`) keep them synchronised. This is mandatory because FTS5 silently no-ops `DELETE … WHERE` clauses against `UNINDEXED` columns; the content-table design lets `INSERT OR REPLACE INTO messages` and `DELETE FROM messages WHERE event_id = ?` work for idempotent re-indexing and redactions.
- **§9.2 File location & protection:** Tasks 2 + 7. The DB file is **pre-created** with `NSFileProtectionComplete` at the file-creation step (Task 2 Step 1), avoiding the brief unprotected window that `setAttributes` after `DatabaseQueue` open would leave. A defensive assertion verifies the attribute on the resulting file. Wipe on sign-out covered in Task 7.
- **§9.3 Index lifecycle:** Tasks 5 (live), 6 (backfill). `BackfillRunner` depends on a `TimelinePager` protocol (Task 6 Step 2) so the loop is fully testable with a fake. The runner walks pages backward, skips already-indexed events via `search.contains(eventID:)`, tracks the oldest-event ID, and stops on depth limit, `sinceCutoff`, or start-of-timeline. SDK-specific code lives only in `TimelinePagerLive`. Tests cover three batches with mixed indexable/non-indexable items, the depth-limit cap, `sinceCutoff` early-stop, and the duplicate-skip path.
- **§9.4 Query:** Task 4. The query JOINs `messages_fts` to `messages` to recover sender/timestamp/room_id (no longer in the FTS table). Snippet column index is `0` (FTS5 contains only `body`), not `4` as in the original spec snippet — this is documented inline.
- **Test coverage of redaction:** added `test_remove_clearsFTSRow` (Task 4) and `test_deleteRemovesFromFTS` (Task 2) to lock in trigger correctness.
- **Backfill progress surfacing:** `SearchViewModel` exposes `AggregateBackfillProgress` and an `observeBackfill(_:)` AsyncStream consumer; `SearchView` reads `viewModel.emptyResultsMessage` (Task 8 Steps 2 + 4 + 6).
- No placeholders. SDK pagination API isolated to `TimelinePagerLive` for the implementer.
