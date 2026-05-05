import XCTest
import Foundation
import MatrixRustSDK
import MatronAuth
import MatronModels
import MatronStorage
import MatronSync

/// Phase 2.5 spike — does `RoomListService.allRooms().entriesWithDynamicAdapters`
/// work against tuwunel today?
///
/// Phase 1's `ChatServiceLive.chatSummaries()` (lines 73-86) blamed a
/// crash inside the SDK's `VectorDiff::map / BaseStateStore` pipeline
/// when this API was called against tuwunel. The code shipped with a
/// one-shot `client.rooms()` snapshot fallback and an aspirational
/// "Phase 2 (timeline view) can revisit this with a real subscription
/// once the SDK path is stable" comment that never got picked up.
///
/// Now (matrix-rust-components-swift 26.4.1, Phase 3 in flight) we want
/// to know empirically whether the historical blocker is still there
/// before designing the long-lived chat-list subscription. This test
/// is **expected to be deleted** after the answer is recorded inline
/// in `RoomListSubscription.swift` (created in Phase 2.5 Task 2).
///
/// Two-part probe:
///   1. Start sync, attach the dynamic-adapters listener, observe for
///      a few seconds. Pass if the listener fires at least once with
///      an initial snapshot and no crash.
///   2. Create a room via the same SDK Client. Listener should fire
///      another diff containing the new room within ~5s (assertion
///      bounded at 10s for CI).
///
/// To run end-to-end (with a fresh harness):
///
///     tests/integration/run-harness.sh roomlist-spike-sdk.sh
///
/// To run manually against a long-running harness, see
/// `VerificationFlowIntegrationTests` for the env-var setup pattern.
final class RoomListSubscriptionSpikeTests: XCTestCase {

    private var basePath: URL!
    private var syncService: SyncServiceLive?

    override func setUpWithError() throws {
        try super.setUpWithError()
        basePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("matron-rl-spike-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        if let s = syncService { await s.stop() }
        syncService = nil
        try? FileManager.default.removeItem(at: basePath)
        try await super.tearDown()
    }

    func testRoomListEntriesWithDynamicAdapters_firesAndDoesNotCrash() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let homeserverString = env["MATRON_HOMESERVER"] ?? env["HOMESERVER"] else {
            throw XCTSkip("MATRON_HOMESERVER not set; run via tests/integration/run-harness.sh")
        }
        guard let homeserverURL = URL(string: homeserverString) else {
            throw XCTSkip("MATRON_HOMESERVER not a valid URL: \(homeserverString)")
        }
        let username = env["MATRON_USER"] ?? "matron"
        let password = env["MATRON_PW"] ?? "matron-test-pw"

        // 1. Sign in fresh.
        let storeDir = basePath.appendingPathComponent("session-store")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let sdkStore = basePath.appendingPathComponent("sdk-store")
        let auth = AuthServiceLive(
            sessionStore: FileSessionStore(directory: storeDir),
            basePath: sdkStore
        )
        let session = try await auth.loginPassword(
            homeserverURL: homeserverURL,
            username: username,
            password: password,
            initialDeviceDisplayName: "matron-rl-spike"
        )

        // 2. Start sync.
        let provider = ClientProvider(basePath: sdkStore)
        let sync = SyncServiceLive(provider: provider, session: session)
        syncService = sync
        try await sync.start()
        try await sync.waitUntilReady()

        guard let sdkSync = await sync.sdkService() else {
            XCTFail("sync.sdkService() returned nil after waitUntilReady")
            return
        }

        // 3. Attach the dynamic-adapters listener. The actor-protected
        //    capture box gets every diff so the test can assert about
        //    them. `pageSize: 100` matches the SDK example
        //    (Walkthrough.swift:103) and is generous for a freshly
        //    registered user that has zero rooms initially.
        let captured = ListenerCapture()
        let listener = CapturingRoomListEntriesListener { update in
            Task { await captured.append(update) }
        }
        let roomListService = sdkSync.roomListService()
        let allRooms: RoomList
        do {
            allRooms = try await roomListService.allRooms()
        } catch {
            XCTFail("allRooms() threw: \(error). Sync was reported ready; this is unexpected.")
            return
        }

        let result = allRooms.entriesWithDynamicAdapters(pageSize: 100, listener: listener)
        // Hold a strong reference to the result so the listener stays
        // alive for the duration of the test. (The SDK type is a thin
        // controller; dropping it cancels the subscription.)
        defer { _ = result }

        // Crucial: without a filter, the dynamic-adapters window is
        // empty and the listener never fires. SDK Walkthrough example
        // (Walkthrough.swift:104) calls .all(filters: []) which means
        // "all rooms, no extra filtering" — that's what we want for a
        // chat-list view.
        _ = result.controller().setFilter(kind: .all(filters: []))

        // 4. Wait up to 5s for the initial snapshot to arrive. If the
        //    historical crash is still there, this is where it bites
        //    (BaseStateStore::rooms_stream / VectorDiff::map).
        var initialFireCount = 0
        for _ in 0..<50 {
            initialFireCount = await captured.count()
            if initialFireCount > 0 { break }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        XCTAssertGreaterThan(initialFireCount, 0,
                             "RoomList listener never fired in 5s — historical tuwunel crash may still be present, OR sync isn't pushing initial state")

        let initialDiffs = await captured.diffs()
        // Log every captured update so we can see what tuwunel actually
        // streams. Helpful when the test passes but the per-room state
        // isn't what we expect.
        for (i, diff) in initialDiffs.enumerated() {
            print("[RoomListSpike] diff[\(i)]: \(String(describing: diff))")
        }

        // 5. Create a fresh room. This stands in for "another device
        //    creates a room while matron is signed in". On a new user
        //    @matron1 there are no other devices, but the room CREATE
        //    still rolls through sliding sync the same way.
        let client = try await provider.client(for: session)
        let request = CreateRoomParameters(
            name: "spike-room-\(UUID().uuidString.prefix(8))",
            topic: nil,
            isEncrypted: false,
            isDirect: false,
            visibility: .private,
            preset: .privateChat,
            invite: nil,
            avatar: nil
        )
        let createdRoomID = try await client.createRoom(request: request)
        print("[RoomListSpike] created room: \(createdRoomID)")

        // 6. Wait up to 10s for a new diff describing that room.
        //    Generous timeout — sliding sync can take a few seconds to
        //    push state from a freshly-created room.
        let beforeCreateCount = initialDiffs.count
        var afterCount = beforeCreateCount
        for _ in 0..<100 {
            afterCount = await captured.count()
            if afterCount > beforeCreateCount { break }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        XCTAssertGreaterThan(afterCount, beforeCreateCount,
                             "RoomList listener never fired after a new room was created — sliding sync isn't pushing the diff, OR the listener stopped after the initial snapshot")

        let allDiffs = await captured.diffs()
        for (i, diff) in allDiffs[beforeCreateCount...].enumerated() {
            print("[RoomListSpike] post-create diff[\(beforeCreateCount + i)]: \(String(describing: diff))")
        }

        // Finished. Tear-down handles cleanup.
    }

    /// Phase 2.5 Task 3 Step 0 — does N×`Room.subscribeToRoomInfoUpdates()`
    /// scale, or does the per-room callback storm dwarf any benefit?
    ///
    /// The plan calls the API `subscribeToUpdates` informally, but the
    /// actual SDK surface (matrix-rust-components-swift 26.4.1) is
    /// `Room.subscribeToRoomInfoUpdates(listener: RoomInfoListener) ->
    /// TaskHandle` with an immediate-on-subscribe `RoomInfo` emit, so this
    /// probe is on the right method.
    ///
    /// Probe shape:
    ///   1. Sign in fresh, start sync, attach the dynamic-adapters
    ///      listener, wait for the initial `.reset`.
    ///   2. Create N synthetic rooms (N=10 in CI; 100 would be expensive
    ///      and tuwunel-bound, and the callback-rate question is the same
    ///      shape regardless of cohort size — what we're testing is "does
    ///      one user-driven mutation produce O(1) callbacks per room, or
    ///      does the listener storm").
    ///   3. Wait for those rooms to land in the listener's window.
    ///   4. Take every Room reference the listener handed us, call
    ///      `subscribeToRoomInfoUpdates` on each, wait 30s of quiescent
    ///      time.
    ///   5. Assert: total callbacks across all subscriptions is bounded
    ///      (≤ ~N × 5 — generous). The lower bound is N (the SDK emits
    ///      once on subscribe). Anything dramatically higher would
    ///      indicate per-room state churn that would tank UI responsiveness
    ///      at page-100 scale.
    ///   6. Cancel every TaskHandle cleanly.
    ///
    /// Skips silently when MATRON_HOMESERVER is unset (mirrors the other
    /// spike test). Run via:
    ///     tests/integration/run-harness.sh roomlist-spike-sdk.sh
    func testRoomSubscribeToRoomInfoUpdates_scalesAtPage100() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let homeserverString = env["MATRON_HOMESERVER"] ?? env["HOMESERVER"] else {
            throw XCTSkip("MATRON_HOMESERVER not set; run via tests/integration/run-harness.sh")
        }
        guard let homeserverURL = URL(string: homeserverString) else {
            throw XCTSkip("MATRON_HOMESERVER not a valid URL: \(homeserverString)")
        }
        let username = env["MATRON_USER"] ?? "matron"
        let password = env["MATRON_PW"] ?? "matron-test-pw"

        // 1. Sign in fresh.
        let storeDir = basePath.appendingPathComponent("session-store")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let sdkStore = basePath.appendingPathComponent("sdk-store")
        let auth = AuthServiceLive(
            sessionStore: FileSessionStore(directory: storeDir),
            basePath: sdkStore
        )
        let session = try await auth.loginPassword(
            homeserverURL: homeserverURL,
            username: username,
            password: password,
            initialDeviceDisplayName: "matron-rl-scale-spike"
        )

        // 2. Start sync.
        let provider = ClientProvider(basePath: sdkStore)
        let sync = SyncServiceLive(provider: provider, session: session)
        syncService = sync
        try await sync.start()
        try await sync.waitUntilReady()

        guard let sdkSync = await sync.sdkService() else {
            XCTFail("sync.sdkService() returned nil after waitUntilReady")
            return
        }

        // 3. Pre-create N rooms BEFORE attaching the listener so the
        //    initial `.reset` carries them all in one batch. Faster than
        //    racing per-room push-backs across sliding-sync.
        let client = try await provider.client(for: session)
        let cohortSize = 10
        var createdIDs: [String] = []
        for i in 0..<cohortSize {
            let request = CreateRoomParameters(
                name: "scale-spike-\(i)-\(UUID().uuidString.prefix(6))",
                topic: nil,
                isEncrypted: false,
                isDirect: false,
                visibility: .private,
                preset: .privateChat,
                invite: nil,
                avatar: nil
            )
            createdIDs.append(try await client.createRoom(request: request))
        }
        print("[RoomListSpike] created \(createdIDs.count) cohort rooms")

        // 4. Attach the dynamic-adapters listener.
        let captured = ListenerCapture()
        let listener = CapturingRoomListEntriesListener { update in
            Task { await captured.append(update) }
        }
        let roomListService = sdkSync.roomListService()
        let allRooms: RoomList
        do {
            allRooms = try await roomListService.allRooms()
        } catch {
            XCTFail("allRooms() threw: \(error)")
            return
        }
        let result = allRooms.entriesWithDynamicAdapters(pageSize: 100, listener: listener)
        defer { _ = result }
        _ = result.controller().setFilter(kind: .all(filters: []))

        // 5. Wait until the listener has reported at least `cohortSize`
        //    rooms across all captured diffs. Sliding sync may fan them
        //    out across multiple batches.
        var observedRooms: [MatrixRustSDK.Room] = []
        for _ in 0..<300 {
            observedRooms = await captured.allRooms()
            if observedRooms.count >= cohortSize { break }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        XCTAssertGreaterThanOrEqual(
            observedRooms.count, cohortSize,
            "Expected at least \(cohortSize) rooms in listener window after pre-creation, saw \(observedRooms.count)"
        )

        // 6. Subscribe to RoomInfo updates on every observed room (cap
        //    at the SDK page size of 100 — anything beyond that wouldn't
        //    be visible to the chat list anyway).
        let subscribeTarget = Array(observedRooms.prefix(100))
        print("[RoomListSpike] subscribing to RoomInfo updates on \(subscribeTarget.count) rooms")
        let counter = CallbackCounter()
        var handles: [TaskHandle] = []
        for room in subscribeTarget {
            let infoListener = CountingRoomInfoListener { _ in
                Task { await counter.tick() }
            }
            let handle = room.subscribeToRoomInfoUpdates(listener: infoListener)
            handles.append(handle)
        }

        // 7. Wait 30s. The SDK is documented to emit once immediately on
        //    subscribe (so we expect at least N callbacks straight away);
        //    everything beyond that is genuine room-state churn or storm.
        try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s

        let totalCallbacks = await counter.value()
        let perRoom = Double(totalCallbacks) / Double(subscribeTarget.count)
        print("[RoomListSpike] 30s observation: total RoomInfo callbacks=\(totalCallbacks) across \(subscribeTarget.count) rooms (avg=\(perRoom)/room)")

        // Expectation: ≥ N (one per room on subscribe), ≤ N × 5 (generous
        // upper bound — anything more would indicate per-room churn that
        // would degrade UI at page-100 scale and force us to scope to a
        // sliding window).
        XCTAssertGreaterThanOrEqual(totalCallbacks, subscribeTarget.count,
                                    "Expected ≥ N=\(subscribeTarget.count) callbacks (one per room on subscribe)")
        XCTAssertLessThanOrEqual(totalCallbacks, subscribeTarget.count * 5,
                                 "Expected ≤ 5N=\(subscribeTarget.count * 5) callbacks; saw \(totalCallbacks). Per-room churn is too high; consider sliding-window scoping (top ~20).")

        // 8. Drop handles cleanly.
        for handle in handles { handle.cancel() }
        handles.removeAll()
    }
}

private actor CallbackCounter {
    private var n: Int = 0
    func tick() { n += 1 }
    func value() -> Int { n }
}

private final class CountingRoomInfoListener: RoomInfoListener, @unchecked Sendable {
    private let onInfo: (RoomInfo) -> Void
    init(onInfo: @escaping (RoomInfo) -> Void) {
        self.onInfo = onInfo
    }
    func call(roomInfo: RoomInfo) {
        onInfo(roomInfo)
    }
}

private actor ListenerCapture {
    private(set) var stored: [[RoomListEntriesUpdate]] = []
    func append(_ update: [RoomListEntriesUpdate]) {
        stored.append(update)
    }
    func count() -> Int { stored.count }
    func diffs() -> [[RoomListEntriesUpdate]] { stored }

    /// Walks every captured batch, applies it to a synthetic ordered
    /// vector, and returns the resulting `Room` references. Mirrors the
    /// production diff-application algorithm at a coarse level so the
    /// scaling spike can subscribe to whatever the listener actually
    /// surfaced (rather than re-asking the SDK and racing sliding-sync).
    func allRooms() -> [MatrixRustSDK.Room] {
        var rooms: [MatrixRustSDK.Room] = []
        for batch in stored {
            for diff in batch {
                switch diff {
                case .append(let values): rooms.append(contentsOf: values)
                case .pushBack(let v):    rooms.append(v)
                case .pushFront(let v):   rooms.insert(v, at: 0)
                case .popBack:            if !rooms.isEmpty { rooms.removeLast() }
                case .popFront:           if !rooms.isEmpty { rooms.removeFirst() }
                case .insert(let i, let v):
                    let idx = Int(i)
                    if idx >= 0, idx <= rooms.count { rooms.insert(v, at: idx) }
                case .set(let i, let v):
                    let idx = Int(i)
                    if idx >= 0, idx < rooms.count { rooms[idx] = v }
                case .remove(let i):
                    let idx = Int(i)
                    if idx >= 0, idx < rooms.count { rooms.remove(at: idx) }
                case .truncate(let n):
                    let len = Int(n)
                    if len < rooms.count { rooms.removeLast(rooms.count - len) }
                case .clear:              rooms.removeAll()
                case .reset(let values):  rooms = values
                }
            }
        }
        return rooms
    }
}

private final class CapturingRoomListEntriesListener: RoomListEntriesListener, @unchecked Sendable {
    private let onUpdate: ([RoomListEntriesUpdate]) -> Void
    init(onUpdate: @escaping ([RoomListEntriesUpdate]) -> Void) {
        self.onUpdate = onUpdate
    }
    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) {
        onUpdate(roomEntriesUpdate)
    }
}
