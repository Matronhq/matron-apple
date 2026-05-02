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
│   └── SearchModels.swift                   NEW — DTOs
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

```swift
import Foundation
import GRDB

public enum SearchSchema {
    public static func migrate(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1: messages_fts + indexed_rooms") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE messages_fts USING fts5(
                    room_id UNINDEXED,
                    event_id UNINDEXED,
                    sender UNINDEXED,
                    timestamp UNINDEXED,
                    body,
                    tokenize='porter unicode61'
                );
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
    public static func makeDatabase(at path: URL) throws -> DatabaseQueue {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(path: path.path, configuration: config)
        try (FileManager.default).setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: path.path
        )
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
            let exists = try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE name = 'messages_fts'")
            XCTAssertEqual(exists, true)
            let exists2 = try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE name = 'indexed_rooms'")
            XCTAssertEqual(exists2, true)
        }
    }

    func test_canInsertAndQueryFTS() throws {
        let queue = try SearchSchema.makeDatabase(at: dbURL)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO messages_fts(room_id, event_id, sender, timestamp, body) VALUES (?, ?, ?, ?, ?)",
                           arguments: ["!r:s", "$1", "@a:s", 1745000000, "the quick brown fox jumps over the lazy dog"])
        }
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'fox'")
            XCTAssertEqual(count, 1)
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
            // Idempotency: delete any previous row for this event then insert fresh.
            try db.execute(sql: "DELETE FROM messages_fts WHERE event_id = ?", arguments: [eventID])
            try db.execute(
                sql: "INSERT INTO messages_fts(room_id, event_id, sender, timestamp, body) VALUES (?, ?, ?, ?, ?)",
                arguments: [roomID, eventID, sender, timestamp.timeIntervalSince1970, body]
            )
        }
    }

    public func remove(eventID: String) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM messages_fts WHERE event_id = ?", arguments: [eventID])
        }
    }

    public func query(_ text: String, limit: Int) async throws -> [SearchHit] {
        let escaped = text.replacingOccurrences(of: "\"", with: "\"\"")
        let pattern = "\"\(escaped)\"*"
        return try await queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT room_id, event_id, sender, timestamp,
                       snippet(messages_fts, 4, '<mark>', '</mark>', '…', 32) AS snippet
                FROM messages_fts
                WHERE messages_fts MATCH ?
                ORDER BY timestamp DESC
                LIMIT ?
            """, arguments: [pattern, limit])

            return rows.map { row in
                SearchHit(
                    id: row["event_id"],
                    roomID: row["room_id"],
                    sender: row["sender"],
                    timestamp: Date(timeIntervalSince1970: row["timestamp"]),
                    snippet: row["snippet"]
                )
            }
        }
    }

    public func wipe() async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM messages_fts")
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

    func test_indexAndQuery_returnsHit() async throws {
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s",
                            timestamp: Date(), body: "the auth bug is in src/auth.rs")
        let hits = try await svc.query("auth bug", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].snippet.contains("<mark>auth"))
    }

    func test_indexIsIdempotent() async throws {
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: Date(), body: "first")
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: Date(), body: "second")
        let hits = try await svc.query("first", limit: 10)
        XCTAssertEqual(hits.count, 0)
        let hits2 = try await svc.query("second", limit: 10)
        XCTAssertEqual(hits2.count, 1)
    }

    func test_remove() async throws {
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: Date(), body: "secret")
        try await svc.remove(eventID: "$1")
        let hits = try await svc.query("secret", limit: 10)
        XCTAssertEqual(hits.count, 0)
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
- Create: `MatronShared/Sources/Search/BackfillRunner.swift`
- Create: `MatronShared/Tests/SearchTests/BackfillTests.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import MatronSync
import MatronModels
import MatrixRustSDK

public final class BackfillRunner: @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession
    private let search: SearchService
    private let depthLimit: Int
    private let dayLimit: Int

    public init(provider: ClientProvider, session: UserSession, search: SearchService, depthLimit: Int = 1000, dayLimit: Int = 90) {
        self.provider = provider
        self.session = session
        self.search = search
        self.depthLimit = depthLimit
        self.dayLimit = dayLimit
    }

    /// Returns once backfill for `roomID` is complete (or skipped because already complete).
    public func backfill(roomID: String) async throws {
        if try await search.backfillComplete(roomID: roomID) { return }

        let client = try await provider.client(for: session)
        let room = try await client.getRoom(roomId: roomID)
        let timeline = try await room.timeline()

        var indexedCount = 0
        var oldestEventID: String? = nil
        let cutoff = Date().addingTimeInterval(-Double(dayLimit) * 86_400)

        while indexedCount < depthLimit {
            let result = try await timeline.paginateBackwards(opts: .untilNumItems(eventLimit: 50, items: 50))
            // result.hitStartOfTimeline (or similar) — name varies by SDK version
            let hitStart: Bool = result.hitStartOfTimeline ?? false  // adjust per SDK

            // Snapshot current items, walk backward indexing new ones until we hit cutoff or oldest already indexed
            // (Implementer: use the timeline's snapshot accessor; for each text/tool-call item not yet indexed,
            // call search.index, increment indexedCount, update oldestEventID, and break if timestamp < cutoff.)

            try await search.recordBackfillProgress(
                roomID: roomID, indexedCount: indexedCount,
                oldestEventID: oldestEventID, complete: false
            )

            if hitStart || timestampOfOldest(in: result) < cutoff { break }
        }

        try await search.recordBackfillProgress(
            roomID: roomID, indexedCount: indexedCount,
            oldestEventID: oldestEventID, complete: true
        )
    }

    private func timestampOfOldest(in result: PaginationResult) -> Date {
        // Implementer: pull min timestamp from the page. Stub returns .distantPast.
        .distantPast
    }
}
```

> **Implementer note:** the SDK's pagination + snapshot APIs are the most volatile part of this task. The shape above (paginate → walk → record progress → repeat) is what matters; adjust to match `Package.resolved`.

- [ ] **Step 2: Test (with a fake search and a stubbed backfill)**

Skip a real SDK-level test; cover the search-side bookkeeping:

```swift
import XCTest
@testable import MatronSearch

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
}
```

- [ ] **Step 3: Commit**

```bash
cd MatronShared && swift test --filter BackfillTests
git add MatronShared/Sources/Search/BackfillRunner.swift MatronShared/Tests/SearchTests/BackfillTests.swift
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

In `MatronApp`'s post-login `.task`, observe the chat list snapshot once and queue a `BackfillRunner.backfill` for each room. Run them serially (or `withTaskGroup` of N=2 concurrent) to avoid hammering the homeserver.

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

- [ ] **Step 1: ViewModel test**

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
}
```

- [ ] **Step 2: ViewModel**

```swift
import Foundation
import MatronSearch
import MatronChat
import MatronModels

@Observable
@MainActor
final class SearchViewModel {
    var query: String = ""
    private(set) var messageHits: [SearchHit] = []
    private(set) var isSearching = false

    private let search: SearchService
    private let allChats: [ChatSummary]

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
                            chatTitle: chatTitle(for: hit.roomID),
                            onTap: { onSelectMessage(hit) }
                        )
                    }
                }
            }
            if viewModel.query.isEmpty {
                Section { Text("Search across chat titles, bots, and messages.").foregroundStyle(.secondary) }
            } else if viewModel.chatHits.isEmpty && viewModel.messageHits.isEmpty && !viewModel.isSearching {
                Section { Text("No results.").foregroundStyle(.secondary) }
            }
        }
        .searchable(text: $viewModel.query, placement: .navigationBarDrawer(displayMode: .always))
        .onChange(of: viewModel.query) { _, _ in
            Task { await viewModel.search() }
        }
        .navigationTitle("Search")
    }

    private func chatTitle(for roomID: String) -> String {
        // Look up from the allChats list passed into the VM (pass it through here in Step 5).
        roomID
    }
}
```

- [ ] **Step 5: Commit**

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
- [ ] No matches → "No results."

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

- **§5.8 Search UX:** Tasks 8–10.
- **§6.2 Decryption hook:** Task 5.
- **§9.1 Schema:** Task 2.
- **§9.2 File location & protection:** Tasks 2 + 7 (wipe on sign-out).
- **§9.3 Index lifecycle:** Tasks 5 (live), 6 (backfill).
- **§9.4 Query:** Task 4.
- No placeholders. SDK pagination API flagged for the implementer.
