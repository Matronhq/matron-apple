import Foundation
import MatronChat
import MatronShare
import MatronStorage

/// Leaves the conversation list where the share extension can read it.
///
/// The extension runs in its own process, often while the app is suspended
/// and sometimes with no network, so it cannot ask the app and should not
/// have to ask the server before showing anything. The app writes what its
/// own list shows each time it goes to the background, which is the only
/// time the share sheet can be opened from somewhere else.
enum ShareTargetsPublisher {
    static func targets(from summaries: [ChatSummary], coordinatorID: String?) -> [ShareTarget] {
        let targets = summaries.filter { $0.parentConvoID == nil }.map { summary in
            ShareTarget(
                id: summary.id,
                title: summary.title.isEmpty ? "Untitled" : summary.title,
                detail: summary.boxName,
                isCoordinator: summary.id == coordinatorID,
                lastActivity: summary.lastActivity)
        }
        return ShareTargets.ordered(targets)
    }

    /// Writes and clears run in the order they were asked for. Without
    /// this a write still waiting its turn could land after sign-out's
    /// clear and leave the old account's list on disk.
    private static let queue = DispatchQueue(label: "chat.matron.share-targets", qos: .utility)

    static func publish(_ summaries: [ChatSummary], coordinatorID: String?, userID: String,
                        container: URL? = StoragePaths.groupContainer) {
        guard let container else { return }
        // An empty list means the chat list has not loaded yet, not that
        // the account has no conversations worth keeping a list of.
        guard !summaries.isEmpty else { return }
        let targets = targets(from: summaries, coordinatorID: coordinatorID)
        queue.async {
            try? ShareTargetsCache.write(targets, userID: userID, in: container)
        }
    }

    /// Returns once the list is gone, after any write already queued.
    static func clear(container: URL? = StoragePaths.groupContainer) {
        guard let container else { return }
        queue.sync { ShareTargetsCache.clear(in: container) }
    }
}
