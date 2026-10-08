import Foundation
import Observation
import MatronModels

/// What the share sheet needs from the outside world. Closures rather than
/// services so a test can stand in for the app group, the network and the
/// item providers without building any of them.
public struct ShareEnvironment: Sendable {
    /// The signed-in session, or nil when the app is signed out.
    public var session: @Sendable () -> UserSession?
    /// The conversation list the app left behind, if any.
    public var cachedTargets: @Sendable (UserSession) -> [ShareTarget]?
    /// A fresh conversation list from the server.
    public var fetchTargets: @Sendable (UserSession) async throws -> [ShareTarget]
    public var makeTransport: @Sendable (UserSession) -> any ShareTransport
    /// Where shared files are copied to. Emptied when the sheet closes.
    public var workDirectory: URL

    public init(
        session: @escaping @Sendable () -> UserSession?,
        cachedTargets: @escaping @Sendable (UserSession) -> [ShareTarget]?,
        fetchTargets: @escaping @Sendable (UserSession) async throws -> [ShareTarget],
        makeTransport: @escaping @Sendable (UserSession) -> any ShareTransport,
        workDirectory: URL
    ) {
        self.session = session
        self.cachedTargets = cachedTargets
        self.fetchTargets = fetchTargets
        self.makeTransport = makeTransport
        self.workDirectory = workDirectory
    }
}

/// Drives the share sheet: what was shared, where it is going, and the send.
@MainActor
@Observable
public final class ShareViewModel {
    public enum Phase: Equatable {
        /// Reading the shared items.
        case loading
        case signedOut
        case ready
        case sending(ShareProgress)
        case sent
    }

    public private(set) var phase: Phase = .loading
    public private(set) var files: [SharedFile] = []
    public var message = ""
    public private(set) var targets: [ShareTarget] = []
    /// True while no conversation list has arrived from anywhere yet.
    public private(set) var isLoadingTargets = false
    public var selectedTargetID: String?
    public var query = ""
    /// A failure to show: an item that could not be read, or a send that
    /// did not go through. The sheet stays open either way.
    public var errorMessage: String?

    @ObservationIgnored private let environment: ShareEnvironment
    @ObservationIgnored private var session: UserSession?
    @ObservationIgnored private var sender: ShareSender?

    public init(environment: ShareEnvironment) {
        self.environment = environment
    }

    public var visibleTargets: [ShareTarget] {
        ShareTargets.filter(targets, query: query)
    }

    public var selectedTarget: ShareTarget? {
        targets.first { $0.id == selectedTargetID }
    }

    public var canSend: Bool {
        guard phase == .ready, selectedTarget != nil else { return false }
        return !files.isEmpty || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Reads the shared items and the conversation list. The list shows as
    /// soon as the cached copy is read; the server's copy replaces it when
    /// it arrives, and a failure to fetch it is silent when there is a
    /// cached list to fall back on.
    public func load(_ providers: [NSItemProvider]) async {
        guard let session = environment.session() else {
            phase = .signedOut
            return
        }
        self.session = session
        if let cached = environment.cachedTargets(session), !cached.isEmpty {
            apply(cached)
        } else {
            isLoadingTargets = true
        }
        let refresh = Task { await refreshTargets(for: session) }

        var texts: [String] = []
        for provider in providers {
            do {
                switch try await ShareItemLoader.load(provider, into: environment.workDirectory) {
                case .file(let file): files.append(file)
                case .text(let text): texts.append(text)
                case nil: break
                }
            } catch {
                if errorMessage == nil { errorMessage = error.localizedDescription }
            }
        }
        if !texts.isEmpty {
            message = texts.joined(separator: "\n")
        }
        phase = .ready
        await refresh.value
    }

    private func refreshTargets(for session: UserSession) async {
        defer { isLoadingTargets = false }
        do {
            apply(try await environment.fetchTargets(session))
        } catch {
            if targets.isEmpty, errorMessage == nil {
                errorMessage = "Couldn't load your conversations. \(error.localizedDescription)"
            }
        }
    }

    /// Takes a new list, keeping the user's pick. With no pick yet the
    /// Coordinator is chosen, as the place things go by default.
    private func apply(_ list: [ShareTarget]) {
        targets = ShareTargets.ordered(list)
        if selectedTarget == nil {
            selectedTargetID = targets.first(where: \.isCoordinator)?.id
        }
    }

    public func removeFile(id: UUID) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        let file = files.remove(at: index)
        try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
    }

    public func send() async {
        guard canSend, let session, let target = selectedTarget else { return }
        let request = ShareRequest(convoID: target.id, message: message, files: files)
        // One sender for the life of the sheet: it remembers what already
        // uploaded, so Send after a failure picks up where it stopped.
        let sender = self.sender ?? ShareSender(transport: environment.makeTransport(session))
        self.sender = sender
        errorMessage = nil
        phase = .sending(ShareProgress(fileIndex: files.isEmpty ? nil : 1, fileCount: files.count,
                                       filename: files.first?.filename, fraction: 0))
        do {
            try await sender.send(request) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, case .sending(let current) = self.phase,
                          progress.fraction >= current.fraction else { return }
                    self.phase = .sending(progress)
                }
            }
            phase = .sent
            cleanUp()
        } catch {
            phase = .ready
            errorMessage = error.localizedDescription
        }
    }

    /// Deletes the copies of the shared files. Called when the sheet
    /// closes, whichever way it closes.
    public func cleanUp() {
        try? FileManager.default.removeItem(at: environment.workDirectory)
    }
}
