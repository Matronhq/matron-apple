import XCTest
import MatrixRustSDK
@testable import MatronPush

/// Pins `PushBootstrap.setPerRoomNotificationMode()` and the `bootstrap()`
/// orchestration. The Phase 4 plan called for re-enabling
/// `.m.rule.master` here too, but v26 of the SDK doesn't expose
/// `setPushRuleEnabled` — that step is deliberately out of scope; see
/// the doc-comment on `PushBootstrap` for the full rationale. These
/// tests cover what's actually shipping: per-room `.allMessages` mode
/// + permission-decline short-circuit + per-room failure resilience.
@MainActor
final class PushBootstrapTests: XCTestCase {
    func test_setPerRoomNotificationMode_setsAllJoinedRoomsToAllMessages() async {
        let settings = FakeMatronNotificationSettings()
        let bootstrap = PushBootstrap(
            pushService: NoopPushService(),
            pusherBaseURL: URL(string: "https://sygnal.example")!,
            notificationSettings: settings,
            joinedRoomIDs: { ["!a:s.example", "!b:s.example", "!c:s.example"] }
        )

        await bootstrap.setPerRoomNotificationMode()

        XCTAssertEqual(settings.modes["!a:s.example"], .allMessages)
        XCTAssertEqual(settings.modes["!b:s.example"], .allMessages)
        XCTAssertEqual(settings.modes["!c:s.example"], .allMessages)
    }

    func test_setPerRoomNotificationMode_continuesPastPerRoomFailure() async {
        // Spec §8.2 wants every joined room set to .allMessages. If
        // one room's API call fails (network blip, server-side rate
        // limit), the rest must still land — the next bootstrap pass
        // (next launch) re-tries the failing one.
        let settings = FakeMatronNotificationSettings()
        settings.failingRoomIDs = ["!b:s.example"]
        let bootstrap = PushBootstrap(
            pushService: NoopPushService(),
            pusherBaseURL: URL(string: "https://sygnal.example")!,
            notificationSettings: settings,
            joinedRoomIDs: { ["!a:s.example", "!b:s.example", "!c:s.example"] }
        )

        await bootstrap.setPerRoomNotificationMode()

        XCTAssertEqual(settings.modes["!a:s.example"], .allMessages)
        XCTAssertNil(settings.modes["!b:s.example"], "failing room should NOT be recorded as set")
        XCTAssertEqual(settings.modes["!c:s.example"], .allMessages)
    }

    func test_setPerRoomNotificationMode_emptyJoinedRoomsList_isHarmless() async {
        // Cold-start before any rooms have synced — joinedRoomIDs is
        // empty. Bootstrap should still complete without throwing;
        // the next sync's `chatSummaries()` snapshot will populate
        // and the next bootstrap pass will set the rooms.
        let settings = FakeMatronNotificationSettings()
        let bootstrap = PushBootstrap(
            pushService: NoopPushService(),
            pusherBaseURL: URL(string: "https://sygnal.example")!,
            notificationSettings: settings,
            joinedRoomIDs: { [] }
        )

        await bootstrap.setPerRoomNotificationMode()

        XCTAssertTrue(settings.modes.isEmpty)
    }

    func test_register_callsRegisterTokenOnPushService() async {
        let push = NoopPushService()
        let url = URL(string: "https://sygnal.example/sygnal")!
        let bootstrap = PushBootstrap(
            pushService: push,
            pusherBaseURL: url,
            notificationSettings: FakeMatronNotificationSettings(),
            joinedRoomIDs: { [] }
        )
        let token = Data([0x01, 0x02, 0x03, 0x04])

        await bootstrap.register(token: token)

        XCTAssertEqual(push.registeredTokens.count, 1)
        XCTAssertEqual(push.registeredTokens.first?.token, token)
        XCTAssertEqual(push.registeredTokens.first?.url, url)
    }

    func test_register_swallowsThrownErrorsFromPushService() async {
        // `PushService.registerToken` throws on network failure;
        // PushBootstrap should swallow today (Phase 4 doesn't gate UX
        // on this; future Settings UI surfaces it). Pin behaviour so
        // a future refactor doesn't accidentally turn registration
        // into a hard failure that breaks the post-verify branch.
        final class ThrowingPushService: PushService, @unchecked Sendable {
            func requestPermission() async -> Bool { true }
            func registerToken(_: Data, pusherBaseURL: URL) async throws {
                struct Err: Error {}
                throw Err()
            }
            func unregister(deviceToken: Data, pusherBaseURL: URL) async throws {}
        }
        let bootstrap = PushBootstrap(
            pushService: ThrowingPushService(),
            pusherBaseURL: URL(string: "https://sygnal.example")!,
            notificationSettings: FakeMatronNotificationSettings(),
            joinedRoomIDs: { [] }
        )

        // No try — must not propagate.
        await bootstrap.register(token: Data([0x00]))
    }

    // MARK: - PushTokenStore

    func test_pushTokenStore_resumesWaitersOnSetToken() async {
        let store = PushTokenStore()
        let token = Data([0xab, 0xcd])
        Task { @MainActor in
            // Yield once so the awaiter below installs its continuation
            // before setToken fires; otherwise setToken returns early
            // (no waiters yet) and the awaiter blocks forever.
            await Task.yield()
            store.setToken(token)
        }

        let received = await store.waitForToken()
        XCTAssertEqual(received, token)
    }

    func test_pushTokenStore_returnsCachedTokenImmediately() async {
        let store = PushTokenStore()
        let token = Data([0xfe, 0xed])
        store.setToken(token)

        // Already cached — must not block.
        let received = await store.waitForToken()
        XCTAssertEqual(received, token)
    }

    // MARK: - PushTokenStore.enqueuePushOperation ordering

    func test_enqueuePushOperation_runsInOrder() async {
        // Cursor PR #5 finding "unregister can erase new pusher": if
        // sign-out's unregister and bootstrap's register can race, a
        // late unregister from a prior session can delete a fresh
        // register. The chain serialises them. This test enqueues
        // three operations and asserts they ran in enqueue order.
        let store = PushTokenStore()
        let recorder = OrderRecorder()

        store.enqueuePushOperation { [recorder] in
            // Sleep on the first task so the second has a chance to
            // be scheduled before the first finishes — without the
            // chain, the second would race ahead.
            try? await Task.sleep(nanoseconds: 50_000_000)
            await recorder.append("a")
        }
        store.enqueuePushOperation { [recorder] in
            await recorder.append("b")
        }
        store.enqueuePushOperation { [recorder] in
            await recorder.append("c")
        }

        await store.awaitPendingPushOperations()
        let order = await recorder.recorded
        XCTAssertEqual(order, ["a", "b", "c"])
    }

    func test_awaitPendingPushOperations_returnsImmediatelyWhenChainEmpty() async {
        // Bootstrap calls `awaitPendingPushOperations()` before
        // `register(token:)`. On a clean cold-start (no prior
        // sign-out / unregister enqueued), this must NOT block.
        let store = PushTokenStore()
        await store.awaitPendingPushOperations()
        // No assertion needed — the test passes by completing.
    }
}

/// Actor-protected ordered list used by `test_enqueuePushOperation_runsInOrder`
/// — `Task` closures need a Sendable sink to record their landing order
/// without tripping concurrency-checking warnings on a plain `[String]`.
private actor OrderRecorder {
    var recorded: [String] = []
    func append(_ value: String) { recorded.append(value) }
}
