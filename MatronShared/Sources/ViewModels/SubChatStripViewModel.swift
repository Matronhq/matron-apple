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
/// Nesting recurses for free at this layer: the `parentConvoID` can itself
/// be a child's id, in which case this VM lists *that* child's children.
///
/// Mirrors `ChatViewModel`'s lifecycle: `start()` returns the observation
/// `Task` so tests can `await task.value`, and SwiftUI hosts call `stop()`
/// from `onDisappear` (no `deinit` cancel — Swift 6 forbids touching
/// `@MainActor` state from a nonisolated `deinit`).
@Observable
@MainActor
public final class SubChatStripViewModel {
    /// Every child of the parent (running and finished), in creation order
    /// (oldest first) — the switcher menu's source.
    public private(set) var children: [SubChatSummary] = []
    /// The subset still running — the sticky strip's source. Empty ⇒ the
    /// strip hides entirely.
    public private(set) var runningChildren: [SubChatSummary] = []

    public let parentConvoID: String
    private let chat: ChatService
    private var observationTask: Task<Void, Never>?

    /// Monotonic token identifying the current observation run; bumped by
    /// every `start()`. This VM is shared per-parent across surfaces (the
    /// parent chat's strip, every child viewer's switcher), and SwiftUI can
    /// run the NEW view's `.task`/`start()` before the OLD view's
    /// `onDisappear` on push navigation — the same remount hazard
    /// `ChatViewModel` guards against. Hosts record the generation after
    /// their `start()` and pass it to `stop(ifGeneration:)` so a stale
    /// surface's teardown can never cancel a successor's fresh stream.
    public private(set) var observationGeneration: Int = 0

    public init(chat: ChatService, parentConvoID: String) {
        self.chat = chat
        self.parentConvoID = parentConvoID
    }

    @discardableResult
    public func start() -> Task<Void, Never> {
        observationGeneration += 1
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

    /// Stops the observation only if `generation` still identifies the
    /// current run — a stale view instance's `onDisappear` (which can fire
    /// AFTER its successor's `start()`) becomes a no-op instead of killing
    /// the shared stream.
    public func stop(ifGeneration generation: Int) {
        guard generation == observationGeneration else { return }
        stop()
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
