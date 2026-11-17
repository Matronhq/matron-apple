import Foundation
import Network

/// The engine's view of the network path, behind a seam so a test can drive
/// it. The system implementation wraps `NWPathMonitor`; nothing else in the
/// engine touches the Network framework.
public protocol NetworkPathMonitoring: AnyObject, Sendable {
    /// Starts reporting. `onUpdate` receives whether the path is usable and a
    /// signature (status plus sorted interface names) that is equal for two
    /// callbacks describing the same path. The first callback reports the
    /// current path.
    func start(onUpdate: @escaping @Sendable (_ satisfied: Bool, _ signature: String) -> Void)
    func cancel()
}

/// The real monitor: an `NWPathMonitor` on its own queue.
public final class SystemNetworkPathMonitor: NetworkPathMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()

    public init() {}

    public func start(onUpdate: @escaping @Sendable (_ satisfied: Bool, _ signature: String) -> Void) {
        monitor.pathUpdateHandler = { path in
            let signature = "\(path.status)|\(path.availableInterfaces.map(\.name).sorted().joined(separator: ","))"
            onUpdate(path.status == .satisfied, signature)
        }
        monitor.start(queue: DispatchQueue(label: "chat.matron.journal.path-monitor"))
    }

    public func cancel() {
        monitor.cancel()
    }
}
