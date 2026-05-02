import Foundation
import MatrixRustSDK
import MatronModels

public actor SyncServiceLive: SyncService {
    private let provider: ClientProvider
    private let session: UserSession
    private var sdkSyncService: MatrixRustSDK.SyncService?
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
        await svc.start()
        sdkSyncService = svc
        ready = true
        let waiters = readyContinuations
        readyContinuations.removeAll()
        for cont in waiters { cont.resume() }
    }

    public func stop() async {
        if let svc = sdkSyncService {
            await svc.stop()
        }
        sdkSyncService = nil
        ready = false
    }

    public var isRunning: Bool { sdkSyncService != nil }

    public func waitUntilReady() async throws {
        if ready { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            readyContinuations.append(cont)
        }
    }

    /// Returns the underlying SDK SyncService. Used by ChatServiceLive to
    /// obtain a RoomListService once start() has completed.
    func sdkService() async -> MatrixRustSDK.SyncService? {
        sdkSyncService
    }
}
