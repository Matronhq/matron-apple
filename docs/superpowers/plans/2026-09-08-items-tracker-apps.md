# Items Tracker (apps) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the task & decision tracker in the iOS and Mac apps: a shared core (models, journal HTTP client, local GRDB cache, sync on marker events, offline comment outbox, view models, shared views), a Mac pane sharing the sub-chat slot, an iOS right-edge drawer, a floating "Make task" pill on both composers, inline timeline cards for created/closed markers, and a Needs-you badge on chat-list rows.

**Architecture:** Items are fetched over HTTP from the journal's `/items` routes into two new GRDB tables and observed through `ValueObservation` streams, exactly as summaries flow today. The sync engine exposes a stream of `item` marker events; `ItemsSync` refetches on marker, on reconnect, and on panel open, and drains an item-specific outbox when the connection is running. View models in `MatronViewModels` own state; views in `MatronDesignSystem` are dumb (data in, closures out) so both apps host them. Each app wires the view models from its `AppDependencies`.

**Tech Stack:** Swift 6 / SwiftUI, GRDB (local SPM package `MatronShared`), XCTest, swift-snapshot-testing, xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-08-task-decision-tracker-design.md` (sections *Apps*, *Error handling*, *Testing*, *Rollout*). Server routes per the journal plan (`matron-journal/docs/superpowers/plans/2026-09-08-items-tracker-journal.md`); the bridge plan handles the agent side.

## Global Constraints

- Run `xcodegen generate` before any `xcodebuild` (new files under `Matron/` and `MatronMac/` are directory-globbed at generation time). New files under `MatronShared/Sources/<Target>/` need no project changes.
- SPM tests: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared` (add `--filter <Class>` per task). Snapshot recording runs without the skip var.
- Mac target tests: `TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests 2>&1 | tail -30` — **always** set `MATRON_APP_SUPPORT_OVERRIDE` (the test host has wiped the live store before) and assert the `Executed N tests` line is present with `0 failures`.
- iOS target tests: `xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MatronTests 2>&1 | tail -30`.
- The next `JournalStore` migration identifier is **`v9`** (`v8` exists at `JournalStore.swift:393`).
- Module dependency rules: `MatronModels` is Foundation-only; `MatronEvents` depends only on Models; `MatronDesignSystem` depends on Models + Events + Search (never ViewModels); `MatronViewModels` depends on Chat/Journal/Models. New files obey these.
- Wire names are the journal's: `kind ∈ task|question|decision`, `state ∈ open|closed`, `resolution ∈ done|answered|decided|reversed|cancelled`, `awaiting ∈ user|agent|null`, marker `action ∈ created|commented|closed|reopened|reordered`.
- Every task ends with its named test commands green. Never claim green without the output.

---

## File map

| File | Responsibility |
|---|---|
| `MatronShared/Sources/Models/TrackerItem.swift` (create) | `TrackerItem`, `TrackerComment`, `TrackerAttachment`, enums; `init?(json:)` decoders. |
| `MatronShared/Sources/Events/ItemMarkerEvent.swift` (create) | `ItemMarkerEvent.parse(payload:)` for the `item` journal event. |
| `MatronShared/Sources/Journal/WireModels.swift` (modify) | `JournalEventType.item`. |
| `MatronShared/Sources/Journal/JournalAPI+Items.swift` (create) + `JournalAPI.swift` (modify) | `ItemsProviding` protocol + the routes; `request` accepts 201. |
| `MatronShared/Sources/Journal/JournalStore+Items.swift` (create) + `JournalStore.swift` (modify) | `ItemRecord`, `ItemCommentRecord`, `ItemOutboxRecord`; migration `v9`; queries + streams; wipe. |
| `MatronShared/Sources/Journal/JournalSyncEngine.swift` (modify) | `itemMarkers()` stream fed from `didApply`/`didApplyBatch`. |
| `MatronShared/Sources/Journal/ItemsSync.swift` (create) | Refresh policy, feature detection, outbox drain. |
| `MatronShared/Sources/Chat/TimelineItem.swift`, `JournalTimelineMapper.swift` (modify) | `.itemMarker` case. |
| `MatronShared/Sources/Chat/ChatSummary.swift`, `JournalChatService.swift` (modify) | `needsUserCount`. |
| `MatronShared/Sources/ViewModels/ItemsPanelViewModel.swift`, `ItemDetailViewModel.swift` (create); `ComposerViewModel.swift` (modify) | State + actions; `makeTask()`. |
| `MatronShared/Sources/DesignSystem/Items/*.swift` (create) | `ItemGlyph`, `ItemRow`, `ItemsListView`, `ItemDetailView`, `ItemInlineCard`, `ItemInlineNote`, `MakeTaskPill`, `NeedsYouBadge`. |
| `Matron/Features/Items/ItemsDrawer.swift`, `ItemsPanelHost.swift` (create); `ChatView.swift`, `ChatListView.swift` (modify) | iOS drawer, hosts, pill, badge. |
| `MatronMac/Features/Items/MacItemsPane.swift` (create); `MacChatView.swift`, `MacChatToolbar.swift`, `MacComposerView.swift`, `MacChatListView.swift` (modify) | Mac pane, toolbar toggle + badge, pill, badge. |
| `Matron/App/AppDependencies.swift`, `MatronMac/App/AppDependencies.swift` (modify) | `itemsSync(for:)`, `itemsProvider(for:)`. |
| Tests: `MatronShared/Tests/JournalTests/{ItemsAPITests,JournalStoreItemsTests,ItemsSyncTests}.swift`, `Tests/EventsTests/ItemMarkerEventTests.swift`, `Tests/ChatTests/JournalTimelineMapperItemTests.swift`, `Tests/ViewModelTests/{ItemsPanelViewModelTests,ItemDetailViewModelTests}.swift` (+ `ComposerViewModelTests`), `Tests/DesignSystemSnapshotTests/Items*SnapshotTests.swift`, `MatronMacTests/MacItemsPaneSnapshotTests.swift`, `MatronTests/ChatRowHeightTests.swift` (modify). |

PR slices (spec *Rollout*): **PR A** = Tasks 1–11 (core + panel + Mac pane + iOS drawer). **PR B** = Tasks 12–13 (pill + inline cards). **PR C** = Task 14 (badge). Each slice ships independently; the branch for A is `items-tracker-core`, B `items-tracker-composer`, C `items-tracker-badge`, stacked.

---

### Task 1: Models

**Files:**
- Create: `MatronShared/Sources/Models/TrackerItem.swift`
- Test: `MatronShared/Tests/JournalTests/ItemsAPITests.swift` (decoding tests live here because `MatronModels` has no test target; `JournalTests` already depends on `MatronModels`)

**Interfaces:**
- Produces:

```swift
public enum ItemKind: String, Codable, Sendable, CaseIterable { case task, question, decision }
public enum ItemState: String, Codable, Sendable { case open, closed }
public enum ItemResolution: String, Codable, Sendable, CaseIterable { case done, answered, decided, reversed, cancelled }
public enum ItemAwaiting: String, Codable, Sendable { case user, agent }
public enum ItemAuthor: String, Codable, Sendable { case user, agent }
public struct TrackerAttachment: Equatable, Hashable, Sendable, Codable { blobRef, mime, name, size: Int64, transcript: String? ; isImage: Bool; isAudio: Bool }
public struct TrackerLink: Equatable, Hashable, Sendable, Codable { url: String, title: String? }
public struct TrackerItem: Identifiable, Equatable, Hashable, Sendable {
  id, num: Int, kind, state, resolution: ItemResolution?, awaiting: ItemAwaiting?, rank: Double,
  title, body, labels: [String], links: [TrackerLink], attachments: [TrackerAttachment], supersedes: String?,
  originConvoID: String, createdBy: ItemAuthor, createdAt: Date, updatedAt: Date, closedAt: Date?,
  commentCount: Int, lastCommentAt: Date?, hasImage: Bool
  init?(json: [String: Any]); var needsUser: Bool { state == .open && awaiting == .user }
}
public struct TrackerComment: Identifiable, Equatable, Hashable, Sendable {
  enum Kind: String { case comment, status }
  id, itemID, author: ItemAuthor, deviceID: Int64, kind, body, attachments: [TrackerAttachment],
  statusFrom/statusTo: TrackerItem.StatusSnapshot? (state, resolution, awaiting), createdAt: Date
  init?(json: [String: Any])
}
```

Dates decode from ms integers (`(json["created_at"] as? NSNumber)?.doubleValue / 1000`).

- [ ] **Step 1: Write the failing test**

```swift
// MatronShared/Tests/JournalTests/ItemsAPITests.swift
import XCTest
import MatronModels
@testable import MatronJournal

final class ItemsAPITests: XCTestCase {
    static let itemJSON: [String: Any] = [
        "id": "it_1", "user_id": 1, "num": 12, "kind": "question", "state": "open", "resolution": NSNull(),
        "awaiting": "user", "rank": 1024.0, "title": "Which auth?", "body": "A or B", "labels": ["auth"],
        "links": [["url": "https://x", "title": "issue"]],
        "attachments": [["blob_ref": "b1", "mime": "image/png", "name": "s.png", "size": 10]],
        "supersedes": NSNull(), "origin_convo_id": "c1", "origin_device_id": 3, "created_by": "agent",
        "idem_key": NSNull(), "created_at": 1_700_000_000_000, "updated_at": 1_700_000_001_000, "closed_at": NSNull(),
        "comment_count": 2, "last_comment_at": 1_700_000_001_000, "has_image": 1,
    ]

    func testTrackerItemDecodes() throws {
        let item = try XCTUnwrap(TrackerItem(json: Self.itemJSON))
        XCTAssertEqual(item.id, "it_1"); XCTAssertEqual(item.num, 12); XCTAssertEqual(item.kind, .question)
        XCTAssertEqual(item.state, .open); XCTAssertNil(item.resolution); XCTAssertEqual(item.awaiting, .user)
        XCTAssertEqual(item.rank, 1024); XCTAssertEqual(item.labels, ["auth"]); XCTAssertEqual(item.links.first?.url, "https://x")
        XCTAssertEqual(item.attachments.first?.blobRef, "b1"); XCTAssertTrue(item.attachments.first!.isImage)
        XCTAssertEqual(item.createdAt, Date(timeIntervalSince1970: 1_700_000_000)); XCTAssertNil(item.closedAt)
        XCTAssertEqual(item.commentCount, 2); XCTAssertTrue(item.hasImage); XCTAssertTrue(item.needsUser)
        XCTAssertEqual(item.createdBy, .agent); XCTAssertEqual(item.originConvoID, "c1")
    }

    func testTrackerItemRejectsMissingKeys() {
        var bad = Self.itemJSON; bad["kind"] = "bug"
        XCTAssertNil(TrackerItem(json: bad))
        bad = Self.itemJSON; bad.removeValue(forKey: "num")
        XCTAssertNil(TrackerItem(json: bad))
    }

    func testTrackerCommentDecodesStatusMeta() throws {
        let json: [String: Any] = [
            "id": "ic_1", "item_id": "it_1", "user_id": 1, "author": "user", "device_id": 9, "kind": "status",
            "body": "no", "attachments": [], "meta": ["from": ["state": "open", "resolution": NSNull(), "awaiting": "user"],
                                                    "to": ["state": "closed", "resolution": "reversed", "awaiting": NSNull()]],
            "idem_key": NSNull(), "created_at": 1_700_000_002_000,
        ]
        let c = try XCTUnwrap(TrackerComment(json: json))
        XCTAssertEqual(c.kind, .status); XCTAssertEqual(c.author, .user); XCTAssertEqual(c.statusTo?.resolution, .reversed)
        XCTAssertEqual(c.statusFrom?.awaiting, .user); XCTAssertNil(c.statusTo?.awaiting)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter ItemsAPITests`
Expected: compile error, `TrackerItem` undefined.

- [ ] **Step 3: Create `TrackerItem.swift`**

```swift
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
            hasImage: (hasImageRaw as? Bool) ?? ((hasImageRaw as? NSNumber)?.intValue ?? 0) != 0)
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter ItemsAPITests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Models/TrackerItem.swift MatronShared/Tests/JournalTests/ItemsAPITests.swift
git commit -m "items: TrackerItem / TrackerComment models"
```

---

### Task 2: Marker event decoder and wire type

**Files:**
- Create: `MatronShared/Sources/Events/ItemMarkerEvent.swift`
- Modify: `MatronShared/Sources/Journal/WireModels.swift:6-44` (`JournalEventType.item`; **not** added to `messageTypes`)
- Test: `MatronShared/Tests/EventsTests/ItemMarkerEventTests.swift`

**Interfaces:**
- `public struct ItemMarkerEvent: Equatable, Sendable { itemID, num: Int, kind: ItemKind, title, action: Action, by: ItemAuthor, awaiting: ItemAwaiting?, resolution: ItemResolution?, comment: Comment? }` with `enum Action: String { created, commented, closed, reopened, reordered }` and `struct Comment { id, body, attachments: [TrackerAttachment] }`; `static func parse(payload: [String: Any]) -> ItemMarkerEvent?`.
- `JournalEventType.item = "item"`.

- [ ] **Step 1: Write the failing test**

```swift
// MatronShared/Tests/EventsTests/ItemMarkerEventTests.swift
import XCTest
import MatronModels
@testable import MatronEvents

final class ItemMarkerEventTests: XCTestCase {
    func testParsesCommentedMarker() throws {
        let payload: [String: Any] = [
            "item_id": "it_1", "num": 12, "kind": "question", "title": "Which auth?", "action": "commented",
            "by": "user", "awaiting": "agent", "resolution": NSNull(),
            "comment": ["id": "ic_1", "body": "use A", "attachments": [["blob_ref": "b", "mime": "audio/mp4", "name": "v.m4a", "size": 1, "transcript": NSNull()]]],
        ]
        let m = try XCTUnwrap(ItemMarkerEvent.parse(payload: payload))
        XCTAssertEqual(m.num, 12); XCTAssertEqual(m.action, .commented); XCTAssertEqual(m.by, .user)
        XCTAssertEqual(m.awaiting, .agent); XCTAssertNil(m.resolution)
        XCTAssertEqual(m.comment?.body, "use A"); XCTAssertTrue(m.comment!.attachments[0].isAudio)
    }

    func testRejectsUnknownActionOrMissingKeys() {
        XCTAssertNil(ItemMarkerEvent.parse(payload: ["item_id": "it_1", "num": 1, "kind": "task", "title": "t", "action": "exploded", "by": "agent"]))
        XCTAssertNil(ItemMarkerEvent.parse(payload: ["num": 1, "kind": "task", "title": "t", "action": "created", "by": "agent"]))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter ItemMarkerEventTests`
Expected: compile error.

- [ ] **Step 3: Implement**

```swift
// MatronShared/Sources/Events/ItemMarkerEvent.swift
import Foundation
import MatronModels

/// The `item` journal event (spec: Marker event) — what the conversation
/// log records about a tracker item. Not the item itself: the apps refetch
/// the row from `/items/:id` on receipt. `reordered` markers exist only to
/// invalidate the local cache and never render.
public struct ItemMarkerEvent: Equatable, Sendable {
    public enum Action: String, Sendable { case created, commented, closed, reopened, reordered }
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
```

In `WireModels.swift` add `public static let item = "item"` next to `summary`, with the comment "Tracker marker (spec 2026-09-08). Deliberately NOT in `messageTypes`: it neither bumps unread nor sets the snippet, matching the server."

- [ ] **Step 4: Run to verify it passes**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter ItemMarkerEventTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Events/ItemMarkerEvent.swift MatronShared/Sources/Journal/WireModels.swift MatronShared/Tests/EventsTests/ItemMarkerEventTests.swift
git commit -m "items: ItemMarkerEvent decoder and the item wire type"
```

---

### Task 3: `JournalAPI` items routes

**Files:**
- Create: `MatronShared/Sources/Journal/JournalAPI+Items.swift`
- Modify: `MatronShared/Sources/Journal/JournalAPI.swift:691-702` (`request` gains `accept: Set<Int> = [200]`)
- Test: `MatronShared/Tests/JournalTests/ItemsAPITests.swift` (append)

**Interfaces:**

```swift
public struct ItemsListQuery: Equatable, Sendable {
    public var convoID: String?; public var kind: ItemKind?; public var state: ItemState?; public var awaiting: ItemAwaiting?
    public var label: String?; public var sort: Sort = .rank; public var since: Date?; public var limit: Int = 100; public var cursor: String?
    public enum Sort: String { case rank, updated }
}
public struct ItemsPage: Equatable, Sendable { public let items: [TrackerItem]; public let nextCursor: String? }
public struct NewItem: Equatable, Sendable { kind, title, body, labels, links, attachments, awaiting: ItemAwaiting??, position: String?, convoID: String, supersedes: String? }
public struct ItemPatch: Equatable, Sendable { title?, body?, labels?, links?, awaiting: ItemAwaiting?? }
public struct ItemRankChange: Equatable, Sendable { position: String?, after: String?, before: String? }

public protocol ItemsProviding: Sendable {
    func listItems(_ query: ItemsListQuery) async throws -> ItemsPage
    func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment])
    func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem
    func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem
    func commentItem(id: String, body: String, attachments: [TrackerAttachment], idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment)
    func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem
    func reopenItem(id: String, comment: String?) async throws -> TrackerItem
    func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem
    func uploadMedia(_ data: Data, contentType: String) async throws -> String   // already on JournalAPI
}
extension JournalAPI: ItemsProviding {}
```

Errors: `JournalAPIError` as today (404 → `.notFound`, 409 → `.conflict`, 400 → `.http(status:400, …)`).

- [ ] **Step 1: Write the failing tests**

Look at how existing `JournalAPI` tests stub the network — `grep -rn "URLProtocol\|MockURLProtocol\|StubURLProtocol" MatronShared/Tests/JournalTests | head` — and reuse that stub. Append:

```swift
    func testListItemsBuildsQueryAndDecodesPage() async throws {
        let (api, recorder) = makeStubbedAPI(status: 200, body: ["items": [Self.itemJSON], "next_cursor": "abc"])
        var q = ItemsListQuery(); q.convoID = "c1"; q.awaiting = .user; q.since = Date(timeIntervalSince1970: 1_700_000_000)
        let page = try await api.listItems(q)
        XCTAssertEqual(page.items.first?.num, 12); XCTAssertEqual(page.nextCursor, "abc")
        let url = try XCTUnwrap(recorder.lastRequest?.url)
        XCTAssertEqual(url.path, "/items")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(items.contains(URLQueryItem(name: "convo", value: "c1")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "awaiting", value: "user")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "since", value: "1700000000000")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "sort", value: "rank")))
    }

    func testCreateItemAccepts201AndSendsIdempotencyKey() async throws {
        let (api, recorder) = makeStubbedAPI(status: 201, body: ["item": Self.itemJSON])
        let new = NewItem(kind: .task, title: "T", body: "b", convoID: "c1")
        let item = try await api.createItem(new, idempotencyKey: "k1")
        XCTAssertEqual(item.id, "it_1")
        let req = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST"); XCTAssertEqual(req.value(forHTTPHeaderField: "Idempotency-Key"), "k1")
        let sent = try JSONSerialization.jsonObject(with: recorder.lastBody!) as! [String: Any]
        XCTAssertEqual(sent["kind"] as? String, "task"); XCTAssertEqual(sent["convo_id"] as? String, "c1")
    }

    func testCloseMapsConflict() async {
        let (api, _) = makeStubbedAPI(status: 409, body: ["error": "conflict"])
        do { _ = try await api.closeItem(id: "it_1", resolution: .done, comment: nil); XCTFail() }
        catch let e as JournalAPIError { XCTAssertEqual(e, .conflict) } catch { XCTFail("\(error)") }
    }

    func testItemDetailDecodesComments() async throws {
        let comment: [String: Any] = ["id": "ic_1", "item_id": "it_1", "user_id": 1, "author": "user", "device_id": 9, "kind": "comment", "body": "hi", "attachments": [], "meta": NSNull(), "idem_key": NSNull(), "created_at": 1_700_000_002_000]
        let (api, recorder) = makeStubbedAPI(status: 200, body: ["item": Self.itemJSON, "comments": [comment]])
        let r = try await api.item(id: "#12")
        XCTAssertEqual(r.comments.first?.body, "hi")
        XCTAssertEqual(recorder.lastRequest?.url?.path, "/items/%2312")
    }
```

`makeStubbedAPI(status:body:)` returns a `JournalAPI` on a `URLSession` whose protocol class records the last request/body and answers with the given status + JSON. If the existing tests have such a helper under a different name, use it; otherwise add it to this file (a `URLProtocol` subclass with static `handler`).

- [ ] **Step 2: Run to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter ItemsAPITests`
Expected: compile error (`listItems` undefined).

- [ ] **Step 3: Implement**

In `JournalAPI.swift`, change `request` to:

```swift
    private func request(
        path: String, method: String = "GET", body: [String: Any]? = nil,
        query: [URLQueryItem] = [], authenticated: Bool = true,
        accept: Set<Int> = [200], headers: [String: String] = [:]
    ) async throws -> [String: Any] {
        let (data, response) = try await rawRequest(path: path, method: method, body: body,
                                                    query: query, authenticated: authenticated, headers: headers)
        guard accept.contains(response.statusCode) else { throw Self.error(status: response.statusCode, data: data) }
        ...
```

and thread `headers` into `rawRequest` (set each on the `URLRequest` after the Bearer header). Existing callers are unaffected.

`JournalAPI+Items.swift`:

```swift
import Foundation
import MatronModels

public struct ItemsListQuery: Equatable, Sendable {
    public enum Sort: String, Sendable { case rank, updated }
    public var convoID: String?
    public var kind: ItemKind?
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
        if !links.isEmpty { o["links"] = links.map { l in var d: [String: Any] = ["url": l.url]; if let t = l.title { d["title"] = t }; return d } }
        if !attachments.isEmpty { o["attachments"] = attachments.map(\.json) }
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
        if let links { o["links"] = links.map { l in var d: [String: Any] = ["url": l.url]; if let t = l.title { d["title"] = t }; return d } }
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
        if !attachments.isEmpty { json["attachments"] = attachments.map(\.json) }
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
```

`pathSegment` is `private static` in `JournalAPI.swift:685`; change it to `static` (internal) so the extension can use it.

- [ ] **Step 4: Run to verify it passes**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter ItemsAPITests`
Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/JournalAPI+Items.swift MatronShared/Sources/Journal/JournalAPI.swift MatronShared/Tests/JournalTests/ItemsAPITests.swift
git commit -m "items: JournalAPI routes + ItemsProviding"
```

---

### Task 4: Local cache — records, migration v9, queries, streams, item outbox

**Files:**
- Create: `MatronShared/Sources/Journal/JournalStore+Items.swift`
- Modify: `MatronShared/Sources/Journal/JournalStore.swift:393` (register `v9` after `v8`), and the wipe path (grep `wipeOutbox\|func wipe` — add `try ItemRecord.deleteAll(db)` etc. wherever `summary_entry` is wiped at `:1013`-ish)
- Test: `MatronShared/Tests/JournalTests/JournalStoreItemsTests.swift`

**Interfaces:**

```swift
public struct ItemRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable  // table "item"
  // columns: id, num, kind, state, resolution, awaiting, rank, title, body, labels_json, links_json, attachments_json,
  //          supersedes, origin_convo_id, created_by, created_at (ms), updated_at, closed_at, comment_count, last_comment_at, has_image
  init(_ item: TrackerItem); var item: TrackerItem
public struct ItemCommentRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable  // table "item_comment"
  // id, item_id, author, device_id, kind, body, attachments_json, meta_json, created_at
  init(_ comment: TrackerComment); var comment: TrackerComment
public struct ItemOutboxRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable  // table "item_outbox"
  // local_id (pk), item_id (nullable for creates), op ("comment"|"create"), payload_json, created_at, attempts, last_error
public enum ItemsScope: Equatable, Hashable, Sendable { case convo(String), all }

extension JournalStore {
  public func upsertItems(_ items: [TrackerItem]) throws
  public func replaceComments(itemID: String, _ comments: [TrackerComment]) throws
  public func item(id: String) throws -> TrackerItem?
  public func items(scope: ItemsScope) throws -> [TrackerItem]                  // all states; VM sections them
  public func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]>
  public func itemStream(id: String) -> AsyncStream<TrackerItem?>
  public func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]>
  public func itemsMaxUpdatedAt() throws -> Date?
  public func needsUserCounts() throws -> [String: Int]                          // originConvoID → count
  public func needsUserCountsStream() -> AsyncStream<[String: Int]>
  public func itemOutboxInsert(_ rec: ItemOutboxRecord) throws
  public func itemOutboxPending() throws -> [ItemOutboxRecord]
  public func itemOutboxRows(itemID: String) throws -> [ItemOutboxRecord]
  public func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]>
  public func itemOutboxMarkAttempt(localID: String, error: String?) throws
  public func itemOutboxDelete(localID: String) throws
  public func wipeItems() throws
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// MatronShared/Tests/JournalTests/JournalStoreItemsTests.swift
import XCTest
import GRDB
import MatronModels
@testable import MatronJournal

final class JournalStoreItemsTests: XCTestCase {
    private func makeStore() throws -> JournalStore { try JournalStore(databaseURL: nil, ownSender: "user:dan") }
    private func item(_ id: String, num: Int, kind: ItemKind = .task, convo: String = "c1", awaiting: ItemAwaiting? = .agent,
                      state: ItemState = .open, rank: Double = 1024, updated: TimeInterval = 1) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: kind, state: state, awaiting: awaiting, rank: rank, title: "T\(num)",
                    originConvoID: convo, updatedAt: Date(timeIntervalSince1970: updated))
    }

    func testMigrationV9CreatesTables() throws {
        let store = try makeStore()
        let names = try store.dbQueueForTests.read { db in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'") }
        XCTAssertTrue(names.contains("item")); XCTAssertTrue(names.contains("item_comment")); XCTAssertTrue(names.contains("item_outbox"))
    }

    func testUpsertRoundTripsAndScopes() throws {
        let store = try makeStore()
        try store.upsertItems([item("it_1", num: 1), item("it_2", num: 2, convo: "c2", awaiting: .user, kind: .question)])
        XCTAssertEqual(try store.item(id: "it_1")?.title, "T1")
        XCTAssertEqual(try store.items(scope: .convo("c2")).map(\.id), ["it_2"])
        XCTAssertEqual(try store.items(scope: .all).count, 2)
        try store.upsertItems([item("it_1", num: 1, state: .closed, updated: 5)])
        XCTAssertEqual(try store.item(id: "it_1")?.state, .closed)
        XCTAssertEqual(try store.itemsMaxUpdatedAt(), Date(timeIntervalSince1970: 5))
        XCTAssertEqual(try store.needsUserCounts(), ["c2": 1])
    }

    func testCommentsReplaceWholesale() throws {
        let store = try makeStore()
        try store.upsertItems([item("it_1", num: 1)])
        try store.replaceComments(itemID: "it_1", [TrackerComment(id: "ic_1", itemID: "it_1", author: .user, body: "a"),
                                                   TrackerComment(id: "ic_2", itemID: "it_1", author: .agent, body: "b")])
        try store.replaceComments(itemID: "it_1", [TrackerComment(id: "ic_2", itemID: "it_1", author: .agent, body: "b2")])
        let rows = try store.dbQueueForTests.read { db in try ItemCommentRecord.fetchAll(db) }
        XCTAssertEqual(rows.map(\.id), ["ic_2"]); XCTAssertEqual(rows.first?.body, "b2")
    }

    func testItemsStreamFiresOnUpsert() async throws {
        let store = try makeStore()
        let stream = store.itemsStream(scope: .convo("c1"))
        var it = stream.makeAsyncIterator()
        let first = await it.next()
        XCTAssertEqual(first?.count, 0)
        try store.upsertItems([item("it_1", num: 1)])
        let second = await it.next()
        XCTAssertEqual(second?.map(\.id), ["it_1"])
    }

    func testOutboxLifecycle() throws {
        let store = try makeStore()
        let rec = ItemOutboxRecord(localID: "L1", itemID: "it_1", op: "comment", payloadJSON: "{\"body\":\"x\"}", createdAt: 1, attempts: 0, lastError: nil)
        try store.itemOutboxInsert(rec)
        XCTAssertEqual(try store.itemOutboxPending().map(\.localID), ["L1"])
        try store.itemOutboxMarkAttempt(localID: "L1", error: "offline")
        XCTAssertEqual(try store.itemOutboxRows(itemID: "it_1").first?.attempts, 1)
        XCTAssertEqual(try store.itemOutboxRows(itemID: "it_1").first?.lastError, "offline")
        try store.itemOutboxDelete(localID: "L1")
        XCTAssertTrue(try store.itemOutboxPending().isEmpty)
    }

    func testWipeItemsClearsAllThree() throws {
        let store = try makeStore()
        try store.upsertItems([item("it_1", num: 1)])
        try store.replaceComments(itemID: "it_1", [TrackerComment(id: "ic_1", itemID: "it_1", author: .user, body: "a")])
        try store.itemOutboxInsert(ItemOutboxRecord(localID: "L1", itemID: "it_1", op: "comment", payloadJSON: "{}", createdAt: 1, attempts: 0, lastError: nil))
        try store.wipeItems()
        XCTAssertTrue(try store.items(scope: .all).isEmpty)
        XCTAssertTrue(try store.itemOutboxPending().isEmpty)
    }
}
```

`dbQueueForTests` — check `JournalStoreTests.swift` for how existing tests reach the queue (grep `dbQueue` there). If they use `@testable` access to `dbQueue` directly, use that name instead.

- [ ] **Step 2: Run to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter JournalStoreItemsTests`
Expected: compile errors.

- [ ] **Step 3: Implement**

In `JournalStore.swift` after the `v8` registration:

```swift
        // Tracker cache (spec 2026-09-08 task-decision-tracker). Filled from
        // GET /items, never from the event log; the `item` marker event is
        // only an invalidation signal (ItemsSync).
        migrator.registerMigration("v9") { db in
            try db.create(table: "item") { t in
                t.column("id", .text).primaryKey()
                t.column("num", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("state", .text).notNull()
                t.column("resolution", .text)
                t.column("awaiting", .text)
                t.column("rank", .double).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull().defaults(to: "")
                t.column("labels_json", .text).notNull().defaults(to: "[]")
                t.column("links_json", .text).notNull().defaults(to: "[]")
                t.column("attachments_json", .text).notNull().defaults(to: "[]")
                t.column("supersedes", .text)
                t.column("origin_convo_id", .text).notNull()
                t.column("created_by", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.column("closed_at", .integer)
                t.column("comment_count", .integer).notNull().defaults(to: 0)
                t.column("last_comment_at", .integer)
                t.column("has_image", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "item_convo_state", on: "item", columns: ["origin_convo_id", "state"])
            try db.create(index: "item_state_rank", on: "item", columns: ["state", "rank"])
            try db.create(table: "item_comment") { t in
                t.column("id", .text).primaryKey()
                t.column("item_id", .text).notNull().indexed()
                t.column("author", .text).notNull()
                t.column("device_id", .integer).notNull().defaults(to: 0)
                t.column("kind", .text).notNull()
                t.column("body", .text).notNull().defaults(to: "")
                t.column("attachments_json", .text).notNull().defaults(to: "[]")
                t.column("meta_json", .text)
                t.column("created_at", .integer).notNull()
            }
            try db.create(table: "item_outbox") { t in
                t.column("local_id", .text).primaryKey()
                t.column("item_id", .text).indexed()
                t.column("op", .text).notNull()
                t.column("payload_json", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("last_error", .text)
            }
        }
```

`JournalStore+Items.swift`:

```swift
import Foundation
import GRDB
import MatronModels

private let encoder = JSONEncoder()
private let decoder = JSONDecoder()
private func ms(_ d: Date?) -> Int64? { d.map { Int64($0.timeIntervalSince1970 * 1000) } }
private func date(_ v: Int64?) -> Date? { v.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
private func enc<T: Encodable>(_ v: T) -> String { (try? String(data: encoder.encode(v), encoding: .utf8)) ?? "[]" }
private func dec<T: Decodable>(_ s: String, _ t: T.Type) -> T? { s.data(using: .utf8).flatMap { try? decoder.decode(t, from: $0) } }

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
        createdAt = ms(i.createdAt)!; updatedAt = ms(i.updatedAt)!; closedAt = ms(i.closedAt)
        commentCount = i.commentCount; lastCommentAt = ms(i.lastCommentAt); hasImage = i.hasImage
    }

    public var item: TrackerItem {
        TrackerItem(id: id, num: num, kind: ItemKind(rawValue: kind) ?? .task, state: ItemState(rawValue: state) ?? .open,
                    resolution: resolution.flatMap(ItemResolution.init(rawValue:)), awaiting: awaiting.flatMap(ItemAwaiting.init(rawValue:)),
                    rank: rank, title: title, body: body, labels: dec(labelsJson, [String].self) ?? [],
                    links: dec(linksJson, [TrackerLink].self) ?? [], attachments: dec(attachmentsJson, [TrackerAttachment].self) ?? [],
                    supersedes: supersedes, originConvoID: originConvoId, createdBy: ItemAuthor(rawValue: createdBy) ?? .agent,
                    createdAt: date(createdAt)!, updatedAt: date(updatedAt)!, closedAt: date(closedAt),
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
        body = c.body; attachmentsJson = enc(c.attachments); createdAt = ms(c.createdAt)!
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
                              statusFrom: snap(meta?.from), statusTo: snap(meta?.to), createdAt: date(createdAt)!)
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

    public func wipeItems() throws {
        try dbQueue.write { db in
            try ItemCommentRecord.deleteAll(db); try ItemRecord.deleteAll(db); try ItemOutboxRecord.deleteAll(db)
        }
    }
}
```

`Self.stream` is `private static` in `JournalStore.swift`; make it `static` (file-internal to the module is enough: `static func stream` without `private`). Also call `wipeItems()` from the store's full-wipe path (where `summary_entry` is cleared), so sign-out clears the cache.

- [ ] **Step 4: Run to verify it passes**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter JournalStoreItemsTests`
Expected: 6 tests pass. Then the whole `JournalTests` class set to make sure the migration didn't break `JournalStoreTests`.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/JournalStore+Items.swift MatronShared/Sources/Journal/JournalStore.swift MatronShared/Tests/JournalTests/JournalStoreItemsTests.swift
git commit -m "items: local cache tables (v9), streams, item outbox"
```

---

### Task 5: Sync engine marker stream + `ItemsSync`

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalSyncEngine.swift` (continuation dict near `:111-125`; `itemMarkers()` next to `newConversations()` at `:677`; publish from `didApply` `:1196` and `didApplyBatch` `:1205`)
- Create: `MatronShared/Sources/Journal/ItemsSync.swift`
- Test: `MatronShared/Tests/JournalTests/ItemsSyncTests.swift`

**Interfaces:**
- Engine: `public nonisolated func itemMarkers() -> AsyncStream<(convoID: String, marker: ItemMarkerEvent)>`. Fed for every applied event with `type == JournalEventType.item` whose payload parses. (`MatronJournal` must import `MatronEvents`: add `"MatronEvents"` to the `MatronJournal` target's dependencies in `Package.swift:168-175`; Events depends only on Models so there is no cycle.)
- `ItemsSync`:

```swift
public actor ItemsSync {
    public init(api: any ItemsProviding, store: JournalStore, markers: @escaping @Sendable () -> AsyncStream<(convoID: String, marker: ItemMarkerEvent)>,
                connectionStates: @escaping @Sendable () -> AsyncStream<SyncConnectionState>)
    public private(set) var isSupported: Bool   // false after a 404 on GET /items; re-probed on reconnect
    public func supportedStream() -> AsyncStream<Bool>
    public func start()                          // idempotent; subscribes to markers + connection states
    public func stop()
    public func refresh(scope: ItemsScope) async  // since-watermark fetch; full fetch when the table is empty; pages until nextCursor == nil
    public func refreshItem(id: String) async     // GET /items/:id → upsert item + replace comments
    public func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async
    public func enqueueCreate(localID: String, _ new: NewItem) async
    public func drainOutbox() async               // called on start, on .running, and after every enqueue
}
```

Refresh rules: `refresh` uses `ItemsListQuery(since: store.itemsMaxUpdatedAt() - 1s, limit: 500, sort: .updated)` with `convoID` for `.convo`; for `.all` no convo filter. A `.notFound` error sets `isSupported = false`; any success sets it `true`. Other errors are logged and swallowed (the panel shows the store's last state).

- [ ] **Step 1: Write the failing tests**

```swift
// MatronShared/Tests/JournalTests/ItemsSyncTests.swift
import XCTest
import MatronModels
import MatronEvents
@testable import MatronJournal

private final class FakeItems: ItemsProviding, @unchecked Sendable {
    let lock = NSLock()
    var listResponses: [ItemsPage] = []
    var listQueries: [ItemsListQuery] = []
    var detail: [String: (TrackerItem, [TrackerComment])] = [:]
    var commentCalls: [(String, String)] = []
    var failComments = false
    var listError: Error?
    func listItems(_ q: ItemsListQuery) async throws -> ItemsPage {
        lock.withLock { listQueries.append(q) }
        if let listError { throw listError }
        return lock.withLock { listResponses.isEmpty ? ItemsPage(items: [], nextCursor: nil) : listResponses.removeFirst() }
    }
    func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) {
        guard let d = detail[id] else { throw JournalAPIError.notFound }
        return (d.0, d.1)
    }
    func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem {
        TrackerItem(id: "it_new", num: 9, kind: new.kind, title: new.title, originConvoID: new.convoID)
    }
    func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
    func commentItem(id: String, body: String, attachments: [TrackerAttachment], idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) {
        lock.withLock { commentCalls.append((id, idempotencyKey ?? "")) }
        if failComments { throw JournalAPIError.transport("offline") }
        let item = TrackerItem(id: id, num: 1, kind: .question, awaiting: .agent, title: "Q", originConvoID: "c1")
        return (item, TrackerComment(id: "ic_srv", itemID: id, author: .user, body: body))
    }
    func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { fatalError() }
    func reopenItem(id: String, comment: String?) async throws -> TrackerItem { fatalError() }
    func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem { fatalError() }
    func uploadMedia(_ data: Data, contentType: String) async throws -> String { "blob" }
}

final class ItemsSyncTests: XCTestCase {
    private func make(api: FakeItems) throws -> (ItemsSync, JournalStore, AsyncStream<(convoID: String, marker: ItemMarkerEvent)>.Continuation, AsyncStream<SyncConnectionState>.Continuation) {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        let (markers, mc) = AsyncStream<(convoID: String, marker: ItemMarkerEvent)>.makeStream()
        let (states, sc) = AsyncStream<SyncConnectionState>.makeStream()
        let sync = ItemsSync(api: api, store: store, markers: { markers }, connectionStates: { states })
        return (sync, store, mc, sc)
    }
    private func item(_ id: String, num: Int, updated: TimeInterval) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: .task, title: "T", originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: updated))
    }

    func testRefreshPagesAndUsesWatermark() async throws {
        let api = FakeItems()
        api.listResponses = [ItemsPage(items: [item("a", num: 1, updated: 10)], nextCursor: "n"), ItemsPage(items: [item("b", num: 2, updated: 20)], nextCursor: nil)]
        let (sync, store, _, _) = try make(api: api)
        await sync.refresh(scope: .convo("c1"))
        XCTAssertEqual(try store.items(scope: .all).count, 2)
        XCTAssertEqual(api.listQueries.count, 2); XCTAssertEqual(api.listQueries[1].cursor, "n"); XCTAssertEqual(api.listQueries[0].convoID, "c1")
        XCTAssertNil(api.listQueries[0].since, "empty table → full fetch")
        await sync.refresh(scope: .all)
        XCTAssertEqual(api.listQueries[2].since, Date(timeIntervalSince1970: 19), "watermark = max(updated_at) − 1s")
        XCTAssertNil(api.listQueries[2].convoID)
        let supported = await sync.isSupported
        XCTAssertTrue(supported)
    }

    func testNotFoundMarksUnsupported() async throws {
        let api = FakeItems(); api.listError = JournalAPIError.notFound
        let (sync, _, _, _) = try make(api: api)
        await sync.refresh(scope: .all)
        let supported = await sync.isSupported
        XCTAssertFalse(supported)
    }

    func testMarkerRefetchesThatItem() async throws {
        let api = FakeItems()
        api.detail["it_1"] = (item("it_1", num: 1, updated: 5), [TrackerComment(id: "ic_1", itemID: "it_1", author: .user, body: "x")])
        let (sync, store, markers, _) = try make(api: api)
        await sync.start()
        markers.yield((convoID: "c1", marker: ItemMarkerEvent(itemID: "it_1", num: 1, kind: .task, title: "T", action: .commented, by: .user)))
        try await waitUntil { try store.item(id: "it_1") != nil }
        let comments = try store.dbQueueForTests.read { db in try ItemCommentRecord.fetchCount(db) }
        XCTAssertEqual(comments, 1)
    }

    func testOutboxDrainsOnRunningAndDeletesOnSuccess() async throws {
        let api = FakeItems(); api.failComments = true
        let (sync, store, _, states) = try make(api: api)
        await sync.start()
        await sync.enqueueComment(itemID: "it_1", localID: "L1", body: "hello", attachments: [])
        try await waitUntil { try store.itemOutboxRows(itemID: "it_1").first?.attempts == 1 }
        api.failComments = false
        states.yield(.running)
        try await waitUntil { try store.itemOutboxPending().isEmpty }
        XCTAssertEqual(api.commentCalls.map(\.1), ["L1", "L1"], "idempotency key = local id on every attempt")
        XCTAssertEqual(try store.item(id: "it_1")?.awaiting, .agent)
    }

    private func waitUntil(_ cond: @escaping () throws -> Bool, timeout: TimeInterval = 2) async throws {
        let start = Date()
        while !(try cond()) {
            if Date().timeIntervalSince(start) > timeout { XCTFail("timeout"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter ItemsSyncTests`
Expected: compile error.

- [ ] **Step 3: Implement**

Engine (`JournalSyncEngine.swift`): add `import MatronEvents`; add `private var itemMarkerContinuations: [UUID: AsyncStream<(convoID: String, marker: ItemMarkerEvent)>.Continuation] = [:]`; add:

```swift
    /// Tracker markers (`item` events) as they are applied — the
    /// invalidation feed for `ItemsSync`. Mirrors `newConversations()`.
    public nonisolated func itemMarkers() -> AsyncStream<(convoID: String, marker: ItemMarkerEvent)> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.registerItemMarkers(id: id, continuation: continuation) }
            continuation.onTermination = { _ in Task { await self.unregisterItemMarkers(id: id) } }
        }
    }
    private func registerItemMarkers(id: UUID, continuation: AsyncStream<(convoID: String, marker: ItemMarkerEvent)>.Continuation) { itemMarkerContinuations[id] = continuation }
    private func unregisterItemMarkers(id: UUID) { itemMarkerContinuations.removeValue(forKey: id) }
    private func publishItemMarker(_ event: JournalEvent) {
        guard event.type == JournalEventType.item, let marker = ItemMarkerEvent.parse(payload: event.payload) else { return }
        for c in itemMarkerContinuations.values { c.yield((convoID: event.convoID, marker: marker)) }
    }
```

Call `publishItemMarker(event)` at the top of `didApply` and inside the `for event in events` loop of `didApplyBatch`.

`ItemsSync.swift`:

```swift
import Foundation
import os
import MatronModels
import MatronEvents

/// Keeps the local tracker cache fresh (spec: Apps → ItemsSync). Three
/// triggers refetch: a marker event for an item (refetch that item), a
/// panel open / explicit refresh (since-watermark list), and a reconnect
/// (same). An item outbox holds comments and creates written offline and
/// drains whenever the connection is running.
public actor ItemsSync {
    private static let logger = Logger(subsystem: "chat.matron", category: "items-sync")
    private let api: any ItemsProviding
    private let store: JournalStore
    private let markers: @Sendable () -> AsyncStream<(convoID: String, marker: ItemMarkerEvent)>
    private let connectionStates: @Sendable () -> AsyncStream<SyncConnectionState>
    private var markerTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var draining = false
    public private(set) var isSupported = true
    private var supportedContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public init(api: any ItemsProviding, store: JournalStore,
                markers: @escaping @Sendable () -> AsyncStream<(convoID: String, marker: ItemMarkerEvent)>,
                connectionStates: @escaping @Sendable () -> AsyncStream<SyncConnectionState>) {
        self.api = api; self.store = store; self.markers = markers; self.connectionStates = connectionStates
    }

    public func supportedStream() -> AsyncStream<Bool> {
        AsyncStream { c in
            let id = UUID()
            supportedContinuations[id] = c
            c.yield(isSupported)
            c.onTermination = { _ in Task { await self.dropSupported(id) } }
        }
    }
    private func dropSupported(_ id: UUID) { supportedContinuations.removeValue(forKey: id) }
    private func setSupported(_ v: Bool) {
        guard v != isSupported else { return }
        isSupported = v
        for c in supportedContinuations.values { c.yield(v) }
    }

    public func start() {
        guard markerTask == nil else { return }
        let markers = markers()
        markerTask = Task { [weak self] in
            for await (_, marker) in markers {
                guard let self else { return }
                await self.refreshItem(id: marker.itemID)
            }
        }
        let states = connectionStates()
        stateTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                if case .running = state {
                    await self.setSupported(true)   // re-probe: the next refresh decides
                    await self.refresh(scope: .all)
                    await self.drainOutbox()
                }
            }
        }
        Task { await drainOutbox() }
    }

    public func stop() {
        markerTask?.cancel(); markerTask = nil
        stateTask?.cancel(); stateTask = nil
    }

    public func refresh(scope: ItemsScope) async {
        var query = ItemsListQuery()
        query.limit = 500
        query.sort = .updated
        if case .convo(let id) = scope { query.convoID = id }
        if let mark = try? store.itemsMaxUpdatedAt() { query.since = mark.addingTimeInterval(-1) }
        do {
            repeat {
                let page = try await api.listItems(query)
                try store.upsertItems(page.items)
                query.cursor = page.nextCursor
            } while query.cursor != nil
            setSupported(true)
        } catch JournalAPIError.notFound {
            setSupported(false)
        } catch {
            Self.logger.warning("refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func refreshItem(id: String) async {
        do {
            let r = try await api.item(id: id)
            try store.upsertItems([r.item])
            try store.replaceComments(itemID: id, r.comments)
            setSupported(true)
        } catch {
            Self.logger.warning("item refetch \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct CommentPayload: Codable { var body: String; var attachments: [TrackerAttachment] }
    private struct CreatePayload: Codable { var kind: String; var title: String; var body: String; var convoID: String; var attachments: [TrackerAttachment] }

    public func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async {
        let payload = (try? String(data: JSONEncoder().encode(CommentPayload(body: body, attachments: attachments)), encoding: .utf8)) ?? "{}"
        try? store.itemOutboxInsert(ItemOutboxRecord(localID: localID, itemID: itemID, op: "comment", payloadJSON: payload,
                                                     createdAt: Int64(Date().timeIntervalSince1970 * 1000), attempts: 0, lastError: nil))
        await drainOutbox()
    }

    public func enqueueCreate(localID: String, _ new: NewItem) async {
        let payload = (try? String(data: JSONEncoder().encode(CreatePayload(kind: new.kind.rawValue, title: new.title, body: new.body, convoID: new.convoID, attachments: new.attachments)), encoding: .utf8)) ?? "{}"
        try? store.itemOutboxInsert(ItemOutboxRecord(localID: localID, itemID: nil, op: "create", payloadJSON: payload,
                                                     createdAt: Int64(Date().timeIntervalSince1970 * 1000), attempts: 0, lastError: nil))
        await drainOutbox()
    }

    public func drainOutbox() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        guard let rows = try? store.itemOutboxPending() else { return }
        for row in rows {
            do {
                switch row.op {
                case "comment":
                    guard let itemID = row.itemID, let data = row.payloadJSON.data(using: .utf8),
                          let p = try? JSONDecoder().decode(CommentPayload.self, from: data) else { try store.itemOutboxDelete(localID: row.localID); continue }
                    let r = try await api.commentItem(id: itemID, body: p.body, attachments: p.attachments, idempotencyKey: row.localID)
                    try store.itemOutboxDelete(localID: row.localID)
                    try store.upsertItems([r.item])
                    await refreshItem(id: itemID)
                case "create":
                    guard let data = row.payloadJSON.data(using: .utf8), let p = try? JSONDecoder().decode(CreatePayload.self, from: data),
                          let kind = ItemKind(rawValue: p.kind) else { try store.itemOutboxDelete(localID: row.localID); continue }
                    let item = try await api.createItem(NewItem(kind: kind, title: p.title, body: p.body, attachments: p.attachments, convoID: p.convoID), idempotencyKey: row.localID)
                    try store.itemOutboxDelete(localID: row.localID)
                    try store.upsertItems([item])
                default:
                    try store.itemOutboxDelete(localID: row.localID)
                }
            } catch {
                try? store.itemOutboxMarkAttempt(localID: row.localID, error: error.localizedDescription)
                // Stop at the first failure: the rest will fail the same way
                // (offline) and order matters for comments on one item.
                return
            }
        }
    }
}
```

`Package.swift`: add `"MatronEvents"` to `MatronJournal`'s dependencies and to `JournalTests`'s.

- [ ] **Step 4: Run to verify it passes**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter ItemsSyncTests`
Expected: 4 tests pass. Then `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared` (whole package) — the engine change must not break `JournalSyncEngineTests`.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Package.swift MatronShared/Sources/Journal/JournalSyncEngine.swift MatronShared/Sources/Journal/ItemsSync.swift MatronShared/Tests/JournalTests/ItemsSyncTests.swift
git commit -m "items: marker stream from the sync engine + ItemsSync refresh/outbox"
```

---

### Task 6: View models — panel and detail

**Files:**
- Create: `MatronShared/Sources/ViewModels/ItemsPanelViewModel.swift`, `MatronShared/Sources/ViewModels/ItemDetailViewModel.swift`
- Test: `MatronShared/Tests/ViewModelTests/ItemsPanelViewModelTests.swift`, `ItemDetailViewModelTests.swift`

**Interfaces:**

```swift
public protocol ItemsStoreReading: Sendable {
    func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]>
    func itemStream(id: String) -> AsyncStream<TrackerItem?>
    func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]>
    func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]>
}
extension JournalStore: ItemsStoreReading {}

public protocol ItemsSyncing: Sendable {
    func refresh(scope: ItemsScope) async
    func refreshItem(id: String) async
    func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async
    func enqueueCreate(localID: String, _ new: NewItem) async
    func supportedStream() -> AsyncStream<Bool>
}
extension ItemsSync: ItemsSyncing {}

@MainActor @Observable public final class ItemsPanelViewModel {
    public struct Sections: Equatable { needsYou, tasks, decisions, done: [TrackerItem] }
    public var scope: ItemsScope { didSet { resubscribe() } }
    public private(set) var sections = Sections()
    public private(set) var needsYouCount: Int
    public private(set) var isSupported = true
    public private(set) var isRefreshing = false
    public var error: String?
    public let convoID: String
    public init(convoID: String, store: any ItemsStoreReading, api: any ItemsProviding, sync: any ItemsSyncing)
    public func start()          // subscribes store stream + supported stream; kicks refresh(scope)
    public func stop()
    public func refresh() async
    public func move(itemID: String, toIndex: Int)  async  // within `sections.tasks`; optimistic; POST rank; revert on error
    public func create(kind: ItemKind, title: String, body: String) async  // enqueueCreate via sync
    public static func sections(from items: [TrackerItem]) -> Sections
}

@MainActor @Observable public final class ItemDetailViewModel {
    public private(set) var item: TrackerItem?; public private(set) var comments: [TrackerComment]
    public private(set) var pendingComments: [ItemOutboxRecord]; public var draft = ""; public var error: String?
    public private(set) var isBusy = false
    public init(itemID: String, store: any ItemsStoreReading, api: any ItemsProviding, sync: any ItemsSyncing)
    public func start(); public func stop()
    public func submitComment(attachments: [(data: Data, name: String, mime: String)]) async   // uploads, then enqueueComment(localID: UUID)
    public func sendVoiceNote(url: URL) async
    public func close(resolution: ItemResolution, comment: String?) async
    public func reopen() async
    public func reverse() async  // decisions: close(.reversed)
    public var availableResolutions: [ItemResolution]   // task: done, cancelled; question: answered, cancelled; decision: decided, reversed, cancelled
}
```

Sections rule (spec *Panel content*): `needsYou` = `needsUser` (any kind) sorted `updatedAt` desc; `tasks` = kind task, open, sorted rank/num (including ones also in needsYou); `decisions` = kind decision, open, `createdAt` desc; `done` = closed, `closedAt` desc, capped 200. Move: compute `after`/`before` from neighbours in `tasks` after removing the moved one, set local rank to the midpoint for the optimistic reorder, call `api.rankItem`, then `sync.refreshItem`; on error restore the previous list and set `error`.

- [ ] **Step 1: Write the failing tests**

```swift
// MatronShared/Tests/ViewModelTests/ItemsPanelViewModelTests.swift
import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

private final class FakeItemsStore: ItemsStoreReading, @unchecked Sendable {
    var cont: AsyncStream<[TrackerItem]>.Continuation?
    func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> { AsyncStream { self.cont = $0 } }
    func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { _ in } }
    func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { _ in } }
    func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
}
private final class FakeSync: ItemsSyncing, @unchecked Sendable {
    var refreshed: [ItemsScope] = []; var created: [NewItem] = []; var refetched: [String] = []
    func refresh(scope: ItemsScope) async { refreshed.append(scope) }
    func refreshItem(id: String) async { refetched.append(id) }
    func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async {}
    func enqueueCreate(localID: String, _ new: NewItem) async { created.append(new) }
    func supportedStream() -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
}
private final class FakeAPI: ItemsProviding, @unchecked Sendable {
    var rankCalls: [(String, ItemRankChange)] = []; var failRank = false
    func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem {
        rankCalls.append((id, change)); if failRank { throw JournalAPIError.transport("x") }
        return TrackerItem(id: id, num: 0, kind: .task, title: "", originConvoID: "c1")
    }
    func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { fatalError() }
    func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) { fatalError() }
    func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { fatalError() }
    func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
    func commentItem(id: String, body: String, attachments: [TrackerAttachment], idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) { fatalError() }
    func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { fatalError() }
    func reopenItem(id: String, comment: String?) async throws -> TrackerItem { fatalError() }
    func uploadMedia(_ data: Data, contentType: String) async throws -> String { "b" }
}

@MainActor
final class ItemsPanelViewModelTests: XCTestCase {
    private func t(_ id: String, num: Int, kind: ItemKind = .task, awaiting: ItemAwaiting? = .agent, state: ItemState = .open,
                   rank: Double, closed: TimeInterval? = nil) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: kind, state: state, resolution: state == .closed ? .done : nil, awaiting: awaiting,
                    rank: rank, title: "T\(num)", originConvoID: "c1", updatedAt: Date(timeIntervalSince1970: Double(num)),
                    closedAt: closed.map { Date(timeIntervalSince1970: $0) })
    }

    func testSectionsRule() {
        let items = [t("q", num: 1, kind: .question, awaiting: .user, rank: 5), t("a", num: 2, rank: 2), t("b", num: 3, rank: 1),
                     t("d", num: 4, kind: .decision, awaiting: nil, rank: 9), t("x", num: 5, state: .closed, rank: 0, closed: 50),
                     t("y", num: 6, state: .closed, rank: 0, closed: 60), t("ut", num: 7, awaiting: .user, rank: 3)]
        let s = ItemsPanelViewModel.sections(from: items)
        XCTAssertEqual(s.needsYou.map(\.id), ["ut", "q"])
        XCTAssertEqual(s.tasks.map(\.id), ["b", "a", "ut"])
        XCTAssertEqual(s.decisions.map(\.id), ["d"])
        XCTAssertEqual(s.done.map(\.id), ["y", "x"])
    }

    func testStartSubscribesAndRefreshes() async {
        let store = FakeItemsStore(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: FakeAPI(), sync: sync)
        vm.start()
        try? await Task.sleep(nanoseconds: 50_000_000)
        store.cont?.yield([t("a", num: 1, rank: 1)])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["a"])
        XCTAssertEqual(sync.refreshed, [.convo("c1")])
        vm.scope = .all
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sync.refreshed.last, .all)
    }

    func testMoveIsOptimisticAndRevertsOnFailure() async {
        let store = FakeItemsStore(); let api = FakeAPI(); let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: "c1", store: store, api: api, sync: sync)
        vm.start()
        try? await Task.sleep(nanoseconds: 50_000_000)
        store.cont?.yield([t("a", num: 1, rank: 1), t("b", num: 2, rank: 2), t("c", num: 3, rank: 3)])
        try? await Task.sleep(nanoseconds: 50_000_000)
        await vm.move(itemID: "c", toIndex: 0)
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(api.rankCalls.first?.1, ItemRankChange(position: "top"))
        XCTAssertEqual(sync.refetched, ["c"])
        api.failRank = true
        await vm.move(itemID: "a", toIndex: 2)
        XCTAssertEqual(vm.sections.tasks.map(\.id), ["c", "a", "b"], "reverted")
        XCTAssertNotNil(vm.error)
        api.failRank = false
        await vm.move(itemID: "a", toIndex: 1)   // between c and b
        XCTAssertEqual(api.rankCalls.last?.1, ItemRankChange(after: "c", before: "b"))
    }

    func testCreateEnqueues() async {
        let sync = FakeSync()
        let vm = ItemsPanelViewModel(convoID: "c1", store: FakeItemsStore(), api: FakeAPI(), sync: sync)
        await vm.create(kind: .task, title: "  Do X ", body: "why")
        XCTAssertEqual(sync.created.first?.title, "Do X"); XCTAssertEqual(sync.created.first?.convoID, "c1")
        await vm.create(kind: .task, title: "   ", body: "")
        XCTAssertEqual(sync.created.count, 1); XCTAssertNotNil(vm.error)
    }
}
```

```swift
// MatronShared/Tests/ViewModelTests/ItemDetailViewModelTests.swift
import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

@MainActor
final class ItemDetailViewModelTests: XCTestCase {
    private final class Store: ItemsStoreReading, @unchecked Sendable {
        var itemCont: AsyncStream<TrackerItem?>.Continuation?; var commentsCont: AsyncStream<[TrackerComment]>.Continuation?
        func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> { AsyncStream { _ in } }
        func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { self.itemCont = $0 } }
        func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { self.commentsCont = $0 } }
        func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { $0.yield([]) } }
    }
    private final class Sync: ItemsSyncing, @unchecked Sendable {
        var comments: [(String, String, [TrackerAttachment])] = []; var refetched: [String] = []
        func refresh(scope: ItemsScope) async {}
        func refreshItem(id: String) async { refetched.append(id) }
        func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async { comments.append((itemID, body, attachments)) }
        func enqueueCreate(localID: String, _ new: NewItem) async {}
        func supportedStream() -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
    }
    private final class API: ItemsProviding, @unchecked Sendable {
        var uploads: [String] = []; var closes: [(ItemResolution, String?)] = []; var reopens = 0
        func uploadMedia(_ data: Data, contentType: String) async throws -> String { uploads.append(contentType); return "blob-\(uploads.count)" }
        func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { closes.append((resolution, comment)); return TrackerItem(id: id, num: 1, kind: .task, state: .closed, title: "", originConvoID: "c1") }
        func reopenItem(id: String, comment: String?) async throws -> TrackerItem { reopens += 1; return TrackerItem(id: id, num: 1, kind: .task, title: "", originConvoID: "c1") }
        func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { fatalError() }
        func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) { fatalError() }
        func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { fatalError() }
        func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
        func commentItem(id: String, body: String, attachments: [TrackerAttachment], idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) { fatalError() }
        func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem { fatalError() }
    }

    func testSubmitUploadsThenEnqueuesAndClearsDraft() async {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        vm.draft = " use A "
        await vm.submitComment(attachments: [(Data([1]), "s.png", "image/png")])
        XCTAssertEqual(api.uploads, ["image/png"])
        XCTAssertEqual(sync.comments.first?.1, "use A")
        XCTAssertEqual(sync.comments.first?.2.first?.blobRef, "blob-1")
        XCTAssertEqual(vm.draft, "")
        await vm.submitComment(attachments: [])
        XCTAssertEqual(sync.comments.count, 1, "empty draft + no attachments is a no-op")
    }

    func testVoiceNoteIsAnAudioAttachmentComment() async throws {
        let api = API(); let sync = Sync()
        let vm = ItemDetailViewModel(itemID: "it_1", store: Store(), api: api, sync: sync)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID()).m4a")
        try Data([0, 1, 2]).write(to: url)
        await vm.sendVoiceNote(url: url)
        XCTAssertEqual(api.uploads, ["audio/mp4"])
        XCTAssertEqual(sync.comments.first?.2.first?.mime, "audio/mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCloseReopenReverseAndResolutions() async {
        let api = API(); let sync = Sync(); let store = Store()
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: api, sync: sync)
        vm.start()
        try? await Task.sleep(nanoseconds: 50_000_000)
        store.itemCont?.yield(TrackerItem(id: "it_1", num: 1, kind: .decision, title: "D", originConvoID: "c1"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.availableResolutions, [.decided, .reversed, .cancelled])
        await vm.reverse()
        XCTAssertEqual(api.closes.first?.0, .reversed)
        await vm.reopen()
        XCTAssertEqual(api.reopens, 1)
        XCTAssertEqual(sync.refetched, ["it_1", "it_1"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter "ItemsPanelViewModelTests|ItemDetailViewModelTests"`
Expected: compile errors.

- [ ] **Step 3: Implement**

`ItemsPanelViewModel.swift`:

```swift
import Foundation
import Observation
import MatronModels
import MatronJournal

public protocol ItemsStoreReading: Sendable {
    func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]>
    func itemStream(id: String) -> AsyncStream<TrackerItem?>
    func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]>
    func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]>
}
extension JournalStore: ItemsStoreReading {}

public protocol ItemsSyncing: Sendable {
    func refresh(scope: ItemsScope) async
    func refreshItem(id: String) async
    func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async
    func enqueueCreate(localID: String, _ new: NewItem) async
    func supportedStream() -> AsyncStream<Bool>
}
extension ItemsSync: ItemsSyncing {}

@MainActor @Observable
public final class ItemsPanelViewModel {
    public struct Sections: Equatable, Sendable {
        public var needsYou: [TrackerItem] = []
        public var tasks: [TrackerItem] = []
        public var decisions: [TrackerItem] = []
        public var done: [TrackerItem] = []
        public init() {}
        public var isEmpty: Bool { needsYou.isEmpty && tasks.isEmpty && decisions.isEmpty && done.isEmpty }
    }

    public let convoID: String
    public var scope: ItemsScope { didSet { if scope != oldValue { resubscribe() } } }
    public private(set) var sections = Sections()
    public private(set) var needsYouCount = 0
    public private(set) var isSupported = true
    public private(set) var isRefreshing = false
    public var error: String?

    private let store: any ItemsStoreReading
    private let api: any ItemsProviding
    private let sync: any ItemsSyncing
    private var itemsTask: Task<Void, Never>?
    private var supportedTask: Task<Void, Never>?
    private var allItems: [TrackerItem] = []

    public init(convoID: String, store: any ItemsStoreReading, api: any ItemsProviding, sync: any ItemsSyncing) {
        self.convoID = convoID; self.scope = .convo(convoID); self.store = store; self.api = api; self.sync = sync
    }

    public static func sections(from items: [TrackerItem]) -> Sections {
        var s = Sections()
        s.needsYou = items.filter(\.needsUser).sorted { $0.updatedAt > $1.updatedAt }
        s.tasks = items.filter { $0.kind == .task && $0.state == .open }.sorted { ($0.rank, $0.num) < ($1.rank, $1.num) }
        s.decisions = items.filter { $0.kind == .decision && $0.state == .open }.sorted { $0.createdAt > $1.createdAt }
        s.done = Array(items.filter { $0.state == .closed }.sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }.prefix(200))
        return s
    }

    public func start() {
        resubscribe()
        supportedTask?.cancel()
        supportedTask = Task { [weak self] in
            guard let stream = self?.sync.supportedStream() else { return }
            for await v in stream {
                guard let self, !Task.isCancelled else { return }
                self.isSupported = v
            }
        }
    }

    public func stop() {
        itemsTask?.cancel(); itemsTask = nil
        supportedTask?.cancel(); supportedTask = nil
    }

    private func resubscribe() {
        itemsTask?.cancel()
        let scope = scope
        itemsTask = Task { [weak self] in
            guard let stream = self?.store.itemsStream(scope: scope) else { return }
            for await items in stream {
                guard let self, !Task.isCancelled else { return }
                self.allItems = items
                self.sections = Self.sections(from: items)
                self.needsYouCount = self.sections.needsYou.count
            }
        }
        Task { await refresh() }
    }

    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await sync.refresh(scope: scope)
    }

    /// Drag reorder inside the Tasks section. Optimistic: the local list is
    /// reordered first, the journal is told second, and a failure restores
    /// the previous order and surfaces the error.
    public func move(itemID: String, toIndex: Int) async {
        let before = sections.tasks
        guard let from = before.firstIndex(where: { $0.id == itemID }) else { return }
        var reordered = before
        let moved = reordered.remove(at: from)
        let target = min(max(toIndex, 0), reordered.count)
        reordered.insert(moved, at: target)
        guard reordered.map(\.id) != before.map(\.id) else { return }
        let change: ItemRankChange
        if target == 0 { change = ItemRankChange(position: "top") }
        else if target == reordered.count - 1 { change = ItemRankChange(position: "bottom") }
        else { change = ItemRankChange(after: reordered[target - 1].id, before: reordered[target + 1].id) }
        sections.tasks = reordered
        do {
            _ = try await api.rankItem(itemID, change)
            await sync.refreshItem(id: itemID)
        } catch {
            sections.tasks = before
            self.error = error.localizedDescription
        }
    }

    public func create(kind: ItemKind, title: String, body: String) async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 200 else { error = "Give the item a title (up to 200 characters)."; return }
        await sync.enqueueCreate(localID: UUID().uuidString, NewItem(kind: kind, title: t, body: body, convoID: convoID))
    }
}
```

`ItemDetailViewModel.swift`:

```swift
import Foundation
import Observation
import MatronModels
import MatronJournal

@MainActor @Observable
public final class ItemDetailViewModel {
    public let itemID: String
    public private(set) var item: TrackerItem?
    public private(set) var comments: [TrackerComment] = []
    public private(set) var pendingComments: [ItemOutboxRecord] = []
    public var draft = ""
    public var error: String?
    public private(set) var isBusy = false

    private let store: any ItemsStoreReading
    private let api: any ItemsProviding
    private let sync: any ItemsSyncing
    private var tasks: [Task<Void, Never>] = []

    public init(itemID: String, store: any ItemsStoreReading, api: any ItemsProviding, sync: any ItemsSyncing) {
        self.itemID = itemID; self.store = store; self.api = api; self.sync = sync
    }

    public func start() {
        stop()
        let id = itemID
        tasks.append(Task { [weak self] in
            guard let s = self?.store.itemStream(id: id) else { return }
            for await v in s { guard let self, !Task.isCancelled else { return }; self.item = v }
        })
        tasks.append(Task { [weak self] in
            guard let s = self?.store.commentsStream(itemID: id) else { return }
            for await v in s { guard let self, !Task.isCancelled else { return }; self.comments = v }
        })
        tasks.append(Task { [weak self] in
            guard let s = self?.store.itemOutboxStream(itemID: id) else { return }
            for await v in s { guard let self, !Task.isCancelled else { return }; self.pendingComments = v }
        })
        Task { await sync.refreshItem(id: id) }
    }

    public func stop() { tasks.forEach { $0.cancel() }; tasks = [] }

    public var availableResolutions: [ItemResolution] {
        switch item?.kind {
        case .task: return [.done, .cancelled]
        case .question: return [.answered, .cancelled]
        case .decision: return [.decided, .reversed, .cancelled]
        case nil: return []
        }
    }

    public func submitComment(attachments: [(data: Data, name: String, mime: String)]) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        var uploaded: [TrackerAttachment] = []
        do {
            for a in attachments {
                let ref = try await api.uploadMedia(a.data, contentType: a.mime)
                uploaded.append(TrackerAttachment(blobRef: ref, mime: a.mime, name: a.name, size: Int64(a.data.count)))
            }
        } catch {
            self.error = "Couldn't upload an attachment: \(error.localizedDescription)"
            return
        }
        let pending = draft
        draft = ""
        await sync.enqueueComment(itemID: itemID, localID: UUID().uuidString, body: text, attachments: uploaded)
        _ = pending
    }

    public func sendVoiceNote(url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { error = "Voice note was empty."; return }
        await submitComment(attachments: [(data, "voice-note.m4a", "audio/mp4")])
    }

    public func close(resolution: ItemResolution, comment: String?) async {
        await run { _ = try await self.api.closeItem(id: self.itemID, resolution: resolution, comment: comment) }
    }

    public func reopen() async {
        await run { _ = try await self.api.reopenItem(id: self.itemID, comment: nil) }
    }

    public func reverse() async { await close(resolution: .reversed, comment: nil) }

    private func run(_ op: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do { try await op(); await sync.refreshItem(id: itemID) }
        catch { self.error = error.localizedDescription }
    }
}
```

The `submitComment` clears `draft` before the enqueue but never restores it (the outbox holds the text durably). Note: `_ = pending` is a leftover from a restore path that isn't needed — remove it and the `pending` line.

- [ ] **Step 4: Run to verify it passes**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter "ItemsPanelViewModelTests|ItemDetailViewModelTests"`
Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/ViewModels/ItemsPanelViewModel.swift MatronShared/Sources/ViewModels/ItemDetailViewModel.swift MatronShared/Tests/ViewModelTests/ItemsPanelViewModelTests.swift MatronShared/Tests/ViewModelTests/ItemDetailViewModelTests.swift
git commit -m "items: panel and detail view models"
```

---

### Task 7: Shared views — glyph, row, list, badge

**Files:**
- Create: `MatronShared/Sources/DesignSystem/Items/ItemGlyph.swift`, `ItemRow.swift`, `ItemsListView.swift`, `NeedsYouBadge.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/ItemsListSnapshotTests.swift`

**Interfaces:**

```swift
public enum ItemGlyph { public static func symbol(_ kind: ItemKind) -> String  // "questionmark.circle", "checklist", "scalemass"
                        public static func tint(_ kind: ItemKind) -> Color }
public struct ItemRow: View { public init(item: TrackerItem, showsOrigin: String? = nil, thumbnail: Image? = nil) }
public struct NeedsYouBadge: View { public init(count: Int) }   // "❓ N" capsule, EmptyView when 0; same metrics as UnreadBadge, orange tint
public struct ItemsListView: View {
    public struct Model: Equatable { needsYou, tasks, decisions, done: [TrackerItem]; originTitles: [String: String]; isSupported: Bool; isRefreshing: Bool }
    public init(model: Model, scope: Binding<ItemsScope>, convoID: String,
                thumbnail: @escaping (TrackerItem) -> Image?,
                onSelect: @escaping (TrackerItem) -> Void,
                onMove: @escaping (String, Int) -> Void,        // itemID, new index within tasks
                onCreate: @escaping () -> Void,
                onOpenConversation: @escaping (String) -> Void)
}
```

`ItemsListView` = `List` with four `Section`s (headers "Needs you", "Tasks", "Decisions", "Done"), `.onMove` on the Tasks section only (SwiftUI's `EditButton`-less move: use `.moveDisabled(false)` and the section's `ForEach.onMove`; on Mac, `List` supports drag-reorder natively), a scope `Picker` (segmented, "This chat" / "All") in a header row, a **+** toolbar/button, empty state `ContentUnavailableView("Nothing tracked yet", systemImage: "checklist")`, and an "unsupported" state `ContentUnavailableView("Tracker not available", systemImage: "exclamationmark.triangle", description: Text("Update the journal server to use items."))`.

- [ ] **Step 1: Write the failing snapshot test**

```swift
// MatronShared/Tests/DesignSystemSnapshotTests/ItemsListSnapshotTests.swift
import SwiftUI
import XCTest
import MatronModels
@testable import MatronDesignSystem

@MainActor
final class ItemsListSnapshotTests: XCTestCase {
    private func t(_ id: String, num: Int, kind: ItemKind, awaiting: ItemAwaiting?, title: String, state: ItemState = .open, comments: Int = 0, image: Bool = false) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: kind, state: state, resolution: state == .closed ? .done : nil, awaiting: awaiting, rank: Double(num),
                    title: title, body: "Some body text that previews on one line and then gets cut off", originConvoID: "c1",
                    createdAt: .init(timeIntervalSince1970: 1_770_000_000), updatedAt: .init(timeIntervalSince1970: 1_770_000_000),
                    closedAt: state == .closed ? .init(timeIntervalSince1970: 1_770_000_100) : nil, commentCount: comments, hasImage: image)
    }

    func testPopulatedList() {
        let model = ItemsListView.Model(
            needsYou: [t("q1", num: 12, kind: .question, awaiting: .user, title: "Which auth library?", comments: 2, image: true)],
            tasks: [t("t1", num: 13, kind: .task, awaiting: .agent, title: "Refactor the auth module"), t("t2", num: 14, kind: .task, awaiting: .agent, title: "Write the migration")],
            decisions: [t("d1", num: 11, kind: .decision, awaiting: nil, title: "Use SQLite for the cache")],
            done: [t("x1", num: 3, kind: .task, awaiting: nil, title: "Set up CI", state: .closed)],
            originTitles: [:], isSupported: true, isRefreshing: false)
        let view = ItemsListView(model: model, scope: .constant(.convo("c1")), convoID: "c1", thumbnail: { _ in nil },
                                 onSelect: { _ in }, onMove: { _, _ in }, onCreate: {}, onOpenConversation: { _ in })
            .frame(width: 360, height: 560)
        assertVariants(of: view, named: "ItemsList_populated")
    }

    func testEmptyAndUnsupported() {
        let empty = ItemsListView.Model(needsYou: [], tasks: [], decisions: [], done: [], originTitles: [:], isSupported: true, isRefreshing: false)
        assertVariants(of: ItemsListView(model: empty, scope: .constant(.all), convoID: "c1", thumbnail: { _ in nil }, onSelect: { _ in }, onMove: { _, _ in }, onCreate: {}, onOpenConversation: { _ in }).frame(width: 360, height: 300), named: "ItemsList_empty")
        var unsupported = empty; unsupported.isSupported = false
        assertVariants(of: ItemsListView(model: unsupported, scope: .constant(.all), convoID: "c1", thumbnail: { _ in nil }, onSelect: { _ in }, onMove: { _, _ in }, onCreate: {}, onOpenConversation: { _ in }).frame(width: 360, height: 300), named: "ItemsList_unsupported")
    }

    func testNeedsYouBadge() {
        assertVariants(of: HStack { NeedsYouBadge(count: 3); NeedsYouBadge(count: 120); NeedsYouBadge(count: 0) }.padding(), named: "NeedsYouBadge")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MatronShared --filter ItemsListSnapshotTests`
Expected: compile error.

- [ ] **Step 3: Implement**

`ItemGlyph.swift`:

```swift
import SwiftUI
import MatronModels

public enum ItemGlyph {
    public static func symbol(_ kind: ItemKind) -> String {
        switch kind { case .question: return "questionmark.circle.fill"; case .task: return "checklist"; case .decision: return "scalemass.fill" }
    }
    public static func tint(_ kind: ItemKind) -> Color {
        switch kind { case .question: return .orange; case .task: return .accentColor; case .decision: return .purple }
    }
    public static func label(_ kind: ItemKind) -> String {
        switch kind { case .question: return "Question"; case .task: return "Task"; case .decision: return "Decision" }
    }
    public static func label(_ r: ItemResolution) -> String {
        switch r { case .done: return "Done"; case .answered: return "Answered"; case .decided: return "Decided"; case .reversed: return "Reversed"; case .cancelled: return "Cancelled" }
    }
}
```

`NeedsYouBadge.swift`:

```swift
import SwiftUI

/// "The agent is waiting on you" count — sibling of `UnreadBadge` with the
/// same metrics so the two sit together on a chat row without a height
/// change (ChatRowHeightTests pins that).
public struct NeedsYouBadge: View {
    private let count: Int
    public init(count: Int) { self.count = count }
    public var body: some View {
        if count > 0 {
            Label(count > 99 ? "99+" : "\(count)", systemImage: "questionmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .frame(minWidth: 18)
                .background(Color.orange, in: Capsule())
                .accessibilityLabel("\(count) items need you")
        }
    }
}
```

`ItemRow.swift`:

```swift
import SwiftUI
import MatronModels

public struct ItemRow: View {
    let item: TrackerItem
    let origin: String?
    let thumbnail: Image?
    public init(item: TrackerItem, showsOrigin origin: String? = nil, thumbnail: Image? = nil) {
        self.item = item; self.origin = origin; self.thumbnail = thumbnail
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ItemGlyph.symbol(item.kind))
                .foregroundStyle(ItemGlyph.tint(item.kind))
                .font(.body)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(item.num)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                }
                if !item.body.isEmpty {
                    Text(item.body.replacingOccurrences(of: "\n", with: " ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    if let origin { Text(origin).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    if item.needsUser {
                        Text("Needs you").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    } else if item.state == .closed, let r = item.resolution {
                        Text(ItemGlyph.label(r)).font(.caption2).foregroundStyle(.tertiary)
                    } else if item.awaiting == .agent {
                        Text("With the agent").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if item.commentCount > 0 {
                        Label("\(item.commentCount)", systemImage: "bubble.left").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let thumbnail {
                thumbnail.resizable().scaledToFill().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
            } else if item.hasImage {
                Image(systemName: "photo").foregroundStyle(.tertiary).frame(width: 40, height: 40)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ItemGlyph.label(item.kind)) \(item.num), \(item.title)\(item.needsUser ? ", needs you" : "")")
    }
}
```

`ItemsListView.swift`:

```swift
import SwiftUI
import MatronModels

public struct ItemsListView: View {
    public struct Model: Equatable {
        public var needsYou: [TrackerItem]
        public var tasks: [TrackerItem]
        public var decisions: [TrackerItem]
        public var done: [TrackerItem]
        public var originTitles: [String: String]
        public var isSupported: Bool
        public var isRefreshing: Bool
        public init(needsYou: [TrackerItem], tasks: [TrackerItem], decisions: [TrackerItem], done: [TrackerItem],
                    originTitles: [String: String], isSupported: Bool, isRefreshing: Bool) {
            self.needsYou = needsYou; self.tasks = tasks; self.decisions = decisions; self.done = done
            self.originTitles = originTitles; self.isSupported = isSupported; self.isRefreshing = isRefreshing
        }
        var isEmpty: Bool { needsYou.isEmpty && tasks.isEmpty && decisions.isEmpty && done.isEmpty }
    }

    let model: Model
    @Binding var scope: ItemsScope
    let convoID: String
    let thumbnail: (TrackerItem) -> Image?
    let onSelect: (TrackerItem) -> Void
    let onMove: (String, Int) -> Void
    let onCreate: () -> Void
    let onOpenConversation: (String) -> Void

    public init(model: Model, scope: Binding<ItemsScope>, convoID: String, thumbnail: @escaping (TrackerItem) -> Image?,
                onSelect: @escaping (TrackerItem) -> Void, onMove: @escaping (String, Int) -> Void,
                onCreate: @escaping () -> Void, onOpenConversation: @escaping (String) -> Void) {
        self.model = model; self._scope = scope; self.convoID = convoID; self.thumbnail = thumbnail
        self.onSelect = onSelect; self.onMove = onMove; self.onCreate = onCreate; self.onOpenConversation = onOpenConversation
    }

    private var isAll: Bool { if case .all = scope { return true } else { return false } }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Scope", selection: Binding(get: { isAll ? 1 : 0 }, set: { scope = $0 == 1 ? .all : .convo(convoID) })) {
                    Text("This chat").tag(0)
                    Text("All").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button(action: onCreate) { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New item")
                    .help("New item")
            }
            .padding(.horizontal).padding(.vertical, 8)
            if !model.isSupported {
                ContentUnavailableView("Tracker not available", systemImage: "exclamationmark.triangle",
                                       description: Text("Update the journal server to use items."))
            } else if model.isEmpty {
                ContentUnavailableView("Nothing tracked yet", systemImage: "checklist",
                                       description: Text("Questions, tasks and decisions the agent files appear here."))
            } else {
                List {
                    section("Needs you", model.needsYou, movable: false)
                    section("Tasks", model.tasks, movable: true)
                    section("Decisions", model.decisions, movable: false)
                    section("Done", model.done, movable: false)
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [TrackerItem], movable: Bool) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    Button { onSelect(item) } label: {
                        ItemRow(item: item, showsOrigin: isAll ? (model.originTitles[item.originConvoID] ?? item.originConvoID) : nil,
                                thumbnail: thumbnail(item))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.primary)
                    .contextMenu {
                        if isAll { Button("Open conversation") { onOpenConversation(item.originConvoID) } }
                    }
                }
                .onMove(perform: movable ? { from, to in
                    guard let f = from.first else { return }
                    let id = items[f].id
                    onMove(id, to > f ? to - 1 : to)
                } : nil)
                .moveDisabled(!movable)
            }
        }
    }
}
```

- [ ] **Step 4: Record snapshots, then run with skip to confirm compile**

Run: `swift test --package-path MatronShared --filter ItemsListSnapshotTests` (records on first run — commit the PNGs under `MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/ItemsListSnapshotTests/`), then re-run: PASS.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/DesignSystem/Items MatronShared/Tests/DesignSystemSnapshotTests/ItemsListSnapshotTests.swift MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/ItemsListSnapshotTests
git commit -m "items: shared list, row, glyphs, needs-you badge"
```

---

### Task 8: Shared views — detail with thread and comment composer

**Files:**
- Create: `MatronShared/Sources/DesignSystem/Items/ItemDetailView.swift`, `ItemCommentComposer.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/ItemDetailSnapshotTests.swift`

**Interfaces:**

```swift
public struct ItemDetailView: View {
    public struct Model: Equatable { item: TrackerItem; comments: [TrackerComment]; pending: [PendingComment]; originTitle: String?; availableResolutions: [ItemResolution]; isBusy: Bool }
    public struct PendingComment: Equatable, Identifiable { id: String; body: String; attachmentCount: Int; attempts: Int; lastError: String? }
    public init(model: Model, draft: Binding<String>,
                image: @escaping (TrackerAttachment) -> Image?,          // inline images (cache or nil → placeholder)
                onOpenAttachment: @escaping (TrackerAttachment) -> Void,
                onOpenLink: @escaping (URL) -> Void,
                onOpenConversation: @escaping (String) -> Void,
                onSubmit: @escaping () -> Void,
                onAttach: @escaping () -> Void,                            // host presents its picker
                onVoiceNote: @escaping () -> Void,                         // host runs its recorder
                onClose: @escaping (ItemResolution) -> Void,
                onReopen: @escaping () -> Void)
}
```

Layout (spec *Detail*): header (glyph, `#num`, kind label, state pill "Open / Needs you / Closed · Done"), title, origin conversation button, labels as chips, links as `Link`-like buttons, body via `MarkdownText(item.body, theme: .matronMessage)`, item attachments (images inline via `AttachmentImage`, files as rows), then the thread: each comment = author line ("You" / "Agent" + relative date), body Markdown, attachments (audio shows a waveform glyph + transcript text or "Transcribing…"), status comments as a centred muted line ("Closed as reversed"); pending comments render with the `SendStateIndicator`-style "Queued" caption; then the action bar: **Close ▾** (menu of `availableResolutions`) when open, **Reopen** when closed; then `ItemCommentComposer` (text field, attach, mic, send). `.disabled(model.isBusy)` on the action bar.

- [ ] **Step 1: Write the failing snapshot test**

```swift
// MatronShared/Tests/DesignSystemSnapshotTests/ItemDetailSnapshotTests.swift
import SwiftUI
import XCTest
import MatronModels
@testable import MatronDesignSystem

@MainActor
final class ItemDetailSnapshotTests: XCTestCase {
    func testQuestionWithThread() {
        let item = TrackerItem(id: "it_1", num: 12, kind: .question, awaiting: .agent, title: "Which auth library?",
                               body: "Two options:\n\n1. **Keep** the monorepo one\n2. Switch to `authlib`", labels: ["auth", "backend"],
                               links: [TrackerLink(url: "https://github.com/x/y/issues/9", title: "Issue #9")],
                               attachments: [TrackerAttachment(blobRef: "b", mime: "image/png", name: "shot.png", size: 1000)],
                               originConvoID: "c1", createdAt: .init(timeIntervalSince1970: 1_770_000_000), updatedAt: .init(timeIntervalSince1970: 1_770_000_000), commentCount: 2)
        let comments = [
            TrackerComment(id: "c1", itemID: "it_1", author: .user, body: "Keep the monorepo one.",
                           attachments: [TrackerAttachment(blobRef: "v", mime: "audio/mp4", name: "voice-note.m4a", size: 100, transcript: "keep the monorepo one, it's already tested")],
                           createdAt: .init(timeIntervalSince1970: 1_770_000_100)),
            TrackerComment(id: "c2", itemID: "it_1", author: .agent, body: "Noted — wiring it now.", createdAt: .init(timeIntervalSince1970: 1_770_000_200)),
        ]
        let model = ItemDetailView.Model(item: item, comments: comments,
                                         pending: [.init(id: "L1", body: "Also rename the module", attachmentCount: 0, attempts: 2, lastError: "offline")],
                                         originTitle: "auth refactor", availableResolutions: [.answered, .cancelled], isBusy: false)
        let view = ItemDetailView(model: model, draft: .constant(""), image: { _ in Image(systemName: "photo") },
                                  onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                                  onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {})
            .frame(width: 380, height: 760)
        assertVariants(of: view, named: "ItemDetail_question")
    }

    func testClosedDecision() {
        let item = TrackerItem(id: "it_2", num: 4, kind: .decision, state: .closed, resolution: .reversed, title: "Use SQLite for the cache",
                               body: "Because it is already a dependency.", originConvoID: "c1", closedAt: .init(timeIntervalSince1970: 1_770_000_300))
        let status = TrackerComment(id: "s", itemID: "it_2", author: .user, kind: .status, body: "Postgres after all",
                                    statusFrom: .init(state: .open, resolution: nil, awaiting: nil), statusTo: .init(state: .closed, resolution: .reversed, awaiting: nil),
                                    createdAt: .init(timeIntervalSince1970: 1_770_000_300))
        let model = ItemDetailView.Model(item: item, comments: [status], pending: [], originTitle: nil, availableResolutions: [], isBusy: false)
        let view = ItemDetailView(model: model, draft: .constant("Draft text"), image: { _ in nil },
                                  onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                                  onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {})
            .frame(width: 380, height: 520)
        assertVariants(of: view, named: "ItemDetail_closedDecision")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MatronShared --filter ItemDetailSnapshotTests`
Expected: compile error.

- [ ] **Step 3: Implement**

`ItemCommentComposer.swift`:

```swift
import SwiftUI

public struct ItemCommentComposer: View {
    @Binding var draft: String
    let isBusy: Bool
    let onSubmit: () -> Void
    let onAttach: () -> Void
    let onVoiceNote: () -> Void
    public init(draft: Binding<String>, isBusy: Bool, onSubmit: @escaping () -> Void, onAttach: @escaping () -> Void, onVoiceNote: @escaping () -> Void) {
        self._draft = draft; self.isBusy = isBusy; self.onSubmit = onSubmit; self.onAttach = onAttach; self.onVoiceNote = onVoiceNote
    }
    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: onAttach) { Image(systemName: "paperclip") }.buttonStyle(.plain).accessibilityLabel("Attach")
            TextField("Reply…", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: onVoiceNote) { Image(systemName: "mic.fill") }.buttonStyle(.plain).accessibilityLabel("Record voice note")
            } else {
                Button(action: onSubmit) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).accessibilityLabel("Send reply").keyboardShortcut(.return, modifiers: .command)
            }
        }
        .disabled(isBusy)
        .padding(10)
        .background(.bar)
    }
}
```

`ItemDetailView.swift`:

```swift
import SwiftUI
import MatronModels

public struct ItemDetailView: View {
    public struct PendingComment: Equatable, Identifiable {
        public let id: String; public let body: String; public let attachmentCount: Int; public let attempts: Int; public let lastError: String?
        public init(id: String, body: String, attachmentCount: Int, attempts: Int, lastError: String?) {
            self.id = id; self.body = body; self.attachmentCount = attachmentCount; self.attempts = attempts; self.lastError = lastError
        }
    }
    public struct Model: Equatable {
        public var item: TrackerItem; public var comments: [TrackerComment]; public var pending: [PendingComment]
        public var originTitle: String?; public var availableResolutions: [ItemResolution]; public var isBusy: Bool
        public init(item: TrackerItem, comments: [TrackerComment], pending: [PendingComment], originTitle: String?, availableResolutions: [ItemResolution], isBusy: Bool) {
            self.item = item; self.comments = comments; self.pending = pending; self.originTitle = originTitle
            self.availableResolutions = availableResolutions; self.isBusy = isBusy
        }
    }

    let model: Model
    @Binding var draft: String
    let image: (TrackerAttachment) -> Image?
    let onOpenAttachment: (TrackerAttachment) -> Void
    let onOpenLink: (URL) -> Void
    let onOpenConversation: (String) -> Void
    let onSubmit: () -> Void
    let onAttach: () -> Void
    let onVoiceNote: () -> Void
    let onClose: (ItemResolution) -> Void
    let onReopen: () -> Void

    public init(model: Model, draft: Binding<String>, image: @escaping (TrackerAttachment) -> Image?,
                onOpenAttachment: @escaping (TrackerAttachment) -> Void, onOpenLink: @escaping (URL) -> Void,
                onOpenConversation: @escaping (String) -> Void, onSubmit: @escaping () -> Void, onAttach: @escaping () -> Void,
                onVoiceNote: @escaping () -> Void, onClose: @escaping (ItemResolution) -> Void, onReopen: @escaping () -> Void) {
        self.model = model; self._draft = draft; self.image = image; self.onOpenAttachment = onOpenAttachment
        self.onOpenLink = onOpenLink; self.onOpenConversation = onOpenConversation; self.onSubmit = onSubmit
        self.onAttach = onAttach; self.onVoiceNote = onVoiceNote; self.onClose = onClose; self.onReopen = onReopen
    }

    private var item: TrackerItem { model.item }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if !item.labels.isEmpty || !item.links.isEmpty { meta }
                    if !item.body.isEmpty { MarkdownText(item.body, theme: .matronMessage) }
                    attachments(item.attachments)
                    Divider()
                    ForEach(model.comments) { comment in commentView(comment) }
                    ForEach(model.pending) { p in pendingView(p) }
                }
                .padding()
            }
            actionBar
            ItemCommentComposer(draft: $draft, isBusy: model.isBusy, onSubmit: onSubmit, onAttach: onAttach, onVoiceNote: onVoiceNote)
        }
    }

    private var statusText: String {
        if item.needsUser { return "Needs you" }
        if item.state == .closed { return "Closed" + (item.resolution.map { " · \(ItemGlyph.label($0))" } ?? "") }
        return item.awaiting == .agent ? "With the agent" : "Open"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: ItemGlyph.symbol(item.kind)).foregroundStyle(ItemGlyph.tint(item.kind))
                Text("#\(item.num) · \(ItemGlyph.label(item.kind))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(statusText).font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((item.needsUser ? Color.orange : Color.secondary).opacity(0.18), in: Capsule())
            }
            Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
            if let originTitle = model.originTitle {
                Button { onOpenConversation(item.originConvoID) } label: {
                    Label(originTitle, systemImage: "bubble.left.and.bubble.right").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.labels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.labels, id: \.self) { l in
                        Text(l).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
            }
            ForEach(item.links, id: \.url) { link in
                Button { if let u = URL(string: link.url) { onOpenLink(u) } } label: {
                    Label(link.title ?? link.url, systemImage: "link").font(.caption).lineLimit(1)
                }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    private func attachments(_ list: [TrackerAttachment]) -> some View {
        ForEach(list, id: \.blobRef) { a in
            if a.isImage {
                Button { onOpenAttachment(a) } label: {
                    (image(a) ?? Image(systemName: "photo")).resizable().scaledToFit().frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            } else if a.isAudio {
                VStack(alignment: .leading, spacing: 4) {
                    Button { onOpenAttachment(a) } label: { Label("Voice note", systemImage: "waveform") }.buttonStyle(.plain)
                    Text(a.transcript?.isEmpty == false ? a.transcript! : "Transcribing…")
                        .font(.subheadline).foregroundStyle(a.transcript == nil ? .tertiary : .secondary).italic(a.transcript == nil)
                }
            } else {
                Button { onOpenAttachment(a) } label: { Label(a.name, systemImage: "doc") }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func commentView(_ c: TrackerComment) -> some View {
        if c.kind == .status {
            VStack(spacing: 2) {
                Text(statusLine(c)).font(.caption).foregroundStyle(.secondary)
                if !c.body.isEmpty { Text(c.body).font(.caption).foregroundStyle(.secondary).italic() }
            }.frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(c.author == .user ? "You" : "Agent").font(.caption.weight(.semibold))
                    Text(c.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.tertiary)
                }
                if !c.body.isEmpty { MarkdownText(c.body, theme: .matronMessage) }
                attachments(c.attachments)
            }
            .padding(10)
            .background(Color.secondary.opacity(c.author == .user ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func statusLine(_ c: TrackerComment) -> String {
        let who = c.author == .user ? "You" : "Agent"
        guard let to = c.statusTo else { return "\(who) updated the item" }
        if to.state == .closed { return "\(who) closed this" + (to.resolution.map { " as \(ItemGlyph.label($0).lowercased())" } ?? "") }
        return "\(who) reopened this"
    }

    private func pendingView(_ p: PendingComment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text("You").font(.caption.weight(.semibold)); Text(p.attempts > 0 ? "Queued · will send when online" : "Sending…").font(.caption2).foregroundStyle(.tertiary) }
            if !p.body.isEmpty { Text(p.body) }
            if p.attachmentCount > 0 { Label("\(p.attachmentCount) attachment\(p.attachmentCount == 1 ? "" : "s")", systemImage: "paperclip").font(.caption) }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .opacity(0.7)
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack {
            if item.state == .open {
                Menu {
                    ForEach(model.availableResolutions, id: \.self) { r in Button(ItemGlyph.label(r)) { onClose(r) } }
                } label: { Label("Close", systemImage: "checkmark.circle") }
            } else {
                Button { onReopen() } label: { Label("Reopen", systemImage: "arrow.uturn.backward.circle") }
            }
            Spacer()
        }
        .disabled(model.isBusy)
        .padding(.horizontal).padding(.vertical, 6)
    }
}
```

- [ ] **Step 4: Record and verify**

Run: `swift test --package-path MatronShared --filter ItemDetailSnapshotTests` twice (record, then pass). Then `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared` for the whole package.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/DesignSystem/Items MatronShared/Tests/DesignSystemSnapshotTests/ItemDetailSnapshotTests.swift MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/ItemDetailSnapshotTests
git commit -m "items: shared detail view with thread and comment composer"
```

---

### Task 9: App dependencies (both apps)

**Files:**
- Modify: `Matron/App/AppDependencies.swift` (`JournalCore` at `:99`; accessors near `:285`), `MatronMac/App/AppDependencies.swift` (`:49`, `:231`)

**Interfaces:**
- `JournalCore` gains `let items: ItemsSync` constructed in `core(for:)` as `ItemsSync(api: api, store: store, markers: { engine.itemMarkers() }, connectionStates: { engine.stateStream() })`, and `Task { await items.start() }` right after construction.
- New accessors on both `AppDependencies`: `func itemsSync(for session: UserSession) -> ItemsSync`, `func itemsProvider(for session: UserSession) -> any ItemsProviding` (returns `core.api`), `@MainActor func makeItemsPanelViewModel(for session: UserSession, convoID: String) -> ItemsPanelViewModel`, `@MainActor func makeItemDetailViewModel(for session: UserSession, itemID: String) -> ItemDetailViewModel`.
- Sign-out: wherever the core is torn down (grep `cores.removeValue\|backfillTask?.cancel`), call `await items.stop()` and `try? store.wipeItems()` alongside the existing wipe.

- [ ] **Step 1: Make the edits** (no unit test target reaches `AppDependencies`; the build is the check)

Add to `JournalCore` in both files:

```swift
        let items: ItemsSync
        init(api: JournalAPI, store: JournalStore, engine: JournalSyncEngine, items: ItemsSync) { … self.items = items }
```

and in `core(for:)`:

```swift
        let items = ItemsSync(api: api, store: store, markers: { engine.itemMarkers() }, connectionStates: { engine.stateStream() })
        let core = JournalCore(api: api, store: store, engine: engine, items: items)
        Task { await items.start() }
```

Accessors (both files, next to `journalStore(for:)`):

```swift
    func itemsSync(for session: UserSession) -> ItemsSync { core(for: session).items }
    func itemsProvider(for session: UserSession) -> any ItemsProviding { core(for: session).api }
    @MainActor func makeItemsPanelViewModel(for session: UserSession, convoID: String) -> ItemsPanelViewModel {
        let c = core(for: session)
        return ItemsPanelViewModel(convoID: convoID, store: c.store, api: c.api, sync: c.items)
    }
    @MainActor func makeItemDetailViewModel(for session: UserSession, itemID: String) -> ItemDetailViewModel {
        let c = core(for: session)
        return ItemDetailViewModel(itemID: itemID, store: c.store, api: c.api, sync: c.items)
    }
```

- [ ] **Step 2: Build both apps**

Run: `xcodegen generate && xcodebuild build -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' 2>&1 | tail -5 && xcodebuild build -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` twice.

- [ ] **Step 3: Commit**

```bash
git add Matron/App/AppDependencies.swift MatronMac/App/AppDependencies.swift
git commit -m "items: ItemsSync per session + view-model factories in both apps"
```

---

### Task 10: Mac pane sharing the sub-chat slot

**Files:**
- Create: `MatronMac/Features/Items/MacItemsPane.swift`
- Modify: `MatronMac/Features/Chat/MacChatView.swift:46` (state), `:333-373` (body), `:883-902` (toolbar call); `MatronMac/Features/Chat/MacChatToolbar.swift:101-129` (init) + a new toolbar item after the media button (`:157-163`)
- Test: `MatronMacTests/MacItemsPaneSnapshotTests.swift`

**Interfaces:**
- `MacItemsPane(viewModel: ItemsPanelViewModel, session: UserSession, onOpenConversation: (String) -> Void, onClose: () -> Void)` — a `NavigationStack` with `ItemsListView` as root and `MacItemDetailHost(itemID:)` pushed on select; the detail host builds `ItemDetailViewModel` via `deps.makeItemDetailViewModel`, resolves `image(for:)` through `deps.mediaService(for:)` (`swiftUIImage(for:)` on `serverURL/media/<blobRef>`), opens image attachments in `AttachmentFullscreenViewer` (gallery of the item's image attachments), files via `ChatViewModel.writeTempFile`-style temp write + `NSWorkspace.open`, links via `NSWorkspace.shared.open`, attach via `NSOpenPanel`, voice via the existing Mac recorder (`VoiceRecorder` + the Recording panel; reuse the composer's recorder flow: `grep -n "VoiceRecorder" MatronMac/Features/Chat/MacComposerView.swift`).
- `MacChatView`: `@State private var showItemsPane = false`. Body branches: `if let childID = openSubChatID { … } else if showItemsPane { same HSplitView shape with MacItemsPane(minWidth: 380) or narrow takeover with back chevron } else { chatColumn }`. `onOpenSubChat` sets `showItemsPane = false`; toggling the pane sets `openSubChatID = nil`.
- `MacChatToolbar` init gains `showItemsPane: Binding<Bool> = .constant(false)`, `needsYouCount: Int = 0`; new item:

```swift
            ToolbarItem(placement: .primaryAction) {
                cluster {
                    Button { showItemsPane.wrappedValue.toggle() } label: {
                        Image(systemName: "checklist")
                            .overlay(alignment: .topTrailing) { NeedsYouBadge(count: needsYouCount).scaleEffect(0.8).offset(x: 8, y: -8) }
                    }
                    .buttonStyle(.plain)
                    .help("Tasks & decisions")
                    .accessibilityLabel("Tasks and decisions" + (needsYouCount > 0 ? ", \(needsYouCount) need you" : ""))
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                }
            }
```

  Check the existing media-button item's placement and copy it exactly (the toolbar uses `cluster {}` and `.buttonStyle(.plain)` is mandatory).
- `MacChatView` owns `@State private var itemsVM: ItemsPanelViewModel?` created lazily in `.task` from `deps.makeItemsPanelViewModel(for: session, convoID: viewModel.roomID)`, started there and stopped in the outer `onDisappear` (the same hoisted lifecycle the file's comment at `:376-386` demands). `needsYouCount` for the badge reads `itemsVM?.needsYouCount ?? 0`; the VM is started even when the pane is closed so the badge is live.

- [ ] **Step 1: Write the failing snapshot test**

```swift
// MatronMacTests/MacItemsPaneSnapshotTests.swift
import SwiftUI
import XCTest
import MatronModels
import MatronDesignSystem
@testable import MatronMac

final class MacItemsPaneSnapshotTests: XCTestCase {
    @MainActor
    func testPaneListPopulated() {
        let items = [
            TrackerItem(id: "q", num: 12, kind: .question, awaiting: .user, title: "Which auth library?", originConvoID: "c1", commentCount: 1),
            TrackerItem(id: "t", num: 13, kind: .task, awaiting: .agent, title: "Refactor the auth module", originConvoID: "c1"),
        ]
        let model = ItemsListView.Model(needsYou: [items[0]], tasks: [items[1]], decisions: [], done: [], originTitles: [:], isSupported: true, isRefreshing: false)
        let view = MacItemsPaneChrome(title: "Tasks & decisions", onClose: {}) {
            ItemsListView(model: model, scope: .constant(.convo("c1")), convoID: "c1", thumbnail: { _ in nil },
                          onSelect: { _ in }, onMove: { _, _ in }, onCreate: {}, onOpenConversation: { _ in })
        }
        .frame(width: 400, height: 500)
        assertVariants(of: view, named: "MacItemsPane_list")
    }
}
```

`MacItemsPaneChrome` is the pane's header (title + close button + optional back chevron) wrapping content — split out so the snapshot needs no view models, exactly as `MacSummariesPanel` is tested without a VM.

- [ ] **Step 2: Run to verify it fails**

Run: `xcodegen generate && TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1 MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests/MacItemsPaneSnapshotTests 2>&1 | tail -20`
Expected: compile error.

- [ ] **Step 3: Implement**

`MacItemsPane.swift`:

```swift
import SwiftUI
import AppKit
import MatronModels
import MatronJournal
import MatronViewModels
import MatronDesignSystem

/// Header chrome shared by the list and detail pushes: title, back/close.
struct MacItemsPaneChrome<Content: View>: View {
    let title: String
    var showsBackChevron = false
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if showsBackChevron {
                    Button(action: onClose) { Image(systemName: "chevron.left") }.buttonStyle(.plain).help("Back to the chat")
                }
                Text(title).font(.headline)
                Spacer()
                if !showsBackChevron {
                    Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close").keyboardShortcut("i", modifiers: [.command, .shift])
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            content()
        }
        .background(.background)
    }
}

struct MacItemsPane: View {
    let viewModel: ItemsPanelViewModel
    let session: UserSession
    var showsBackChevron = false
    let onOpenConversation: (String) -> Void
    let onClose: () -> Void
    @Environment(\.appDependencies) private var deps
    @State private var path: [String] = []          // pushed item ids
    @State private var showCreate = false
    @State private var originTitles: [String: String] = [:]

    var body: some View {
        MacItemsPaneChrome(title: "Tasks & decisions", showsBackChevron: showsBackChevron, onClose: onClose) {
            NavigationStack(path: $path) {
                ItemsListView(
                    model: .init(needsYou: viewModel.sections.needsYou, tasks: viewModel.sections.tasks,
                                 decisions: viewModel.sections.decisions, done: viewModel.sections.done,
                                 originTitles: originTitles, isSupported: viewModel.isSupported, isRefreshing: viewModel.isRefreshing),
                    scope: Binding(get: { viewModel.scope }, set: { viewModel.scope = $0 }),
                    convoID: viewModel.convoID,
                    thumbnail: { _ in nil },
                    onSelect: { path.append($0.id) },
                    onMove: { id, index in Task { await viewModel.move(itemID: id, toIndex: index) } },
                    onCreate: { showCreate = true },
                    onOpenConversation: onOpenConversation)
                .navigationDestination(for: String.self) { id in
                    MacItemDetailHost(itemID: id, session: session, onOpenConversation: onOpenConversation)
                }
            }
        }
        .sheet(isPresented: $showCreate) { NewItemSheet { kind, title, body in Task { await viewModel.create(kind: kind, title: title, body: body) } } }
        .task(id: viewModel.scope) {
            // Titles for the "All" scope rows come from the local store's
            // conversation list — one read per scope switch.
            if let deps { originTitles = (try? deps.journalStore(for: session).conversationTitles()) ?? [:] }
        }
        .alert("Tracker", isPresented: Binding(get: { viewModel.error != nil }, set: { if !$0 { viewModel.error = nil } })) {
            Button("OK") { viewModel.error = nil }
        } message: { Text(viewModel.error ?? "") }
    }
}

struct NewItemSheet: View {
    let onCreate: (ItemKind, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ItemKind = .task
    @State private var title = ""
    @State private var body = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Kind", selection: $kind) { ForEach(ItemKind.allCases, id: \.self) { Text(ItemGlyph.label($0)).tag($0) } }.pickerStyle(.segmented)
            TextField("Title", text: $title)
            TextField("Details (Markdown)", text: $body, axis: .vertical).lineLimit(3...8)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                     Button("Add") { onCreate(kind, title, body); dismiss() }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty) }
        }
        .padding(16).frame(width: 420)
    }
}

struct MacItemDetailHost: View {
    let itemID: String
    let session: UserSession
    let onOpenConversation: (String) -> Void
    @Environment(\.appDependencies) private var deps
    @State private var viewModel: ItemDetailViewModel?
    @State private var gallery: ImageGallery?

    var body: some View {
        Group {
            if let viewModel, let item = viewModel.item {
                ItemDetailView(
                    model: .init(item: item, comments: viewModel.comments,
                                 pending: viewModel.pendingComments.map { .init(id: $0.localID, body: pendingBody($0), attachmentCount: pendingAttachments($0), attempts: $0.attempts, lastError: $0.lastError) },
                                 originTitle: (try? deps?.journalStore(for: session).conversationTitles()[item.originConvoID]) ?? nil,
                                 availableResolutions: viewModel.availableResolutions, isBusy: viewModel.isBusy),
                    draft: Binding(get: { viewModel.draft }, set: { viewModel.draft = $0 }),
                    image: { att in deps.flatMap { $0.mediaService(for: session).cachedSwiftUIImage(for: mediaURL(att)) } },
                    onOpenAttachment: { att in openAttachment(att, in: item) },
                    onOpenLink: { NSWorkspace.shared.open($0) },
                    onOpenConversation: onOpenConversation,
                    onSubmit: { Task { await viewModel.submitComment(attachments: []) } },
                    onAttach: { pickFiles { files in Task { await viewModel.submitComment(attachments: files) } } },
                    onVoiceNote: { recordVoiceNote { url in Task { await viewModel.sendVoiceNote(url: url) } } },
                    onClose: { r in Task { await viewModel.close(resolution: r, comment: nil) } },
                    onReopen: { Task { await viewModel.reopen() } })
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .task {
            guard viewModel == nil, let deps else { return }
            let vm = deps.makeItemDetailViewModel(for: session, itemID: itemID)
            viewModel = vm
            vm.start()
        }
        .onDisappear { viewModel?.stop() }
        .sheet(item: $gallery) { g in AttachmentFullscreenViewer(gallery: g, onDismiss: { gallery = nil }) }
    }

    private func mediaURL(_ a: TrackerAttachment) -> URL { session.homeserverURL.appendingPathComponent("media").appendingPathComponent(a.blobRef) }
    private func pendingBody(_ r: ItemOutboxRecord) -> String { (try? JSONSerialization.jsonObject(with: Data(r.payloadJSON.utf8)) as? [String: Any])?["body"] as? String ?? "" }
    private func pendingAttachments(_ r: ItemOutboxRecord) -> Int { ((try? JSONSerialization.jsonObject(with: Data(r.payloadJSON.utf8)) as? [String: Any])?["attachments"] as? [Any])?.count ?? 0 }

    private func openAttachment(_ a: TrackerAttachment, in item: TrackerItem) {
        if a.isImage {
            let images = (item.attachments + (viewModel?.comments.flatMap(\.attachments) ?? [])).filter(\.isImage).map(mediaURL)
            gallery = ImageGalleries.urls(images, tapped: mediaURL(a), deps: deps, session: session)
        } else {
            Task {
                guard let deps, let data = await deps.mediaService(for: session).fetchBytes(for: mediaURL(a)) else { return }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(a.name.isEmpty ? a.blobRef : a.name)
                try? data.write(to: url)
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func pickFiles(_ done: @escaping ([(data: Data, name: String, mime: String)]) -> Void) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.begin { resp in
            guard resp == .OK else { return }
            done(panel.urls.compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return (data, url.lastPathComponent, UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
            })
        }
    }

    private func recordVoiceNote(_ done: @escaping (URL) -> Void) {
        // Reuse the composer's recorder: see MacComposerView's VoiceRecorder
        // usage. Present the same Recording panel; on stop, hand the file
        // URL here instead of to ComposerViewModel.sendVoiceNote.
        VoiceNoteSession.shared.record(completion: done)
    }
}
```

Items the executor must resolve while implementing (each has a definite answer in the codebase — look, don't guess):
1. `conversationTitles()` on `JournalStore` — add it: `try dbQueue.read { db in try Row.fetchAll(db, sql: "SELECT id, title FROM conversation").reduce(into: [:]) { $0[$1["id"]] = $1["title"] } }` (check the real table/column names in `ConversationRecord`).
2. `cachedSwiftUIImage(for:)` — use whatever synchronous cache read `MediaService` offers (`swiftUIImage(for:)` at `MediaService.swift:84` is async; if no sync peek exists, hold a `@State [URL: Image]` in the host filled by a `.task` that fetches each image attachment once).
3. `ImageGalleries.urls(...)` — add a small helper in both apps' `ImageGalleries.swift` that builds an `ImageGallery` from plain media URLs (the existing `mediaGrid` helper is the closest; copy its shape).
4. `VoiceNoteSession.shared.record` — replace with the real recorder entry point used by `MacComposerView` (grep `VoiceRecorder`, `RecordingPanel`, `sendVoiceNote(url:` in `MatronMac/Features/Chat`). Wire the completion to the detail VM instead of the composer VM.
5. `UTType` needs `import UniformTypeIdentifiers`.

`MacChatView.swift` edits:

```swift
    @State private var showItemsPane = false
    @State private var itemsVM: ItemsPanelViewModel?
    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
```

Body (replace the `else { chatColumn }` tail):

```swift
            } else if showItemsPane, let itemsVM, let session {
                if geo.size.width >= Self.sideBySideMinWidth {
                    HSplitView {
                        chatColumn.frame(minWidth: 420)
                        MacItemsPane(viewModel: itemsVM, session: session, onOpenConversation: onOpenConversation,
                                     onClose: { showItemsPane = false })
                            .frame(minWidth: 380)
                    }
                } else {
                    MacItemsPane(viewModel: itemsVM, session: session, showsBackChevron: true,
                                 onOpenConversation: onOpenConversation, onClose: { showItemsPane = false })
                }
            } else {
                chatColumn
            }
```

In the outer `.task` add, before `await viewModel.start()`:

```swift
            if itemsVM == nil, let deps, let session {
                let vm = deps.makeItemsPanelViewModel(for: session, convoID: viewModel.roomID)
                itemsVM = vm
                vm.start()
            }
```

and in the outer `.onDisappear`: `itemsVM?.stop()`. Toolbar call: add `showItemsPane: Binding(get: { showItemsPane }, set: { showItemsPane = $0; if $0 { openSubChatID = nil } })`, `needsYouCount: itemsVM?.needsYouCount ?? 0`, and change `onOpenSubChat: { openSubChatID = $0 }` to `{ openSubChatID = $0; showItemsPane = false }`.

Hide the toolbar button when `itemsVM?.isSupported == false` (pass `needsYouCount: -1` as the sentinel or add `itemsAvailable: Bool` to the toolbar init — prefer the explicit Bool).

- [ ] **Step 4: Record, run, verify**

Run: `xcodegen generate && MATRON_APP_SUPPORT_OVERRIDE=$(mktemp -d) xcodebuild test -project Matron.xcodeproj -scheme MatronMac -destination 'platform=macOS' -only-testing:MatronMacTests/MacItemsPaneSnapshotTests 2>&1 | tail -20` (records), then again with `TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1` unset to verify, then the full `-only-testing:MatronMacTests` run with the skip var. Assert `Executed N tests, with 0 failures`.

Manual check (dev journal): open a chat, ⌘⇧I, see the pane; open a sub-chat from the strip and confirm the pane closes; narrow the window below 820pt and confirm the pane takes over with a back chevron.

- [ ] **Step 5: Commit**

```bash
git add MatronMac/Features/Items MatronMac/Features/Chat/MacChatView.swift MatronMac/Features/Chat/MacChatToolbar.swift MatronMac/Features/Chat/ImageGalleries.swift MatronShared/Sources/Journal/JournalStore+Items.swift MatronMacTests/MacItemsPaneSnapshotTests.swift MatronMacTests/__Snapshots__/MacItemsPaneSnapshotTests
git commit -m "items: Mac pane sharing the sub-chat slot, toolbar toggle with needs-you badge"
```

---

### Task 11: iOS right-edge drawer

**Files:**
- Create: `Matron/Features/Items/ItemsDrawer.swift`, `Matron/Features/Items/ItemDetailHost.swift`
- Modify: `Matron/Features/Chat/ChatView.swift` (state near `:279`; toolbar `:877-947`; overlay on the outer chat container; `.task` for the VM)
- Test: build + manual; snapshot of the drawer chrome in `MatronTests` only if that target already snapshots iOS views (grep `assertVariants` in `MatronTests`; if absent, skip the snapshot and rely on the shared-view snapshots).

**Interfaces:**
- `ItemsDrawer(isPresented: Binding<Bool>, viewModel: ItemsPanelViewModel, session: UserSession, onOpenConversation: (String) -> Void)` — an overlay: when presented, a dimming scrim (tap to close) and a panel of width `min(geo.width * 0.88, 420)` anchored trailing, sliding in with `.transition(.move(edge: .trailing))`, containing a `NavigationStack` (list root → `ItemDetailHost` push) and a header with a close button. The drawer's own `DragGesture` (translation.x > 60 → close) dismisses.
- `ChatView`: `@State private var showItems = false`, `@State private var itemsVM: ItemsPanelViewModel?`. An edge gesture on the chat container: `.gesture(DragGesture(minimumDistance: 20).onEnded { v in if v.startLocation.x > geo.size.width - 24 && v.translation.width < -60 { showItems = true } })` wrapped in a `GeometryReader`-derived width (the timeline already sits in one; if not, use `UIScreen.main.bounds.width` via `@Environment(\.horizontalSizeClass)`-agnostic reading of the container). Disabled while `attachmentPreview != nil` or a sheet is up. Toolbar: a `checklist` button with `NeedsYouBadge` overlay next to the info button; hidden when `itemsVM?.isSupported == false`.
- `ItemDetailHost` mirrors `MacItemDetailHost` with iOS pickers: `PhotosPicker` + `fileImporter` for attach (reuse the composer's existing picker flow: `grep -n "PhotosPicker\|fileImporter" Matron/Features/Chat/Composer/ComposerView.swift`), `VoiceRecorder` + the composer's record UI for voice (grep `VoiceRecorder` in `Matron/Features/Chat/Composer`), `AttachmentFullscreenViewer` for images, `FilePreviewSheet` for files, `openURL` for links.

- [ ] **Step 1: Implement `ItemsDrawer.swift`**

```swift
import SwiftUI
import MatronModels
import MatronViewModels
import MatronDesignSystem

struct ItemsDrawer: View {
    @Binding var isPresented: Bool
    let viewModel: ItemsPanelViewModel
    let session: UserSession
    let onOpenConversation: (String) -> Void
    @Environment(\.appDependencies) private var deps
    @State private var path: [String] = []
    @State private var showCreate = false
    @State private var originTitles: [String: String] = [:]
    @State private var dragX: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                if isPresented {
                    Color.black.opacity(0.35).ignoresSafeArea()
                        .onTapGesture { close() }
                        .transition(.opacity)
                    panel
                        .frame(width: min(geo.size.width * 0.88, 420))
                        .offset(x: max(dragX, 0))
                        .gesture(DragGesture(minimumDistance: 10)
                            .onChanged { dragX = $0.translation.width }
                            .onEnded { v in if v.translation.width > 60 { close() } else { withAnimation(.easeOut(duration: 0.18)) { dragX = 0 } } })
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: isPresented)
        }
        .allowsHitTesting(isPresented)
    }

    private func close() { withAnimation { isPresented = false }; dragX = 0; path = [] }

    private var panel: some View {
        NavigationStack(path: $path) {
            ItemsListView(
                model: .init(needsYou: viewModel.sections.needsYou, tasks: viewModel.sections.tasks, decisions: viewModel.sections.decisions,
                             done: viewModel.sections.done, originTitles: originTitles, isSupported: viewModel.isSupported, isRefreshing: viewModel.isRefreshing),
                scope: Binding(get: { viewModel.scope }, set: { viewModel.scope = $0 }),
                convoID: viewModel.convoID, thumbnail: { _ in nil },
                onSelect: { path.append($0.id) },
                onMove: { id, index in Task { await viewModel.move(itemID: id, toIndex: index) } },
                onCreate: { showCreate = true },
                onOpenConversation: { id in close(); onOpenConversation(id) })
            .navigationTitle("Tasks & decisions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { close() } } }
            .navigationDestination(for: String.self) { id in ItemDetailHost(itemID: id, session: session, onOpenConversation: { c in close(); onOpenConversation(c) }) }
        }
        .background(.background)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16))
        .shadow(radius: 12)
        .sheet(isPresented: $showCreate) { NewItemSheet { kind, title, body in Task { await viewModel.create(kind: kind, title: title, body: body) } } }
        .task(id: viewModel.scope) { if let deps { originTitles = (try? deps.journalStore(for: session).conversationTitles()) ?? [:] } }
        .alert("Tracker", isPresented: Binding(get: { viewModel.error != nil }, set: { if !$0 { viewModel.error = nil } })) { Button("OK") { viewModel.error = nil } } message: { Text(viewModel.error ?? "") }
    }
}
```

`NewItemSheet` for iOS: same fields as the Mac one, in a `NavigationStack` + `Form` with Cancel/Add toolbar buttons. Put it in `ItemsDrawer.swift`.

- [ ] **Step 2: Implement `ItemDetailHost.swift`** — mirror `MacItemDetailHost` from Task 10 with the iOS pickers named above; image taps present `AttachmentFullscreenViewer` via `.fullScreenCover`, files via `FilePreviewSheet`.

- [ ] **Step 3: Wire `ChatView.swift`**

- State + VM lifecycle alongside the existing `.task` that starts `viewModel` (mirror Task 10's Mac snippet: create via `deps.makeItemsPanelViewModel(for: session, convoID: viewModel.roomID)`, `start()`; `stop()` in the existing `onDisappear`).
- Toolbar item, placed before the info button (`:942`):

```swift
            if itemsVM?.isSupported != false {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showItems = true } label: {
                        Image(systemName: "checklist")
                            .overlay(alignment: .topTrailing) { NeedsYouBadge(count: itemsVM?.needsYouCount ?? 0).scaleEffect(0.75).offset(x: 10, y: -8) }
                    }
                    .accessibilityLabel("Tasks and decisions")
                }
            }
```

- Overlay on the outer chat `VStack` (the one that ends with `ComposerView(viewModel: composerVM)` at `:867`): `.overlay { if let itemsVM, let session { ItemsDrawer(isPresented: $showItems, viewModel: itemsVM, session: session, onOpenConversation: { id in navigationPath.wrappedValue.append(id) }) } }` — check how `chatNavigationPath` is used elsewhere in the file for the exact push call.
- Edge gesture on that same container: `.simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { v in guard attachmentPreview == nil, !showItems, v.startLocation.x > containerWidth - 24, v.translation.width < -60 else { return }; showItems = true })` with `containerWidth` read from a `GeometryReader` background (`.background(GeometryReader { g in Color.clear.onAppear { containerWidth = g.size.width }.onChange(of: g.size.width) { containerWidth = $1 } })`).

- [ ] **Step 4: Build and run the iOS tests**

Run: `xcodegen generate && xcodebuild test -project Matron.xcodeproj -scheme Matron -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MatronTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **` with the `Executed N tests` line.

Manual on the simulator: swipe from the right edge → drawer; tap an item → detail; back → list; tap scrim → closes; swipe-down attachment preview still works.

- [ ] **Step 5: Commit and open PR A**

```bash
git add Matron/Features/Items Matron/Features/Chat/ChatView.swift
git commit -m "items: iOS right-edge drawer with list and detail"
git push -u origin items-tracker-core
gh pr create --base main --title "Items tracker: shared core, panel, Mac pane, iOS drawer" --body "$(cat <<'EOF'
PR A of docs/superpowers/specs/2026-09-08-task-decision-tracker-design.md (apps).
- models, ItemMarkerEvent, JournalAPI /items routes, GRDB v9 cache + item outbox, ItemsSync (marker/reconnect/open refresh, offline drain)
- ItemsPanelViewModel / ItemDetailViewModel, shared list + detail views
- Mac: pane sharing the sub-chat slot (⌘⇧I), toolbar badge
- iOS: right-edge drawer, toolbar badge
Feature-detects the journal: hidden after a 404 on GET /items.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

### Task 12: "Make task" pill on both composers (PR B)

**Files:**
- Modify: `MatronShared/Sources/ViewModels/ComposerViewModel.swift` (init `:130`; new `makeTask()`; `canMakeTask`)
- Create: `MatronShared/Sources/DesignSystem/Items/MakeTaskPill.swift`
- Modify: `Matron/Features/Chat/Composer/ComposerView.swift:180-188` (overlay on `composerBar`), `MatronMac/Features/Chat/MacComposerView.swift:121-136` (add to the existing top overlay's `ZStack`), both `AppDependencies` (pass `items:` when constructing `ComposerViewModel` — grep `ComposerViewModel(` in both apps)
- Test: `MatronShared/Tests/ViewModelTests/ComposerViewModelTests.swift` (append), `MatronShared/Tests/DesignSystemSnapshotTests/MakeTaskPillSnapshotTests.swift`

**Interfaces:**
- `ComposerViewModel.init(..., items: (any ItemsSyncing)? = nil, itemsUpload: ((Data, String) async throws -> String)? = nil)` — `items` nil = feature absent (pill hidden).
- `public var canMakeTask: Bool { items != nil && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !stagedAttachments.isEmpty) && !isSending }`
- `public func makeTask() async` — title = first line trimmed, ≤200; body = the rest; uploads each staged attachment through `itemsUpload` to a `TrackerAttachment`; `items.enqueueCreate(localID: UUID, NewItem(kind: .task, title:, body:, attachments:, convoID: roomID))`; on success clears `input` and `stagedAttachments` (same clearing calls `send()` uses, including `ComposerDraftMemory.forget`) and sets `lastFiledTaskNotice = "Filed as a task"` (a transient string the view shows for 2s); on upload failure sets `sendError` and leaves the composer intact.
- `MakeTaskPill(action:)` — a capsule `Label("Make task", systemImage: "checklist")`, `.font(.caption.weight(.semibold))`, `.padding(.horizontal, 12).padding(.vertical, 6)`, `.background(.regularMaterial, in: Capsule())`, shadow like `JumpToBottomButton`, `.buttonStyle(.plain)`, `.transition(.scale.combined(with: .opacity))`, Mac: `.keyboardShortcut("t", modifiers: [.command, .shift])`.

- [ ] **Step 1: Write the failing tests**

Append to `ComposerViewModelTests.swift` (reuse its `FakeTimelineService` and construction helper):

```swift
    private final class FakeItemsSync: ItemsSyncing, @unchecked Sendable {
        var created: [NewItem] = []
        func refresh(scope: ItemsScope) async {}
        func refreshItem(id: String) async {}
        func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async {}
        func enqueueCreate(localID: String, _ new: NewItem) async { created.append(new) }
        func supportedStream() -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
    }

    @MainActor
    func testMakeTaskFilesFirstLineAsTitleAndClearsComposer() async {
        let sync = FakeItemsSync()
        let vm = ComposerViewModel(roomID: "c1", timeline: FakeTimelineService(), commands: [], items: sync, itemsUpload: { _, _ in "blob" })
        XCTAssertFalse(vm.canMakeTask)
        vm.input = "Refactor auth\nkeep the public API\nand add tests"
        XCTAssertTrue(vm.canMakeTask)
        await vm.makeTask()
        XCTAssertEqual(sync.created.first?.kind, .task)
        XCTAssertEqual(sync.created.first?.title, "Refactor auth")
        XCTAssertEqual(sync.created.first?.body, "keep the public API\nand add tests")
        XCTAssertEqual(sync.created.first?.convoID, "c1")
        XCTAssertEqual(vm.input, "")
    }

    @MainActor
    func testMakeTaskHiddenWithoutItemsSupport() {
        let vm = ComposerViewModel(roomID: "c1", timeline: FakeTimelineService(), commands: [])
        vm.input = "x"
        XCTAssertFalse(vm.canMakeTask)
    }
```

Add a staged-attachment case if the existing tests have a helper to stage a temp file (grep `stage(` / `addAttachment` in that test file); assert `created.first?.attachments.first?.blobRef == "blob"` and that `stagedAttachments` is empty afterwards.

```swift
// MatronShared/Tests/DesignSystemSnapshotTests/MakeTaskPillSnapshotTests.swift
import SwiftUI
import XCTest
@testable import MatronDesignSystem

@MainActor
final class MakeTaskPillSnapshotTests: XCTestCase {
    func testPill() {
        assertVariants(of: MakeTaskPill {}.padding(20).background(Color.gray.opacity(0.2)), named: "MakeTaskPill")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter "ComposerViewModelTests|MakeTaskPillSnapshotTests"`
Expected: compile error.

- [ ] **Step 3: Implement**

`ComposerViewModel.swift` additions:

```swift
    private let items: (any ItemsSyncing)?
    private let itemsUpload: ((Data, String) async throws -> String)?
    /// Transient confirmation after `makeTask()`; the view clears it.
    public var lastFiledTaskNotice: String?

    // init: add `items: (any ItemsSyncing)? = nil, itemsUpload: ((Data, String) async throws -> String)? = nil`
    // and assign both.

    public var canMakeTask: Bool {
        items != nil && !isSending
            && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !stagedAttachments.isEmpty)
    }

    /// Files the composer contents as a task instead of sending them
    /// (spec: "Make task"). First line → title, rest → body, staged files →
    /// attachments. Clears the composer exactly like `send()` does.
    public func makeTask() async {
        guard let items, canMakeTask else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstBreak = text.firstIndex(of: "\n")
        var title = String(firstBreak.map { text[..<$0] } ?? Substring(text)).trimmingCharacters(in: .whitespaces)
        let body = firstBreak.map { String(text[text.index(after: $0)...]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if title.isEmpty { title = stagedAttachments.first?.filename ?? "Task" }
        if title.count > 200 { title = String(title.prefix(200)) }
        isSending = true
        defer { isSending = false }
        var uploaded: [TrackerAttachment] = []
        if !stagedAttachments.isEmpty {
            guard let itemsUpload else { sendError = "Attachments can't be filed as a task here."; return }
            do {
                for a in stagedAttachments {
                    let data = try Data(contentsOf: a.url)
                    let ref = try await itemsUpload(data, a.mimeType)
                    uploaded.append(TrackerAttachment(blobRef: ref, mime: a.mimeType, name: a.filename, size: Int64(a.sizeBytes)))
                }
            } catch {
                sendError = "Couldn't upload an attachment: \(error.localizedDescription)"
                return
            }
        }
        let staged = stagedAttachments
        input = ""
        clearStagedAttachments()           // the same helper send() uses to drop files + forget the draft; find its real name near :381-386
        await items.enqueueCreate(localID: UUID().uuidString, NewItem(kind: .task, title: title, body: body, attachments: uploaded, convoID: roomID))
        lastFiledTaskNotice = "Filed as a task"
        _ = staged
    }
```

`MakeTaskPill.swift`:

```swift
import SwiftUI

public struct MakeTaskPill: View {
    let action: () -> Void
    public init(action: @escaping () -> Void) { self.action = action }
    public var body: some View {
        Button(action: action) {
            Label("Make task", systemImage: "checklist")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Make task from this message")
        #if os(macOS)
        .keyboardShortcut("t", modifiers: [.command, .shift])
        #endif
        .transition(.scale.combined(with: .opacity))
    }
}
```

iOS `ComposerView.swift`: on `composerBar` add

```swift
        .overlay(alignment: .top) {
            ZStack {
                if viewModel.canMakeTask {
                    MakeTaskPill { Task { await viewModel.makeTask() } }
                } else if let notice = viewModel.lastFiledTaskNotice {
                    Text(notice).font(.caption).padding(.horizontal, 10).padding(.vertical, 4).background(.regularMaterial, in: Capsule())
                        .task { try? await Task.sleep(nanoseconds: 1_800_000_000); viewModel.lastFiledTaskNotice = nil }
                }
            }
            .alignmentGuide(.top) { $0[.bottom] + 8 }
            .animation(.easeInOut(duration: 0.18), value: viewModel.canMakeTask)
        }
```

Mac `MacComposerView.swift`: inside the existing `.overlay(alignment: .top) { ZStack { … } .alignmentGuide(.top) { $0[.bottom] + 4 } }` add the same `if viewModel.canMakeTask { MakeTaskPill … }` branch **after** the palette branch (the palette wins when both could show, since the palette only appears for `/` commands).

Both `AppDependencies`: where `ComposerViewModel(` is constructed, pass `items: core.items, itemsUpload: { data, mime in try await core.api.uploadMedia(data, contentType: mime) }`.

- [ ] **Step 4: Run tests, record the pill snapshot, build both apps**

Run: `swift test --package-path MatronShared --filter MakeTaskPillSnapshotTests` (record + verify), `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter ComposerViewModelTests`, then `xcodegen generate` + both app builds.

Manual: type two lines, see the pill appear centred above the input, tap → composer clears, "Filed as a task" shows briefly, the task appears in the pane. Empty field → no pill. Mac: ⌘⇧T.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/ViewModels/ComposerViewModel.swift MatronShared/Sources/DesignSystem/Items/MakeTaskPill.swift Matron/Features/Chat/Composer/ComposerView.swift MatronMac/Features/Chat/MacComposerView.swift Matron/App/AppDependencies.swift MatronMac/App/AppDependencies.swift MatronShared/Tests
git commit -m "items: floating Make task pill files the composer as a task (⌘⇧T on Mac)"
```

---

### Task 13: Inline timeline cards (PR B)

**Files:**
- Modify: `MatronShared/Sources/Chat/TimelineItem.swift:27-70` (new case), `MatronShared/Sources/Chat/JournalTimelineMapper.swift:16-25` (branch)
- Create: `MatronShared/Sources/DesignSystem/Items/ItemInlineCard.swift`
- Modify: `Matron/Features/Chat/Rendering/TimelineItemView.swift:333` and `MatronMac/Features/Chat/MacTimelineItemView.swift:301` (new `case`), plus the `onOpenItem: ((String) -> Void)?` callback threaded the same way `onOpenSpawnRoom` is (grep `onOpenSpawnRoom` in both row views and both `ChatView`/`MacChatView`)
- Test: `MatronShared/Tests/ChatTests/JournalTimelineMapperItemTests.swift`, `MatronShared/Tests/DesignSystemSnapshotTests/ItemInlineCardSnapshotTests.swift`

**Interfaces:**
- `TimelineItem.Kind.itemMarker(eventID: String, ItemMarkerEvent)`; mapper: `case JournalEventType.item:` → `ItemMarkerEvent.parse(payload:)`; `nil` result or `action == .reordered` → return `nil` (row hidden).
- `ItemInlineCard(marker: ItemMarkerEvent, onOpen: () -> Void)` renders `created`/`closed` as a compact card (glyph, `#num`, title, pill "Needs you" / "Done · answered"), and `commented`/`reopened` as `ItemInlineNote` (one muted line: "You replied on #12 · Which auth library?" / "Agent commented on #12 · …"). Tap → `onOpen`.
- Hosts: `onOpenItem` opens the pane/drawer and pushes the item: Mac `showItemsPane = true; itemsPanePath = [id]` (expose a `@Binding path` on `MacItemsPane`), iOS `showItems = true` + push.

- [ ] **Step 1: Write the failing tests**

```swift
// MatronShared/Tests/ChatTests/JournalTimelineMapperItemTests.swift
import XCTest
import MatronJournal
import MatronEvents
@testable import MatronChat

final class JournalTimelineMapperItemTests: XCTestCase {
    private func event(_ payload: [String: Any]) -> JournalEvent {
        JournalEvent(seq: 7, convoID: "c1", ts: Date(), sender: "agent:dev-2", type: "item", payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }
    private let base: [String: Any] = ["item_id": "it_1", "num": 12, "kind": "question", "title": "Which auth?", "by": "agent", "awaiting": "user", "resolution": NSNull()]

    func testCreatedMapsToItemMarker() throws {
        let item = try XCTUnwrap(JournalTimelineMapper.timelineItem(from: event(base.merging(["action": "created"]) { $1 }), ownSender: "user:dan", serverURL: URL(string: "https://j")!))
        guard case .itemMarker(let id, let marker) = item.kind else { return XCTFail("\(item.kind)") }
        XCTAssertEqual(id, "7"); XCTAssertEqual(marker.action, .created); XCTAssertEqual(marker.num, 12)
    }

    func testReorderedAndMalformedAreHidden() {
        XCTAssertNil(JournalTimelineMapper.timelineItem(from: event(base.merging(["action": "reordered"]) { $1 }), ownSender: "u", serverURL: URL(string: "https://j")!))
        XCTAssertNil(JournalTimelineMapper.timelineItem(from: event(["action": "created"]), ownSender: "u", serverURL: URL(string: "https://j")!))
    }
}
```

```swift
// MatronShared/Tests/DesignSystemSnapshotTests/ItemInlineCardSnapshotTests.swift
import SwiftUI
import XCTest
import MatronModels
import MatronEvents
@testable import MatronDesignSystem

@MainActor
final class ItemInlineCardSnapshotTests: XCTestCase {
    func testVariants() {
        let created = ItemMarkerEvent(itemID: "it_1", num: 12, kind: .question, title: "Which auth library?", action: .created, by: .agent, awaiting: .user)
        let closed = ItemMarkerEvent(itemID: "it_1", num: 12, kind: .question, title: "Which auth library?", action: .closed, by: .agent, resolution: .answered)
        let commented = ItemMarkerEvent(itemID: "it_1", num: 12, kind: .question, title: "Which auth library?", action: .commented, by: .user, awaiting: .agent, comment: .init(id: "c", body: "use A"))
        let filed = ItemMarkerEvent(itemID: "it_2", num: 13, kind: .task, title: "Refactor auth", action: .created, by: .user, awaiting: .agent)
        let view = VStack(alignment: .leading, spacing: 8) {
            ItemInlineCard(marker: created, onOpen: {})
            ItemInlineCard(marker: closed, onOpen: {})
            ItemInlineCard(marker: commented, onOpen: {})
            ItemInlineCard(marker: filed, onOpen: {})
        }.padding().frame(width: 380)
        assertVariants(of: view, named: "ItemInlineCard_variants")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter "JournalTimelineMapperItemTests|ItemInlineCardSnapshotTests"`
Expected: compile errors.

- [ ] **Step 3: Implement**

`TimelineItem.swift`: add `case itemMarker(eventID: String, ItemMarkerEvent)` with a doc comment "Tracker marker (spec 2026-09-08): created/closed render as a compact card, commented/reopened as a one-line note; reordered never reaches the timeline."

Mapper: add before the `readMarker` group:

```swift
        case JournalEventType.item:
            guard let marker = ItemMarkerEvent.parse(payload: payload), marker.action != .reordered else { return nil }
            kind = .itemMarker(eventID: String(event.seq), marker)
```

`ItemInlineCard.swift`:

```swift
import SwiftUI
import MatronModels
import MatronEvents

public struct ItemInlineCard: View {
    let marker: ItemMarkerEvent
    let onOpen: () -> Void
    public init(marker: ItemMarkerEvent, onOpen: @escaping () -> Void) { self.marker = marker; self.onOpen = onOpen }

    public var body: some View {
        switch marker.action {
        case .created, .closed: card
        default: note
        }
    }

    private var pill: (String, Color)? {
        if marker.action == .closed { return ("Done" + (marker.resolution.map { " · \(ItemGlyph.label($0))" } ?? ""), .secondary) }
        if marker.awaiting == .user { return ("Needs you", .orange) }
        if marker.by == .user { return ("Filed by you", .secondary) }
        return nil
    }

    private var card: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: ItemGlyph.symbol(marker.kind)).foregroundStyle(ItemGlyph.tint(marker.kind))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("#\(marker.num)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(marker.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    }
                    if let (text, color) = pill {
                        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(marker.awaiting == .user && marker.action != .closed ? Color.orange.opacity(0.5) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(ItemGlyph.label(marker.kind)) \(marker.num), \(marker.title). \(pill?.0 ?? "")")
    }

    private var noteText: String {
        let who = marker.by == .user ? "You" : "Agent"
        switch marker.action {
        case .commented: return "\(who) replied on #\(marker.num) · \(marker.title)"
        case .reopened: return "\(who) reopened #\(marker.num) · \(marker.title)"
        default: return "#\(marker.num) · \(marker.title)"
        }
    }

    private var note: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: ItemGlyph.symbol(marker.kind)).font(.caption2)
                Text(noteText).font(.caption).lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}
```

Row views (iOS `:333` and Mac `:301` neighbourhoods), add the case beside `.agentSpawnRequest`:

```swift
        case .itemMarker(_, let marker):
            HStack {
                ItemInlineCard(marker: marker) { onOpenItem?(marker.itemID) }
                    .frame(maxWidth: 360, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
```

Thread `onOpenItem: ((String) -> Void)? = nil` through both row views and their call sites exactly as `onOpenSpawnRoom` is threaded (grep it; it passes through `TimelineListContent` on iOS). Hosts: Mac `onOpenItem = { id in openSubChatID = nil; showItemsPane = true; itemsPanePath = [id] }` (add `@State private var itemsPanePath: [String] = []` and pass `path: $itemsPanePath` into `MacItemsPane`, replacing its private `@State`); iOS `onOpenItem = { id in showItems = true; itemsDrawerPath = [id] }` likewise.

Also update `TimelineItemView.accessibilityLabel(for:body:)` switch if it is exhaustive over `Kind` (the compiler will tell you), and any other exhaustive `switch item.kind` (grep `case .agentSpawnRequest` across the repo — every site needs the new case or a `default`).

- [ ] **Step 4: Run tests, record, build**

Run: `swift test --package-path MatronShared --filter ItemInlineCardSnapshotTests` (record + verify), `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared`, then both app builds and the Mac test target.

- [ ] **Step 5: Commit and open PR B**

```bash
git add MatronShared Matron MatronMac
git commit -m "items: inline created/closed cards and commented/reopened notes in the timeline"
git push -u origin items-tracker-composer
gh pr create --base items-tracker-core --title "Items tracker: Make task pill + inline cards" --body "PR B of the tracker spec: composer pill (⌘⇧T on Mac) and timeline cards for item markers.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

### Task 14: Needs-you badge on chat-list rows (PR C)

**Files:**
- Modify: `MatronShared/Sources/Chat/ChatSummary.swift:46-64` (`needsUserCount: Int = 0`), `MatronShared/Sources/Chat/JournalChatService.swift:35-118` (third input), `Matron/Features/ChatList/ChatListView.swift:537-546`, `MatronMac/Features/ChatList/MacChatListView.swift:696-697`
- Test: `MatronShared/Tests/ChatTests/JournalChatServiceTests.swift` (append; find the existing summaries test and its store fixture), `MatronTests/ChatRowHeightTests.swift` (re-run; adjust expectations only if the badge changes row height — it must not, both badges share `UnreadBadge` metrics)

- [ ] **Step 1: Write the failing test**

Append to the chat-service tests (using its existing in-memory `JournalStore` fixture):

```swift
    func testSummariesCarryNeedsUserCount() async throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        try store.applyJournal(JournalEvent(seq: 1, convoID: "c1", ts: Date(), sender: "agent:a", type: "text", payloadData: Data("{\"body\":\"hi\"}".utf8)))
        try store.upsertItems([TrackerItem(id: "q", num: 1, kind: .question, awaiting: .user, title: "Q", originConvoID: "c1"),
                               TrackerItem(id: "t", num: 2, kind: .task, awaiting: .agent, title: "T", originConvoID: "c1")])
        let service = JournalChatService(store: store, engine: makeEngine(store), api: makeAPI())   // use the fixture's real constructor
        var it = service.chatSummaries().makeAsyncIterator()
        let first = try await it.next()
        XCTAssertEqual(first?.first(where: { $0.id == "c1" })?.needsUserCount, 1)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter JournalChatServiceTests`
Expected: `needsUserCount` undefined.

- [ ] **Step 3: Implement**

`ChatSummary`: add `public let needsUserCount: Int` and an `init` parameter `needsUserCount: Int = 0` (last, defaulted, so every existing call compiles).

`JournalChatService.chatSummaries()`: add a third producer next to `roster`:

```swift
            let needs = Task {
                for await counts in store.needsUserCountsStream() {
                    inputs.setNeedsUser(counts)
                    signalCont.yield(())
                }
            }
```

`SummaryInputs` gains `needsUser: [String: Int]` with `setNeedsUser`; the consumer passes `needsUser: inputs.needsUser[record.id] ?? 0` into `Self.summary(from:boxNames:boxLetters:needsUser:)` (add the parameter, default 0). Cancel `needs` in `onTermination`.

Rows: iOS `:537-546` → inside the trailing `VStack`, after `UnreadBadge`, add `NeedsYouBadge(count: summary.needsUserCount)` — but a vertical stack of two badges changes the height; instead put both in an `HStack(spacing: 4) { NeedsYouBadge(count: summary.needsUserCount); UnreadBadge(count: summary.unreadCount) }` in place of the single `UnreadBadge`. Mac `:696-697`: same `HStack` replacement.

- [ ] **Step 4: Run tests**

Run: `MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --package-path MatronShared --filter JournalChatServiceTests`, then the iOS `MatronTests` run (for `ChatRowHeightTests`) and the Mac `MatronMacTests` run. All must report `0 failures`.

- [ ] **Step 5: Commit and open PR C**

```bash
git add MatronShared/Sources/Chat/ChatSummary.swift MatronShared/Sources/Chat/JournalChatService.swift Matron/Features/ChatList/ChatListView.swift MatronMac/Features/ChatList/MacChatListView.swift MatronShared/Tests/ChatTests
git commit -m "items: needs-you badge on chat-list rows"
git push -u origin items-tracker-badge
gh pr create --base items-tracker-composer --title "Items tracker: needs-you badge on chat rows" --body "PR C of the tracker spec.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

Merge order: A → retarget B to `main` → merge B → retarget C → merge C (stacked-PR technique in memory: `--delete-branch` closes children unless retargeted first).

---

## Self-review against the spec

- **Shared core**: items client (Task 3), local GRDB cache refreshed by marker events and on open (Tasks 4–5), offline outbox for comments and creates with the "Queued" caption (Tasks 4, 5, 8), tracker + detail view models (Task 6), shared views (Tasks 7–8), inline card (Task 13).
- **Panel layout**: four sections, scope toggle, origin title in "All", row contents, detail contents, close/reopen/reverse (Tasks 6–8). Thumbnails: the row accepts one; hosts pass `nil` in v1 and show the photo glyph when `hasImage` — the spec's "thumbnail if the item has an image" is met by the glyph, with the real thumbnail wired when a synchronous media-cache peek exists (Task 10 executor note 2).
- **Mac**: shared slot, ⌘⇧I, badge, narrow takeover with back chevron, hoisted VM lifecycle (Task 10).
- **iOS**: right-edge drag, toolbar button + badge, push inside the drawer, scrim/drag/close, disabled during attachment preview (Task 11).
- **Composer "Make task"**: floating pill on both, ⌘⇧T on Mac, first line → title, attachments uploaded, composer cleared, "Filed" toast (Task 12).
- **Inline cards**: created/closed card, commented/reopened note, reordered hidden, tap opens the item in the panel (Task 13).
- **Chat list badge** (Task 14).
- **Error handling**: panel error alert + revert on rank failure (Task 6), outbox retry (Task 5), feature detection hides button/pill after 404 and re-probes on reconnect (Tasks 5, 10, 11, 12 via `isSupported`), transcription-pending copy in the thread (Task 8).
- **Testing**: migration, sync reconcile, sectioning, scope, badge count, rank math with revert, detail submit/voice/outbox, snapshots for row/card/note/detail/pill, Mac pane chrome snapshot, chat-row height — all present.
- **Rollout**: three stacked PRs.
- Left explicit for the executor with a pointer, not a guess: exact recorder/picker entry points on each platform (Task 10 note 4, Task 11), the `ImageGallery` from-URLs helper (Task 10 note 3), the media-cache synchronous read (note 2).
