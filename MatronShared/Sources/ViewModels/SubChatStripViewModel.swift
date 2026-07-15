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

    // MARK: - Subtask-message linking

    /// The bridge announces every Task/Agent tool call in the parent
    /// timeline as a plain text message `🔀 Subtask: <description>` — with
    /// no machine-readable link to the child conversation it spawns (the
    /// linking `task_ref` only rides the CHILD's status frames). Until the
    /// bridge publishes a structured event, these two helpers make those
    /// messages tappable: parse the indicator, then match it to a child by
    /// title (the child's title is the same watcher label the indicator's
    /// description came from).
    nonisolated private static let subtaskIndicatorPrefix = "🔀 Subtask: "

    /// The description carried by a bridge subtask-indicator message, or
    /// `nil` when `body` isn't one. The indicator is always the whole
    /// message (modulo surrounding whitespace), never an infix.
    nonisolated public static func subtaskDescription(fromMessageBody body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(subtaskIndicatorPrefix) else { return nil }
        let description = trimmed.dropFirst(subtaskIndicatorPrefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? nil : description
    }

    /// The child conversation a subtask indicator most plausibly refers to.
    /// The bridge truncates the indicator's description to 80 chars while
    /// the child title is the full label, so a prefix match is accepted.
    /// Duplicate titles (the same agent re-run) tie-break by preferring a
    /// still-running child, then the newest — `children` arrives in
    /// creation order, so `last` is the most recent spawn, which is the
    /// likeliest referent when the user taps a fresh indicator.
    nonisolated public static func resolveSubtaskTarget(
        description: String,
        among children: [SubChatSummary]
    ) -> SubChatSummary? {
        let matches = children.filter {
            $0.title == description || $0.title.hasPrefix(description)
        }
        return matches.last(where: \.isRunning) ?? matches.last
    }

    /// The navigation path after switching the OPEN sub-chat viewer from
    /// `current` to `sibling`: replace the stack tail (pop-then-push) so
    /// hopping between siblings doesn't grow the back stack — back always
    /// returns to the parent chat. `nil` means no navigation is needed
    /// (tapping the already-open child). Falls back to a plain push when
    /// the tail isn't `current` (defensive — shouldn't happen).
    nonisolated public static func pathReplacingCurrentChild(
        in path: [String],
        current: String,
        with sibling: String
    ) -> [String]? {
        guard sibling != current else { return nil }
        var newPath = path
        if newPath.last == current { newPath.removeLast() }
        newPath.append(sibling)
        return newPath
    }
}
