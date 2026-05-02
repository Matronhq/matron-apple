import Foundation
import MatrixRustSDK
import MatronModels

/// Errors thrown by `SyncServiceLive.waitUntilReady()` when sync fails to
/// reach `.running` within a reasonable window.
public enum SyncReadyError: Error, Equatable {
    case timeout
    case terminated
    case errored
}

public actor SyncServiceLive: SyncService {
    /// How long `waitUntilReady()` will wait before throwing `.timeout`. Set
    /// to a generous bound so a slow first sync against a real homeserver
    /// still resolves; long enough that an unreachable server surfaces an
    /// error rather than a perpetual "Connecting…" spinner.
    public static let readyTimeout: TimeInterval = 30

    private let provider: ClientProvider
    private let session: UserSession
    private var sdkSyncService: MatrixRustSDK.SyncService?
    private var stateHandle: TaskHandle?
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private var ready: Bool = false
    /// Once we've ever reached `.running`, terminal states like `.error` /
    /// `.terminated` won't fail subsequent waiters — the SDK auto-recovers.
    /// Until then, terminal states are surfaced as thrown errors so the UI
    /// doesn't hang on "Connecting…".
    private var hasEverBeenRunning: Bool = false

    public init(provider: ClientProvider, session: UserSession) {
        self.provider = provider
        self.session = session
    }

    public func start() async throws {
        guard sdkSyncService == nil else { return }
        let client = try await provider.client(for: session)
        let svc = try await client.syncService().finish()

        // Attach state observer BEFORE start so we don't miss the .running
        // transition. Calling RoomListService methods before .running crashes
        // BaseStateStore::rooms_stream because the state store hasn't been
        // populated yet.
        let observer = StateObserver { [weak self] state in
            guard let self else { return }
            Task { await self.handleStateChange(state) }
        }
        stateHandle = svc.state(listener: observer)
        await svc.start()
        sdkSyncService = svc
    }

    public func stop() async {
        if let svc = sdkSyncService {
            await svc.stop()
        }
        sdkSyncService = nil
        stateHandle = nil
        ready = false
    }

    public var isRunning: Bool { sdkSyncService != nil }

    public func waitUntilReady() async throws {
        if ready { return }
        // Spawn a watchdog that fails any waiter still in the queue after the
        // timeout window expires. Cancelled if .running fires first.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.readyTimeout * 1_000_000_000))
            await self?.failPendingWaiters(with: SyncReadyError.timeout)
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            readyContinuations.append(cont)
        }
    }

    public func sdkService() -> MatrixRustSDK.SyncService? {
        sdkSyncService
    }

    private func handleStateChange(_ state: SyncServiceState) {
        switch state {
        case .running:
            hasEverBeenRunning = true
            guard !ready else { return }
            ready = true
            let waiters = readyContinuations
            readyContinuations.removeAll()
            for cont in waiters { cont.resume() }
        case .error:
            // Only fail pending waiters if we've never seen .running yet —
            // mid-session blips auto-recover and shouldn't break the UI.
            if !hasEverBeenRunning {
                failPendingWaiters(with: SyncReadyError.errored)
            }
        case .terminated:
            if !hasEverBeenRunning {
                failPendingWaiters(with: SyncReadyError.terminated)
            }
        case .offline, .idle:
            // Don't surface these — sliding sync auto-recovers from .offline
            // and .idle is a transient pre-running state.
            break
        }
    }

    private func failPendingWaiters(with error: Error) {
        let waiters = readyContinuations
        readyContinuations.removeAll()
        for cont in waiters { cont.resume(throwing: error) }
    }
}

private final class StateObserver: SyncServiceStateObserver {
    private let onState: @Sendable (SyncServiceState) -> Void
    init(_ onState: @escaping @Sendable (SyncServiceState) -> Void) { self.onState = onState }
    func onUpdate(state: SyncServiceState) { onState(state) }
}
