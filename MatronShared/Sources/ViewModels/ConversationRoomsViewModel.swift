import Foundation
import MatronModels

/// Drives a chat header's "Rooms · n" control: the agent-chat rooms ONE
/// conversation takes part in (`ConversationRoomsRule`), live off the
/// store's rooms stream. The stream carries every room and re-emits on
/// any room's activity, so `rooms` is only written when this
/// conversation's own list changes.
///
/// Same lifecycle as `SubChatStripViewModel`: hosts record
/// `observationGeneration` after `start()` and tear down with
/// `stop(ifGeneration:)`, so a stale view's `onDisappear` cannot end a
/// successor's stream.
@Observable
@MainActor
public final class ConversationRoomsViewModel {
    public private(set) var rooms: [ConversationRoom] = []

    public let convoID: String
    private let source: @Sendable () -> AsyncStream<[MissionRoom]>
    private var observationTask: Task<Void, Never>?
    public private(set) var observationGeneration: Int = 0

    public init(convoID: String, rooms: @escaping @Sendable () -> AsyncStream<[MissionRoom]>) {
        self.convoID = convoID
        self.source = rooms
    }

    @discardableResult
    public func start() -> Task<Void, Never> {
        observationGeneration += 1
        observationTask?.cancel()
        let source = source
        let convoID = convoID
        let task = Task { [weak self] in
            for await all in source() {
                if Task.isCancelled { return }
                let mine = ConversationRoomsRule.rooms(of: convoID, among: all)
                await MainActor.run {
                    guard let self, self.rooms != mine else { return }
                    self.rooms = mine
                }
            }
        }
        observationTask = task
        return task
    }

    public func stop(ifGeneration generation: Int) {
        guard generation == observationGeneration else { return }
        stop()
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }
}
