import Foundation
@testable import MatronPush

/// Records calls to `requestPermission` / `registerToken` / `unregister`
/// without doing any system work. `PushBootstrapTests` inject this
/// instead of `PushServiceLive` because (a) `requestPermission`
/// surfaces the OS notification prompt which can't run in a unit-test
/// process, and (b) `registerToken` requires a live `Client` resolved
/// off a real homeserver.
final class NoopPushService: PushService, @unchecked Sendable {
    /// Returned by `requestPermission()`. Default `true` so the
    /// happy-path tests don't need to flip this; permission-declined
    /// tests can override to `false`.
    var permissionGranted = true

    private(set) var requestPermissionCallCount = 0
    private(set) var registeredTokens: [(token: Data, url: URL)] = []
    private(set) var unregisteredTokens: [(token: Data, url: URL)] = []

    func requestPermission() async -> Bool {
        requestPermissionCallCount += 1
        return permissionGranted
    }

    func registerToken(_ deviceToken: Data, pusherBaseURL: URL) async throws {
        registeredTokens.append((deviceToken, pusherBaseURL))
    }

    func unregister(deviceToken: Data, pusherBaseURL: URL) async throws {
        unregisteredTokens.append((deviceToken, pusherBaseURL))
    }
}
