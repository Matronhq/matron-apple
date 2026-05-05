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
}

private actor ListenerCapture {
    private(set) var stored: [[RoomListEntriesUpdate]] = []
    func append(_ update: [RoomListEntriesUpdate]) {
        stored.append(update)
    }
    func count() -> Int { stored.count }
    func diffs() -> [[RoomListEntriesUpdate]] { stored }
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
