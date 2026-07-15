import Foundation
import MatronChat

/// Drives the parent chat's running-subagent strip and the sub-chat
/// switcher menu. Subscribes to `ChatService.children(of:)` for one parent
/// conversation and republishes the latest snapshot, split into "all
/// children" (switcher) and "running children" (the sticky strip).
///
/// Deliberately tiny: the strip and switcher are pure reads of the child
/// list; identity + label + running-state is all they need. The child's
/// model / context gauge come from the per-convo session-status stream the
/// sub-chat viewer's own `ChatViewModel` already subscribes to.
///
/// Nesting recurses for free: the `parentConvoID` can itself be a child's
/// id, so a sub-chat that spawns its own subagents shows its own strip.
///
/// Mirrors `ChatViewModel`'s lifecycle: `start()` returns the observation
/// `Task` so tests can `await task.value`, and SwiftUI hosts call `stop()`
/// from `onDisappear` (no `deinit` cancel — Swift 6 forbids touching
/// `@MainActor` state from a nonisolated `deinit`).
@Observable
@MainActor
public final class SubChatStripViewModel {
    /// Every child of the parent (running and finished), newest-created
    /// first — the switcher menu's source.
    public private(set) var children: [SubChatSummary] = []
    /// The subset still running — the sticky strip's source. Empty ⇒ the
    /// strip hides entirely.
    public private(set) var runningChildren: [SubChatSummary] = []

    public let parentConvoID: String
    private let chat: ChatService
    private var observationTask: Task<Void, Never>?

    public init(chat: ChatService, parentConvoID: String) {
        self.chat = chat
        self.parentConvoID = parentConvoID
    }

    @discardableResult
    public func start() -> Task<Void, Never> {
        observationTask?.cancel()
        let chat = chat
        let parentConvoID = parentConvoID
        let task = Task { [weak self] in
            for await snapshot in chat.children(of: parentConvoID) {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    self.children = snapshot
                    self.runningChildren = snapshot.filter(\.isRunning)
                }
            }
        }
        observationTask = task
        return task
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// The running child to preselect when the strip has exactly one — a
    /// convenience for the common single-subagent case. `nil` when there
    /// are none or several (the caller shows the full strip instead).
    public var soleRunningChild: SubChatSummary? {
        runningChildren.count == 1 ? runningChildren.first : nil
    }
}
