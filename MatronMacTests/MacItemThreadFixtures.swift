#if os(macOS)
import Foundation
import MatronDesignSystem
import MatronModels

/// Synthetic item threads for the native Mac item thread's tests.
enum MacItemThreadFixtures {
    static let paragraph = """
        **Done.** The change is on the branch, and here's what moved:

        - The thread reads its attachments' sizes up front, so nothing shifts.
        - A queued reply says so, with a [Send now](https://example.com) button.

        Next I'll run the tests and post the timings here.
        """

    static func comment(_ i: Int, body: String? = nil, author: ItemAuthor? = nil,
                        attachments: [TrackerAttachment] = [], kind: TrackerComment.Kind = .comment,
                        itemID: String = "it_fx") -> TrackerComment {
        TrackerComment(id: "c\(i)", itemID: itemID, author: author ?? (i % 3 == 0 ? .user : .agent), kind: kind,
                       body: body ?? "Comment \(i). " + paragraph, attachments: attachments,
                       createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60))
    }

    static func image(_ ref: String, width: Int = 1600, height: Int = 1000) -> TrackerAttachment {
        TrackerAttachment(blobRef: ref, mime: "image/png", name: "\(ref).png", size: 1000, width: width, height: height)
    }

    static func model(id: String = "it_fx", comments count: Int, body: String = paragraph, title: String = "A thread",
                      extra: [TrackerComment] = [], working: Bool = false) -> ItemDetailView.Model {
        let item = TrackerItem(id: id, num: 1, kind: .task, title: title, body: body, originConvoID: "c1")
        let comments = (0..<count).map { comment($0, itemID: id) } + extra
        var model = ItemDetailView.Model(item: item, comments: comments, pending: [], availableResolutions: [.done],
                                         isBusy: false, loadedCommentCount: comments.count)
        if working { model.working = .working }
        return model
    }
}
#endif
