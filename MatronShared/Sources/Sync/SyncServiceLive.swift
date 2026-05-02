import Foundation
import MatrixRustSDK
import MatronModels

public actor SyncServiceLive: SyncService {
    private let provider: ClientProvider
    private let session: UserSession
    private var sdkSyncService: MatrixRustSDK.SyncService?
    private var stateHandle: TaskHandle?
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private var ready: Bool = false

    public init(provider: ClientProvider, session: UserSession) {
        self.provider = provider
        self.session = session
    }

    public func start() async throws {
        guard sdkSyncService == nil else { return }
        let client = try await provider.client(for: session)
        let svc = try await client.syncService().finish()

        // Attach state observer BEFORE start so we don't miss the .running
        // transition. The observer flips `ready` when the SDK reports it has
        // received an actual sync response — calling RoomListService methods
        // before that point crashes BaseStateStore::rooms_stream because the
        // state store hasn't been populated yet.
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
            guard !ready else { return }
            ready = true
            let waiters = readyContinuations
            readyContinuations.removeAll()
            for cont in waiters { cont.resume() }
        case .error, .terminated, .offline, .idle:
            // Don't surface to waiters yet — sliding sync auto-recovers from
            // .offline/.error via the SDK's internal retry. Phase 3+ may add
            // explicit error reporting here.
            break
        }
    }
}

private final class StateObserver: SyncServiceStateObserver {
    private let onState: @Sendable (SyncServiceState) -> Void
    init(_ onState: @escaping @Sendable (SyncServiceState) -> Void) { self.onState = onState }
    func onUpdate(state: SyncServiceState) { onState(state) }
}
