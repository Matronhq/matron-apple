# Per-chat Media & Links Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-conversation "Media, Files and Links" browser sheet (WhatsApp-style) opened from the chat toolbar on Mac and iOS, reading the full local JournalStore history.

**Architecture:** Two new read-only JournalStore queries feed a `MediaBrowserViewModel` (MatronViewModels) that maps events through the existing `JournalTimelineMapper` payload contract and extracts links with `NSDataDetector`. A pure `MediaBrowserView` component in MatronDesignSystem (data + closures in, no VM import — DesignSystem cannot see MatronViewModels) renders three tabs; thin platform sheets in Matron/ and MatronMac/ glue VM → view and route taps into the existing preview/download paths.

**Tech Stack:** Swift 6 / SwiftUI, GRDB (store), swift-snapshot-testing (`assertVariants`), XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-08-13-media-links-browser-design.md`

## Global Constraints

- Worktree: `~/Dev/matron-apple-media-browser`, branch `feat/media-links-browser` (rebased on main `c2074b4`).
- After ANY file add/remove: run `xcodegen generate` before `xcodebuild` (project.yml globs).
- SPM suite: `cd MatronShared && swift test 2>&1 | tail -5` — assert the "Executed N tests" line exists and shows 0 failures (grep pipelines mask xcodebuild failures otherwise). Full suite currently ~1120 tests.
- Snapshot tests honor `MATRON_SKIP_SNAPSHOT_TESTS=1` / `TEST_RUNNER_MATRON_SKIP_SNAPSHOT_TESTS=1`; new snapshot tests use `assertVariants` (records on first run when no baseline exists, then verifies). Run twice: once to record, once to prove determinism. Do NOT re-record pre-existing drifted baselines (MessageBubbleSnapshotTests, MacSummariesPanelSnapshotTests, MacSearchViewSnapshotTests).
- NEVER run MatronMacTests without `TEST_RUNNER_MATRON_APP_SUPPORT_OVERRIDE` pointing at a scratch dir (test host once wiped the live journal store).
- Payload contract (already parsed by `JournalTimelineMapper.timelineItem`): `blob_ref` → `serverURL/media/<ref>`, `name` (never `filename`), `size`, `caption`, tombstone `expired: true` with null `blob_ref`.
- Links tab: ALL http(s) URLs from any sender (user messages included), deduplicated by absoluteString keeping the NEWEST occurrence, newest first (Dan, 2026-08-13).
- Strictly per-conversation — no sub-chat pooling (child convo ids carry the `:sub:` infix and their events sit under their own `convo_id`).

---

### Task 1: JournalStore browser queries

**Files:**
- Modify: `MatronShared/Sources/Journal/JournalStore.swift` (next to `events(convoID:)`, ~line 754)
- Test: `MatronShared/Tests/JournalTests/MediaBrowserQueryTests.swift` (new)

**Interfaces:**
- Consumes: existing `EventRecord`, `JournalEventType`, `dbQueue`.
- Produces (Task 3 relies on these exact signatures):
  - `public func attachmentEvents(convoID: String) throws -> [JournalEvent]`
  - `public func linkCandidateEvents(convoID: String) throws -> [JournalEvent]`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MatronJournal

/// Pins the two read-only queries behind the media & links browser: type
/// filtering, newest-first ordering, per-conversation isolation (sub-chats
/// excluded), and the LIKE '%http%' link prefilter.
final class MediaBrowserQueryTests: XCTestCase {
    private func makeStore() throws -> JournalStore {
        try JournalStore(databaseURL: nil, ownSender: "user:dan")
    }

    private func event(_ seq: Int64, convo: String = "c1", sender: String = "agent:dev-2",
                       type: String = "text", payload: [String: Any] = ["body": "hi"]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: Double(seq)),
                     sender: sender, type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    func testAttachmentEventsFiltersTypesAndOrdersNewestFirst() throws {
        let store = try makeStore()
        try store.insertHistory([
            event(1, type: "image", payload: ["blob_ref": "b1"]),
            event(2, type: "text", payload: ["body": "not an attachment"]),
            event(3, type: "file", payload: ["blob_ref": "b3", "name": "a.pdf"]),
            event(4, type: "tool_output", payload: ["blob_ref": "b4"]),
            event(5, type: "image", payload: ["expired": true]),
        ])
        let result = try store.attachmentEvents(convoID: "c1")
        XCTAssertEqual(result.map(\.seq), [5, 3, 1], "images+files only, newest first")
        XCTAssertEqual(result.map(\.type), ["image", "file", "image"])
    }

    func testAttachmentEventsIsolatesConversations() throws {
        let store = try makeStore()
        try store.insertHistory([
            event(1, type: "image", payload: ["blob_ref": "b1"]),
            event(2, convo: "c1:sub:x", type: "image", payload: ["blob_ref": "b2"]),
            event(3, convo: "c2", type: "file", payload: ["blob_ref": "b3", "name": "z"]),
        ])
        XCTAssertEqual(try store.attachmentEvents(convoID: "c1").map(\.seq), [1],
                       "a parent chat must not pool its sub-chats' media")
    }

    func testLinkCandidateEventsPrefilterAndOrdering() throws {
        let store = try makeStore()
        try store.insertHistory([
            event(1, payload: ["body": "see https://example.com/a"]),
            event(2, payload: ["body": "no links here"]),
            event(3, payload: ["body": "also http://plain.example"]),
            event(4, type: "image", payload: ["blob_ref": "b", "caption": "https://in-caption.example"]),
            event(5, convo: "c2", payload: ["body": "https://other-convo.example"]),
        ])
        let result = try store.linkCandidateEvents(convoID: "c1")
        XCTAssertEqual(result.map(\.seq), [3, 1],
                       "text events with an http substring, this convo only, newest first")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/Dev/matron-apple-media-browser/MatronShared && MATRON_SKIP_SNAPSHOT_TESTS=1 swift test --filter MediaBrowserQueryTests 2>&1 | tail -5`
Expected: FAIL — `attachmentEvents` has no member.

- [ ] **Step 3: Implement the two queries**

In `JournalStore.swift`, directly after `events(convoID:)`:

```swift
    /// `image`/`file` events for one conversation, newest first — the
    /// media & links browser's Media and Files tabs. Reads the full local
    /// history: the timeline's 120-row window cannot see older attachments.
    public func attachmentEvents(convoID: String) throws -> [JournalEvent] {
        try dbQueue.read { db in
            try EventRecord
                .filter(Column("convo_id") == convoID)
                .filter([JournalEventType.image, JournalEventType.file].contains(Column("type")))
                .order(Column("seq").desc)
                .fetchAll(db)
                .map(\.journalEvent)
        }
    }

    /// `text` events that plausibly contain a URL, newest first — a cheap
    /// SQL prefilter; precise extraction happens in Swift (`LinkExtractor`).
    /// `payload` is a JSON BLOB, so CAST to TEXT before LIKE (SQLite's LIKE
    /// is not defined over blobs).
    public func linkCandidateEvents(convoID: String) throws -> [JournalEvent] {
        try dbQueue.read { db in
            try EventRecord
                .fetchAll(db, sql: """
                    SELECT * FROM event
                    WHERE convo_id = ? AND type = 'text'
                      AND CAST(payload AS TEXT) LIKE '%http%'
                    ORDER BY seq DESC
                    """, arguments: [convoID])
                .map(\.journalEvent)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same as Step 2. Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Journal/JournalStore.swift MatronShared/Tests/JournalTests/MediaBrowserQueryTests.swift
git commit -m "feat(store): attachment + link-candidate queries for the media browser"
```

---

### Task 2: LinkExtractor

**Files:**
- Create: `MatronShared/Sources/Chat/LinkExtractor.swift`
- Test: `MatronShared/Tests/ChatTests/LinkExtractorTests.swift` (new)

**Interfaces:**
- Produces (Task 3 relies on): `public enum LinkExtractor { public static func links(in body: String) -> [URL] }` — http/https only, document order.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import MatronChat

/// Pins link extraction for the Links tab. NSDataDetector handles the messy
/// shapes (markdown, angle brackets, trailing punctuation); these tests pin
/// the scheme filter and multi-URL behavior without over-specifying detector
/// internals that vary by OS build (hence hasPrefix, not equality, where
/// punctuation is involved).
final class LinkExtractorTests: XCTestCase {
    func testBareURL() {
        XCTAssertEqual(LinkExtractor.links(in: "deployed to https://example.com/app"),
                       [URL(string: "https://example.com/app")!])
    }

    func testMarkdownAndTrailingPunctuation() {
        let links = LinkExtractor.links(in: "see [docs](https://example.com/docs). Done.")
        XCTAssertEqual(links.count, 1)
        XCTAssertTrue(links[0].absoluteString.hasPrefix("https://example.com/docs"))
    }

    func testNonHTTPSchemesRejected() {
        XCTAssertEqual(LinkExtractor.links(in: "mail me mailto:a@b.c or ftp://files.example"), [])
    }

    func testMultipleURLsKeepDocumentOrder() {
        let links = LinkExtractor.links(in: "first https://a.example then http://b.example")
        XCTAssertEqual(links.map(\.host), ["a.example", "b.example"])
    }

    func testPlainTextYieldsNothing() {
        XCTAssertEqual(LinkExtractor.links(in: "http on its own is not a link"), [])
    }
}
```

- [ ] **Step 2: Run to verify FAIL** (`swift test --filter LinkExtractorTests`) — `LinkExtractor` unresolved.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Extracts http(s) links from message bodies for the media browser's Links
/// tab. `NSDataDetector` (not a regex) so markdown suffixes, angle brackets
/// and trailing punctuation resolve the way the OS link-tap path resolves
/// them; this wrapper pins the scheme filter — agent chats are full of
/// file://, mailto: and ssh: strings nobody wants in a link list.
public enum LinkExtractor {
    public static func links(in body: String) -> [URL] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(body.startIndex..., in: body)
        return detector.matches(in: body, options: [], range: range).compactMap { match in
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return url
        }
    }
}
```

- [ ] **Step 4: Run to verify PASS.** If `testNonHTTPSchemesRejected` fails because the detector surfaces `mailto:` as a URL with scheme `mailto`, the filter already drops it — investigate before touching the assertion; the filter is the contract.

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/Chat/LinkExtractor.swift MatronShared/Tests/ChatTests/LinkExtractorTests.swift
git commit -m "feat(chat): LinkExtractor — http(s) link extraction for the Links tab"
```

---

### Task 3: MediaBrowserViewModel

**Files:**
- Create: `MatronShared/Sources/ViewModels/MediaBrowserViewModel.swift`
- Test: `MatronShared/Tests/ViewModelTests/MediaBrowserViewModelTests.swift` (new)

**Interfaces:**
- Consumes: Task 1 queries (via a small protocol), Task 2 `LinkExtractor.links(in:)`, `JournalTimelineMapper.timelineItem(from:ownSender:serverURL:)`, `MediaService.fetchOutcome(mxcURL:)` (`MediaFetchOutcome` .data/.notFound/.failure).
- Produces (Tasks 5–6 rely on):
  - `public protocol MediaBrowserStoreReading` with the two Task-1 methods; `extension JournalStore: MediaBrowserStoreReading {}` lives in this file (retroactive, cross-module — fine).
  - `@MainActor @Observable public final class MediaBrowserViewModel` with `init(store: MediaBrowserStoreReading, convoID: String, serverURL: URL, media: any MediaService)`, `load()`, `mediaItems: [MediaEntry]`, `fileItems: [FileEntry]`, `links: [LinkEntry]`, `loadFailed: Bool`, `thumbnail(for: URL) async -> Image?`, `isUnavailable(_ url: URL) -> Bool`.
  - `MediaEntry { id: Int64, url: URL?, caption: String?, expired: Bool }`, `FileEntry { id: Int64, url: URL?, name: String, sizeBytes: Int64?, caption: String?, expired: Bool }`, `LinkEntry { id: String, url: URL, context: String, timestamp: Date }` — all `Identifiable, Equatable, Sendable`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import SwiftUI
import MatronChat
import MatronJournal
@testable import MatronViewModels

private struct FakeBrowserStore: MediaBrowserStoreReading {
    var attachments: [JournalEvent] = []
    var linkCandidates: [JournalEvent] = []
    var throwOnRead = false
    struct Boom: Error {}
    func attachmentEvents(convoID: String) throws -> [JournalEvent] {
        if throwOnRead { throw Boom() }
        return attachments
    }
    func linkCandidateEvents(convoID: String) throws -> [JournalEvent] {
        if throwOnRead { throw Boom() }
        return linkCandidates
    }
}

/// Media service whose outcome is fixed — mirrors FileAttachmentDownloadTests'
/// FixedOutcomeMediaService (private there, so re-declared).
private final class FixedOutcomeMedia: MediaService, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: MediaFetchOutcome
    private(set) var requestCount = 0
    init(outcome: MediaFetchOutcome) { self.outcome = outcome }
    func image(for mxc: URL) async -> Data? { nil }
    func fetchOutcome(mxcURL: URL) async -> MediaFetchOutcome {
        lock.withLock { requestCount += 1 }
        return outcome
    }
}

final class MediaBrowserViewModelTests: XCTestCase {
    private let server = URL(string: "https://journal.example")!

    private func event(_ seq: Int64, type: String, payload: [String: Any],
                       ts: TimeInterval? = nil) -> JournalEvent {
        JournalEvent(seq: seq, convoID: "c1",
                     ts: Date(timeIntervalSince1970: ts ?? Double(seq)),
                     sender: "agent:dev-2", type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    private func makeVM(store: FakeBrowserStore,
                        media: MediaService = FixedOutcomeMedia(outcome: .failure)) -> MediaBrowserViewModel {
        MediaBrowserViewModel(store: store, convoID: "c1", serverURL: server, media: media)
    }

    @MainActor
    func test_load_mapsAttachmentsThroughPayloadContract() async {
        let store = FakeBrowserStore(attachments: [
            event(5, type: "image", payload: ["expired": true]),                    // tombstone
            event(3, type: "file", payload: ["blob_ref": "b3", "name": "a.pdf",
                                             "size": 1234, "caption": "the report"]),
            event(1, type: "image", payload: ["blob_ref": "b1"]),
        ])
        let vm = makeVM(store: store)
        await vm.load()
        XCTAssertEqual(vm.mediaItems.map(\.id), [5, 1])
        XCTAssertTrue(vm.mediaItems[0].expired)
        XCTAssertNil(vm.mediaItems[0].url, "tombstone has no blob_ref → no URL")
        XCTAssertEqual(vm.mediaItems[1].url,
                       server.appendingPathComponent("media").appendingPathComponent("b1"))
        XCTAssertEqual(vm.fileItems.map(\.id), [3])
        XCTAssertEqual(vm.fileItems[0].name, "a.pdf")
        XCTAssertEqual(vm.fileItems[0].sizeBytes, 1234)
        XCTAssertFalse(vm.loadFailed)
    }

    @MainActor
    func test_load_extractsDedupesAndOrdersLinks() async {
        let store = FakeBrowserStore(linkCandidates: [   // store returns newest first
            event(9, type: "text", payload: ["body": "again https://a.example/x\nsecond line"]),
            event(7, type: "text", payload: ["body": "https://b.example and https://a.example/x"]),
        ])
        let vm = makeVM(store: store)
        await vm.load()
        XCTAssertEqual(vm.links.map(\.url.absoluteString),
                       ["https://a.example/x", "https://b.example"],
                       "dedup keeps the NEWEST occurrence; order is newest event first")
        XCTAssertEqual(vm.links[0].context, "again https://a.example/x",
                       "context is the first line of the containing message")
        XCTAssertEqual(vm.links[0].timestamp, Date(timeIntervalSince1970: 9))
    }

    @MainActor
    func test_load_storeFailure_setsLoadFailed() async {
        let vm = makeVM(store: FakeBrowserStore(throwOnRead: true))
        await vm.load()
        XCTAssertTrue(vm.loadFailed)
        XCTAssertEqual(vm.mediaItems, [])
    }

    @MainActor
    func test_thumbnail_notFound_marksUnavailableAndExpires_withoutRefetch() async {
        let media = FixedOutcomeMedia(outcome: .notFound)
        let url = server.appendingPathComponent("media").appendingPathComponent("b1")
        let store = FakeBrowserStore(attachments: [
            event(1, type: "image", payload: ["blob_ref": "b1"]),
        ])
        let vm = makeVM(store: store, media: media)
        await vm.load()
        XCTAssertNil(await vm.thumbnail(for: url))
        XCTAssertTrue(vm.isUnavailable(url))
        XCTAssertTrue(vm.mediaItems[0].expired, "a 404 flips the grid cell to expired")
        XCTAssertNil(await vm.thumbnail(for: url))
        XCTAssertEqual(media.requestCount, 1, "permanently-gone blob must not be re-fetched")
    }

    @MainActor
    func test_thumbnail_transientFailure_staysRetryable() async {
        let media = FixedOutcomeMedia(outcome: .failure)
        let url = server.appendingPathComponent("media").appendingPathComponent("b1")
        let vm = makeVM(store: FakeBrowserStore(), media: media)
        XCTAssertNil(await vm.thumbnail(for: url))
        XCTAssertFalse(vm.isUnavailable(url))
        XCTAssertNil(await vm.thumbnail(for: url))
        XCTAssertEqual(media.requestCount, 2, "transient failure retries")
    }

    @MainActor
    func test_thumbnail_decodesAndCaches() async {
        // 1×1 red PNG, generated platform-side so the test carries no fixture.
        let png = Self.tinyPNG()
        final class DataMedia: MediaService, @unchecked Sendable {
            private let lock = NSLock()
            let data: Data
            private(set) var requestCount = 0
            init(data: Data) { self.data = data }
            func image(for mxc: URL) async -> Data? { data }
            func fetchOutcome(mxcURL: URL) async -> MediaFetchOutcome {
                lock.withLock { requestCount += 1 }
                return .data(data)
            }
        }
        let media = DataMedia(data: png)
        let url = server.appendingPathComponent("media").appendingPathComponent("b1")
        let vm = makeVM(store: FakeBrowserStore(), media: media)
        let first = await vm.thumbnail(for: url)
        XCTAssertNotNil(first)
        _ = await vm.thumbnail(for: url)
        XCTAssertEqual(media.requestCount, 1, "second ask must hit the cache")
    }

    private static func tinyPNG() -> Data {
        #if canImport(UIKit) && !os(macOS)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.pngData { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        #else
        let image = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        #endif
    }
}
```

- [ ] **Step 2: Run to verify FAIL** (`swift test --filter MediaBrowserViewModelTests`).

- [ ] **Step 3: Implement**

```swift
import Foundation
import SwiftUI
import ImageIO
import MatronChat
import MatronJournal
#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The two JournalStore reads the media browser needs, as a protocol so
/// tests fake the store. Conformance for the real store is declared here
/// (MatronJournal cannot import this module).
public protocol MediaBrowserStoreReading {
    func attachmentEvents(convoID: String) throws -> [JournalEvent]
    func linkCandidateEvents(convoID: String) throws -> [JournalEvent]
}

extension JournalStore: MediaBrowserStoreReading {}

/// Backs the per-chat "Media, Files and Links" sheet. Reads the FULL local
/// event history (the timeline's `ChatViewModel.items` is a 120-row window —
/// it cannot see a chat's older attachments), maps attachments through the
/// same payload contract the timeline uses (`JournalTimelineMapper`), and
/// extracts links with `LinkExtractor`.
///
/// Store reads run on the main actor: both queries are single indexed GRDB
/// reads returning at most a few thousand small rows (the LIKE prefilter
/// bounds the text set), measured in low milliseconds — not worth an
/// unchecked-Sendable retrofit on JournalStore.
@MainActor @Observable
public final class MediaBrowserViewModel {
    public struct MediaEntry: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let url: URL?
        public let caption: String?
        public var expired: Bool
    }
    public struct FileEntry: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let url: URL?
        public let name: String
        public let sizeBytes: Int64?
        public let caption: String?
        public var expired: Bool
    }
    public struct LinkEntry: Identifiable, Equatable, Sendable {
        public let id: String        // absoluteString — unique post-dedup
        public let url: URL
        public let context: String   // first line of the containing message
        public let timestamp: Date
    }

    public private(set) var mediaItems: [MediaEntry] = []
    public private(set) var fileItems: [FileEntry] = []
    public private(set) var links: [LinkEntry] = []
    public private(set) var loadFailed = false

    private let store: MediaBrowserStoreReading
    private let convoID: String
    private let serverURL: URL
    private let media: any MediaService

    /// Downscaled thumbnails, small LRU — a 12 MB original must not live
    /// once per grid cell. ~200 pt cells → 400 px covers 2× displays.
    private var thumbnails: [URL: Image] = [:]
    private var thumbnailOrder: [URL] = []
    private var unavailable: Set<URL> = []
    private var inFlight: [URL: Task<Image?, Never>] = [:]
    private static let thumbnailCacheLimit = 64
    public static let thumbnailMaxPixel: CGFloat = 400

    public init(store: MediaBrowserStoreReading, convoID: String,
                serverURL: URL, media: any MediaService) {
        self.store = store
        self.convoID = convoID
        self.serverURL = serverURL
        self.media = media
    }

    public func load() async {
        do {
            let attachments = try store.attachmentEvents(convoID: convoID)
            let candidates = try store.linkCandidateEvents(convoID: convoID)
            var mediaAcc: [MediaEntry] = []
            var fileAcc: [FileEntry] = []
            for event in attachments {
                guard let item = JournalTimelineMapper.timelineItem(
                    from: event, ownSender: "", serverURL: serverURL) else { continue }
                switch item.kind {
                case let .image(url, caption, _, expired):
                    mediaAcc.append(MediaEntry(id: event.seq, url: url,
                                               caption: caption, expired: expired))
                case let .file(url, name, caption, size, expired):
                    fileAcc.append(FileEntry(id: event.seq, url: url, name: name,
                                             sizeBytes: size, caption: caption,
                                             expired: expired))
                default:
                    continue
                }
            }
            var seen = Set<String>()
            var linkAcc: [LinkEntry] = []
            for event in candidates {   // newest first → first sighting IS the newest
                guard let body = event.payload["body"] as? String else { continue }
                let context = String(
                    (body.split(whereSeparator: \.isNewline).first ?? "").prefix(200))
                for url in LinkExtractor.links(in: body)
                where seen.insert(url.absoluteString).inserted {
                    linkAcc.append(LinkEntry(id: url.absoluteString, url: url,
                                             context: context, timestamp: event.ts))
                }
            }
            mediaItems = mediaAcc
            fileItems = fileAcc
            links = linkAcc
            loadFailed = false
        } catch {
            loadFailed = true
            mediaItems = []; fileItems = []; links = []
        }
    }

    public func isUnavailable(_ url: URL) -> Bool { unavailable.contains(url) }

    /// Fetch + downscale one grid thumbnail. A 404 is permanent (blob ids
    /// are immutable; the journal reaper deletes over-quota blobs) — the
    /// entry flips to expired and is never re-fetched. In-flight requests
    /// coalesce so a grid redraw doesn't restart downloads.
    public func thumbnail(for url: URL) async -> Image? {
        if let cached = thumbnails[url] { return cached }
        guard !unavailable.contains(url) else { return nil }
        if let running = inFlight[url] { return await running.value }
        let task = Task<Image?, Never> { [media] in
            switch await media.fetchOutcome(mxcURL: url) {
            case .notFound:
                return nil          // distinguished below via unavailable-marking
            case .failure:
                return nil
            case .data(let data):
                return Self.downscaled(data, maxPixel: Self.thumbnailMaxPixel)
            }
        }
        inFlight[url] = task
        // Re-check the outcome kind for the 404 flag: run fetchOutcome once,
        // so wrap the whole switch — implementation detail: fold the marking
        // into the task by returning an enum instead. Simplest correct form:
        let image: Image? = await task.value
        inFlight[url] = nil
        if image == nil {
            // Only a definitive 404 marks unavailable — re-ask the service?
            // No: that would double-fetch. Instead the task above must
            // communicate the outcome. See Step 3a below — the enum return.
            _ = image
        }
        if let image { cacheThumbnail(image, for: url) }
        return image
    }

    private func cacheThumbnail(_ image: Image, for url: URL) {
        thumbnails[url] = image
        thumbnailOrder.removeAll { $0 == url }
        thumbnailOrder.append(url)
        if thumbnailOrder.count > Self.thumbnailCacheLimit,
           let evicted = thumbnailOrder.first {
            thumbnailOrder.removeFirst()
            thumbnails.removeValue(forKey: evicted)
        }
    }

    private func markExpired(_ url: URL) {
        unavailable.insert(url)
        for index in mediaItems.indices where mediaItems[index].url == url {
            mediaItems[index].expired = true
        }
        for index in fileItems.indices where fileItems[index].url == url {
            fileItems[index].expired = true
        }
    }

    private static func downscaled(_ data: Data, maxPixel: CGFloat) -> Image? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        #if canImport(UIKit) && !os(macOS)
        return Image(uiImage: UIImage(cgImage: cg))
        #elseif os(macOS)
        return Image(nsImage: NSImage(cgImage: cg, size: .zero))
        #else
        return nil
        #endif
    }
}
```

**Step 3a (part of the implementation, not optional):** the `thumbnail(for:)` body above sketches the coalescing but punts the 404 signal — implement it properly with a private outcome enum so `fetchOutcome` runs exactly once:

```swift
    private enum ThumbOutcome { case image(Image), gone, failed }

    public func thumbnail(for url: URL) async -> Image? {
        if let cached = thumbnails[url] { return cached }
        guard !unavailable.contains(url) else { return nil }
        if let running = inFlight[url] { return await running.value }
        let task = Task<ThumbOutcome, Never> { [media] in
            switch await media.fetchOutcome(mxcURL: url) {
            case .notFound: return .gone
            case .failure: return .failed
            case .data(let data):
                if let image = Self.downscaled(data, maxPixel: Self.thumbnailMaxPixel) {
                    return .image(image)
                }
                return .failed
            }
        }
        // Store an adapter task so concurrent callers await the same fetch.
        inFlight[url] = Task { await task.value.asImage }
        let outcome = await task.value
        inFlight[url] = nil
        switch outcome {
        case .image(let image):
            cacheThumbnail(image, for: url)
            return image
        case .gone:
            markExpired(url)
            return nil
        case .failed:
            return nil
        }
    }
```
with `private extension MediaBrowserViewModel.ThumbOutcome { var asImage: Image? { if case .image(let i) = self { return i }; return nil } }` (or inline the mapping — executor's choice, keep it compiling under strict concurrency; `Image` is Sendable).

- [ ] **Step 4: Run to verify PASS** (`swift test --filter MediaBrowserViewModelTests` then the full `swift test` with `MATRON_SKIP_SNAPSHOT_TESTS=1` — assert "Executed N tests").

- [ ] **Step 5: Commit**

```bash
git add MatronShared/Sources/ViewModels/MediaBrowserViewModel.swift MatronShared/Tests/ViewModelTests/MediaBrowserViewModelTests.swift
git commit -m "feat(vm): MediaBrowserViewModel — full-history media/files/links with thumbnail LRU"
```

---

### Task 4: Shared MediaBrowserView (DesignSystem) + snapshots

**Files:**
- Create: `MatronShared/Sources/DesignSystem/MediaBrowserView.swift`
- Test: `MatronShared/Tests/DesignSystemSnapshotTests/MediaBrowserSnapshotTests.swift` (new)

**Interfaces:**
- Consumes: `AttachmentFile(filename:sizeBytes:isLoading:isExpired:onTap:)` (existing).
- Produces (Tasks 5–6 rely on — DesignSystem CANNOT import MatronViewModels, so this view takes plain data + closures; platform sheets map VM entries into these):

```swift
public struct MediaBrowserView: View {
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case media = "Media", files = "Files", links = "Links"
        public var id: String { rawValue }
    }
    public struct MediaCell: Identifiable, Equatable, Sendable {
        public let id: Int64; public let url: URL?; public let expired: Bool
        public init(id: Int64, url: URL?, expired: Bool)
    }
    public struct FileRow: Identifiable, Equatable, Sendable {
        public let id: Int64; public let url: URL?; public let name: String
        public let sizeBytes: Int64?; public let expired: Bool
        public let isLoading: Bool
        public init(id: Int64, url: URL?, name: String, sizeBytes: Int64?, expired: Bool, isLoading: Bool)
    }
    public struct LinkRow: Identifiable, Equatable, Sendable {
        public let id: String; public let url: URL
        public let context: String; public let date: Date
        public init(id: String, url: URL, context: String, date: Date)
    }
    public init(
        media: [MediaCell], files: [FileRow], links: [LinkRow],
        loadFailed: Bool = false,
        initialTab: Tab = .media,
        thumbnail: @escaping (URL) async -> Image? = { _ in nil },
        onMediaTap: @escaping (MediaCell) -> Void = { _ in },
        onFileTap: @escaping (FileRow) -> Void = { _ in },
        onLinkTap: @escaping (LinkRow) -> Void = { _ in }
    )
}
```

- [ ] **Step 1: Write the snapshot tests** (record-on-first-run — "failing" here means no baseline yet)

```swift
import XCTest
import SwiftUI
@testable import MatronDesignSystem

/// Snapshot coverage for the media & links browser sheet body: each tab
/// populated and empty, plus the load-failure state. Thumbnails resolve to
/// nil (placeholder rendering) so the grid is deterministic — image bytes
/// never enter a snapshot.
final class MediaBrowserSnapshotTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_755_000_000)

    private var mediaCells: [MediaBrowserView.MediaCell] {
        [
            .init(id: 3, url: URL(string: "https://j.example/media/a"), expired: false),
            .init(id: 2, url: URL(string: "https://j.example/media/b"), expired: false),
            .init(id: 1, url: nil, expired: true),
        ]
    }
    private var fileRows: [MediaBrowserView.FileRow] {
        [
            .init(id: 5, url: URL(string: "https://j.example/media/c"), name: "report.pdf",
                  sizeBytes: 1_234_567, expired: false, isLoading: false),
            .init(id: 4, url: URL(string: "https://j.example/media/d"), name: "trace.log",
                  sizeBytes: 88, expired: false, isLoading: true),
            .init(id: 3, url: nil, name: "old.zip", sizeBytes: 999, expired: true, isLoading: false),
        ]
    }
    private var linkRows: [MediaBrowserView.LinkRow] {
        [
            .init(id: "https://example.com/pr/42", url: URL(string: "https://example.com/pr/42")!,
                  context: "opened https://example.com/pr/42 for review", date: date),
            .init(id: "https://docs.example", url: URL(string: "https://docs.example")!,
                  context: "docs are at https://docs.example", date: date),
        ]
    }

    private func frame<V: View>(_ view: V) -> some View {
        view.frame(width: 600, height: 480)
    }

    func test_mediaTab_populated() {
        assertVariants(of: frame(MediaBrowserView(
            media: mediaCells, files: [], links: [], initialTab: .media)),
            named: "media-populated")
    }
    func test_mediaTab_empty() {
        assertVariants(of: frame(MediaBrowserView(
            media: [], files: [], links: [], initialTab: .media)),
            named: "media-empty")
    }
    func test_filesTab_populated() {
        assertVariants(of: frame(MediaBrowserView(
            media: [], files: fileRows, links: [], initialTab: .files)),
            named: "files-populated")
    }
    func test_filesTab_empty() {
        assertVariants(of: frame(MediaBrowserView(
            media: [], files: [], links: [], initialTab: .files)),
            named: "files-empty")
    }
    func test_linksTab_populated() {
        assertVariants(of: frame(MediaBrowserView(
            media: [], files: [], links: linkRows, initialTab: .links)),
            named: "links-populated")
    }
    func test_linksTab_empty() {
        assertVariants(of: frame(MediaBrowserView(
            media: [], files: [], links: [], initialTab: .links)),
            named: "links-empty")
    }
    func test_loadFailed() {
        assertVariants(of: frame(MediaBrowserView(
            media: [], files: [], links: [], loadFailed: true)),
            named: "load-failed")
    }
}
```

- [ ] **Step 2: Implement the view**

```swift
import SwiftUI

/// Per-chat "Media, Files and Links" browser body — WhatsApp's media
/// browser, Matron-shaped. Pure data + closures (this module cannot see
/// view models); the platform sheets in Matron/ and MatronMac/ own the
/// MediaBrowserViewModel and map its entries into the row/cell structs.
public struct MediaBrowserView: View {
    // …types exactly as in the Interfaces block above…

    let media: [MediaCell]
    let files: [FileRow]
    let links: [LinkRow]
    let loadFailed: Bool
    let thumbnail: (URL) async -> Image?
    let onMediaTap: (MediaCell) -> Void
    let onFileTap: (FileRow) -> Void
    let onLinkTap: (LinkRow) -> Void
    @State private var tab: Tab

    // …public init assigning everything; `_tab = State(initialValue: initialTab)`…

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $tab) {
                ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()
            if loadFailed {
                ContentUnavailableView("Couldn't load",
                                       systemImage: "exclamationmark.triangle")
                    .frame(maxHeight: .infinity)
            } else {
                switch tab {
                case .media: mediaGrid
                case .files: fileList
                case .links: linkList
                }
            }
        }
    }

    @ViewBuilder private var mediaGrid: some View {
        if media.isEmpty {
            ContentUnavailableView("No media yet",
                                   systemImage: "photo.on.rectangle.angled")
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)],
                          spacing: 2) {
                    ForEach(media) { cell in
                        MediaThumbCell(cell: cell, thumbnail: thumbnail,
                                       onTap: { onMediaTap(cell) })
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    @ViewBuilder private var fileList: some View {
        if files.isEmpty {
            ContentUnavailableView("No files yet", systemImage: "doc")
                .frame(maxHeight: .infinity)
        } else {
            List(files) { row in
                AttachmentFile(filename: row.name, sizeBytes: row.sizeBytes,
                               isLoading: row.isLoading, isExpired: row.expired,
                               onTap: { onFileTap(row) })
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder private var linkList: some View {
        if links.isEmpty {
            ContentUnavailableView("No links yet", systemImage: "link")
                .frame(maxHeight: .infinity)
        } else {
            List(links) { row in
                Button { onLinkTap(row) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.url.absoluteString)
                            .font(.callout)
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                        Text(row.context)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(row.date, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Link, \(row.url.absoluteString)")
            }
            .listStyle(.plain)
        }
    }
}

/// One grid cell: async thumbnail with a placeholder; expired renders the
/// dimmed clock-photo treatment (mirrors AttachmentFile's doc.badge.clock).
private struct MediaThumbCell: View {
    let cell: MediaBrowserView.MediaCell
    let thumbnail: (URL) async -> Image?
    let onTap: () -> Void
    @State private var image: Image?

    var body: some View {
        Button(action: { if !cell.expired { onTap() } }) {
            ZStack {
                Rectangle().fill(.quaternary)
                if cell.expired {
                    Image(systemName: "photo.badge.clock")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else if let image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 110, minHeight: 110)
            .aspectRatio(1, contentMode: .fill)
            .clipped()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cell.expired ? "Image, expired" : "Image")
        .task(id: cell.url) {
            guard !cell.expired, let url = cell.url, image == nil else { return }
            image = await thumbnail(url)
        }
    }
}
```

If `photo.badge.clock` fails to resolve at runtime (symbol-availability check: `Image(systemName:)` renders blank), substitute `clock.badge.xmark` — verify in the recorded snapshot that a glyph is visible either way; a blank cell in `test_mediaTab_populated`'s third cell is a FAIL.

- [ ] **Step 3: Record baselines** — run `swift test --filter MediaBrowserSnapshotTests` once (records, reports failures for newly-written baselines), inspect the PNGs under `MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/MediaBrowserSnapshotTests/` visually (expired cell shows dimmed glyph; Files rows show spinner/expired states; Links rows show URL + context + date), then run again → all PASS (determinism).

- [ ] **Step 4: Commit** (include the `__Snapshots__` PNGs)

```bash
git add MatronShared/Sources/DesignSystem/MediaBrowserView.swift MatronShared/Tests/DesignSystemSnapshotTests/MediaBrowserSnapshotTests.swift MatronShared/Tests/DesignSystemSnapshotTests/__Snapshots__/MediaBrowserSnapshotTests
git commit -m "feat(design): MediaBrowserView — three-tab media/files/links sheet body"
```

---

### Task 5: Mac wiring

**Files:**
- Modify: `MatronMac/App/AppDependencies.swift` (service accessors, ~line 399 region)
- Modify: `MatronMac/Features/Chat/MacChatToolbar.swift` (new toolbar button)
- Modify: `MatronMac/Features/Chat/MacChatView.swift` (state + sheet)
- Create: `MatronMac/Features/Chat/MacMediaBrowserSheet.swift`

**Interfaces:**
- Consumes: `MediaBrowserViewModel` (Task 3), `MediaBrowserView` (Task 4), `ChatViewModel.writeTempFile(mxcURL:filename:)`, `.isDownloadingFile(_:)`, `.isMediaUnavailable(_:)`, `MediaService.sizedImage(for:)`, `AttachmentFullscreenViewer(image:nativePixelSize:onDismiss:)`.
- Produces: `AppDependencies.journalStore(for:)` (also added on iOS in Task 6).

- [ ] **Step 1: Store accessor.** In `MatronMac/App/AppDependencies.swift`, next to `mediaService(for:)`:

```swift
    /// The session's journal store, for read-only feature queries (media
    /// browser). Same instance the sync engine writes.
    func journalStore(for session: UserSession) -> JournalStore {
        core(for: session).store
    }
```

- [ ] **Step 2: Toolbar button.** `MacChatToolbar` gains one parameter (defaulted, so existing call sites and `MacChatToolbarTests` compile unchanged):

```swift
    /// Presents the per-chat media & links browser sheet.
    let showMediaBrowser: Binding<Bool>
```
Add `showMediaBrowser: Binding<Bool> = .constant(false)` to the explicit `init` (same defaulting rationale as `showSummaries` — the memberwise init would drop it). In `body`, after the trailing usage-bars item, add:

```swift
        ToolbarItem(placement: .primaryAction) {
            Button { showMediaBrowser.wrappedValue = true } label: {
                Image(systemName: "photo.on.rectangle.angled")
            }
            .help("Media, files & links")
            .accessibilityLabel("Media browser")
        }
```

- [ ] **Step 3: Sheet + glue view.** In `MacChatView`: add `@State private var showMediaBrowser = false`, pass `showMediaBrowser: $showMediaBrowser` in the `MacChatToolbar(...)` call, and attach next to the existing `.sheet(item: $imagePreview)`:

```swift
        .sheet(isPresented: $showMediaBrowser) {
            MacMediaBrowserSheet(chatViewModel: viewModel)
        }
```

New `MacMediaBrowserSheet.swift` — owns the VM (built from environment deps), maps entries to the DesignSystem structs, routes taps; rigid frame per the Mac sheet sizing rule (sheets adopt only rigid content size):

```swift
import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronViewModels

/// Mac presentation of the per-chat media & links browser. Owns the
/// `MediaBrowserViewModel`; taps route into the same paths the timeline
/// uses — images to `AttachmentFullscreenViewer`, files through
/// `ChatViewModel.writeTempFile` → `NSWorkspace.open`, links to the
/// default browser.
struct MacMediaBrowserSheet: View {
    let chatViewModel: ChatViewModel
    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: MediaBrowserViewModel?
    @State private var imagePreview: Preview?

    private struct Preview: Identifiable {
        let id = UUID()
        let image: Image
        let pixelSize: CGSize
    }

    var body: some View {
        Group {
            if let viewModel {
                MediaBrowserView(
                    media: viewModel.mediaItems.map {
                        .init(id: $0.id, url: $0.url,
                              expired: $0.expired || ($0.url.map(viewModel.isUnavailable) ?? false))
                    },
                    files: viewModel.fileItems.map {
                        .init(id: $0.id, url: $0.url, name: $0.name,
                              sizeBytes: $0.sizeBytes,
                              expired: $0.expired || ($0.url.map(chatViewModel.isMediaUnavailable) ?? false),
                              isLoading: $0.url.map(chatViewModel.isDownloadingFile) ?? false)
                    },
                    links: viewModel.links.map {
                        .init(id: $0.id, url: $0.url, context: $0.context, date: $0.timestamp)
                    },
                    loadFailed: viewModel.loadFailed,
                    thumbnail: { await viewModel.thumbnail(for: $0) },
                    onMediaTap: { cell in openImage(cell) },
                    onFileTap: { row in openFile(row) },
                    onLinkTap: { NSWorkspace.shared.open($0.url) }
                )
            } else {
                ProgressView()
            }
        }
        .frame(width: 640, height: 520)   // rigid — Mac sheets ignore ideal sizes
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task {
            guard viewModel == nil, let session else { return }
            let vm = MediaBrowserViewModel(
                store: deps.journalStore(for: session),
                convoID: chatViewModel.roomID,
                serverURL: session.homeserverURL,
                media: deps.mediaService(for: session))
            await vm.load()
            viewModel = vm
        }
        .sheet(item: $imagePreview) { preview in
            AttachmentFullscreenViewer(
                image: preview.image,
                nativePixelSize: preview.pixelSize,
                onDismiss: { imagePreview = nil }
            )
        }
    }

    private func openImage(_ cell: MediaBrowserView.MediaCell) {
        guard let url = cell.url, let session else { return }
        let media = deps.mediaService(for: session)
        Task {
            if let sized = await media.sizedImage(for: url) {
                imagePreview = Preview(image: sized.image, pixelSize: sized.pixelSize)
            }
        }
    }

    private func openFile(_ row: MediaBrowserView.FileRow) {
        guard let url = row.url, !row.expired else { return }
        Task {
            if let tmp = await chatViewModel.writeTempFile(mxcURL: url, filename: row.name) {
                NSWorkspace.shared.open(tmp)
            }
        }
    }
}
```

**Verify before building:** the exact environment key property names (`\.appDependencies`, `\.currentSession`) against the `EnvironmentValues` extensions near `AppDependenciesKey`/`CurrentSessionKey` (MatronMac/App/AppDependencies.swift ~line 502 on iOS; find the Mac equivalents) and whether `session` is optional there — adjust the `guard let session` accordingly. Also confirm `AttachmentFullscreenViewer`'s Mac init signature (`nativePixelSize:` label) at its definition before use.

- [ ] **Step 4: Build**

```bash
cd ~/Dev/matron-apple-media-browser && xcodegen generate
xcodebuild -project Matron.xcodeproj -scheme MatronMac -configuration Debug -derivedDataPath build/dd build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add MatronMac/App/AppDependencies.swift MatronMac/Features/Chat/MacChatToolbar.swift MatronMac/Features/Chat/MacChatView.swift MatronMac/Features/Chat/MacMediaBrowserSheet.swift
git commit -m "feat(mac): media & links browser — toolbar button + sheet"
```

---

### Task 6: iOS wiring

**Files:**
- Modify: `Matron/App/AppDependencies.swift` (same `journalStore(for:)` accessor as Task 5 Step 1, next to `mediaService(for:)` ~line 264)
- Modify: `Matron/Features/Chat/ChatView.swift` (toolbar button + sheet)
- Create: `Matron/Features/Chat/MediaBrowserSheet.swift`

**Interfaces:**
- Consumes: Tasks 3–4 types, `AttachmentFullscreenViewer(image:onDismiss:)` (iOS init — no pixel size), the `fileShareSheet(url:filename:)` pattern (ChatView ~line 840; the browser sheet reimplements the same ShareLink body since that builder is private to ChatView), `openURL` environment.
- Produces: nothing new.

- [ ] **Step 1: iOS store accessor** — identical to Task 5 Step 1, in `Matron/App/AppDependencies.swift`.

- [ ] **Step 2: Toolbar button.** In `ChatView`'s `.toolbar`, between the subagents `ToolbarItem` and the info `ToolbarItem` (~line 713):

```swift
            ToolbarItem(placement: .topBarTrailing) {
                Button { showMediaBrowser = true } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                }
                .accessibilityLabel("Media, files and links")
            }
```
plus `@State private var showMediaBrowser = false` and, next to the existing `.sheet(isPresented: $showSessionStatus)`:

```swift
        .sheet(isPresented: $showMediaBrowser) {
            MediaBrowserSheet(chatViewModel: viewModel)
        }
```
(Three trailing items max — subagents · media · info; iOS 26 truncates leading *text*, never trailing buttons.) Do NOT add the button to the sub-chat view (`SubChatView`, ~line 1074+) — spec non-goal.

- [ ] **Step 3: Glue sheet.** `Matron/Features/Chat/MediaBrowserSheet.swift`:

```swift
import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronViewModels

/// iOS presentation of the per-chat media & links browser. Mirrors
/// MacMediaBrowserSheet: VM owned here, taps route to the pinch-zoom
/// viewer / ShareLink / openURL.
struct MediaBrowserSheet: View {
    let chatViewModel: ChatViewModel
    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
    @Environment(\.openURL) private var openURL
    @State private var viewModel: MediaBrowserViewModel?
    @State private var preview: Preview?

    private enum Preview: Identifiable {
        case image(UUID, Image)
        case file(UUID, URL, filename: String)
        var id: UUID {
            switch self {
            case .image(let id, _): return id
            case .file(let id, _, _): return id
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    MediaBrowserView(
                        media: viewModel.mediaItems.map {
                            .init(id: $0.id, url: $0.url,
                                  expired: $0.expired || ($0.url.map(viewModel.isUnavailable) ?? false))
                        },
                        files: viewModel.fileItems.map {
                            .init(id: $0.id, url: $0.url, name: $0.name,
                                  sizeBytes: $0.sizeBytes,
                                  expired: $0.expired || ($0.url.map(chatViewModel.isMediaUnavailable) ?? false),
                                  isLoading: $0.url.map(chatViewModel.isDownloadingFile) ?? false)
                        },
                        links: viewModel.links.map {
                            .init(id: $0.id, url: $0.url, context: $0.context, date: $0.timestamp)
                        },
                        loadFailed: viewModel.loadFailed,
                        thumbnail: { await viewModel.thumbnail(for: $0) },
                        onMediaTap: { cell in openImage(cell) },
                        onFileTap: { row in openFile(row) },
                        onLinkTap: { openURL($0.url) }
                    )
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Media")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            guard viewModel == nil, let session else { return }
            let vm = MediaBrowserViewModel(
                store: deps.journalStore(for: session),
                convoID: chatViewModel.roomID,
                serverURL: session.homeserverURL,
                media: deps.mediaService(for: session))
            await vm.load()
            viewModel = vm
        }
        .sheet(item: $preview) { presented in
            switch presented {
            case .image(_, let img):
                AttachmentFullscreenViewer(image: img, onDismiss: { preview = nil })
            case .file(_, let url, let filename):
                // Same body as ChatView.fileShareSheet (private there):
                NavigationStack {
                    VStack(spacing: 16) {
                        Image(systemName: "doc").font(.largeTitle).foregroundStyle(.tint)
                        Text(filename).font(.headline)
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    .padding()
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func openImage(_ cell: MediaBrowserView.MediaCell) {
        guard let url = cell.url, let session else { return }
        let media = deps.mediaService(for: session)
        Task {
            if let img = await media.swiftUIImage(for: url) {
                preview = .image(UUID(), img)
            }
        }
    }

    private func openFile(_ row: MediaBrowserView.FileRow) {
        guard let url = row.url, !row.expired else { return }
        Task {
            if let tmp = await chatViewModel.writeTempFile(mxcURL: url, filename: row.name) {
                preview = .file(UUID(), tmp, filename: row.name)
            }
        }
    }
}
```

**Verify before building:** iOS `AttachmentFullscreenViewer` init labels (ChatView ~line 803 shows `image:onDismiss:`), the environment key names, and `fileShareSheet`'s actual body (~line 840) — mirror it rather than inventing a new layout; if it's more than the sketch above, copy its structure.

- [ ] **Step 4: Build**

```bash
xcodebuild -project Matron.xcodeproj -scheme Matron -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Matron/App/AppDependencies.swift Matron/Features/Chat/ChatView.swift Matron/Features/Chat/MediaBrowserSheet.swift
git commit -m "feat(ios): media & links browser — toolbar button + sheet"
```

---

### Task 7: Full verification + PR

- [ ] **Step 1: Full SPM suite** (snapshots ON so the new baselines verify):

```bash
cd ~/Dev/matron-apple-media-browser/MatronShared && swift test 2>&1 | tail -5
```
Expected: "Executed N tests, with 0 failures" (N ≥ 1140-ish; the pre-existing MessageBubbleSnapshotTests drift may fail on this machine — stash-proof: confirm those exact failures exist on a clean `main` checkout before dismissing, per the 2026-08-13 note; do not re-record them).

- [ ] **Step 2: Both app schemes build** (commands from Tasks 5/6 Step 4).

- [ ] **Step 3: Push + PR**

```bash
git push -u origin feat/media-links-browser
gh pr create --repo Matronhq/matron-apple --title "Per-chat media & links browser" --body "$(cat <<'EOF'
WhatsApp-style per-conversation browser, opened from the chat toolbar on both platforms: Media grid → existing zoom viewers, Files list reusing AttachmentFile (spinner + Expired states compose), Links tab with every http(s) URL from any sender — deduped, newest first.

Reads the full local JournalStore history (the timeline's 120-row window can't see old attachments); no server changes. Spec: docs/superpowers/specs/2026-08-13-media-links-browser-design.md (approved 2026-08-13).

- JournalStore: `attachmentEvents` / `linkCandidateEvents` (indexed, newest-first; CAST-to-TEXT LIKE prefilter for links)
- `LinkExtractor`: NSDataDetector, http/https only
- `MediaBrowserViewModel`: mapper-shared payload contract, dedup-keep-newest links, 64-entry downscaled-thumbnail LRU, 404 → expired (same channel as the timeline)
- `MediaBrowserView` (DesignSystem, pure): 3 tabs + empty/failure states, snapshot-covered
- Platform sheets: Mac rigid 640×520 + NSWorkspace routes; iOS NavigationStack + pinch-zoom/ShareLink/openURL routes

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Bot triage** — wait for CodeRabbit + Cursor Bugbot, verify every finding against the code before fixing (receiving-code-review skill), push fixes, `bugbot run` comment to re-trigger.
