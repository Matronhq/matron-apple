import Foundation

/// Another person's shareable link (`https://<journal>/u/<them>/<n>`), as
/// the read-only viewer shows it. The journal answers such a link for a row
/// that person shares with the signed-in user (the same organisation, or a
/// mission they granted); anything else is one "not shared" answer.
public struct SharedTrackerPreview: Equatable, Sendable {
    /// One comment under an item, or one milestone on a mission.
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: String
        public let heading: String
        public let body: String
        public let date: Date

        public init(id: String, heading: String, body: String, date: Date) {
            self.id = id; self.heading = heading; self.body = body; self.date = date
        }
    }

    public let owner: String
    /// "Question", "Mission", …
    public let kindLabel: String
    public let num: Int
    public let title: String
    /// "Open", "Closed · answered", …
    public let status: String
    public let body: String
    /// "Comments" or "Milestones"; `nil` with no entries.
    public let entriesHeading: String?
    public let entries: [Entry]

    public init(owner: String, kindLabel: String, num: Int, title: String, status: String,
                body: String, entriesHeading: String?, entries: [Entry]) {
        self.owner = owner; self.kindLabel = kindLabel; self.num = num; self.title = title
        self.status = status; self.body = body; self.entriesHeading = entriesHeading; self.entries = entries
    }

    /// "Question #412 · bob's tracker"
    public var heading: String { "\(kindLabel) #\(num) · \(owner)'s tracker" }
}

public enum SharedTrackerLinkState: Equatable, Sendable {
    case loading
    case loaded(SharedTrackerPreview)
    /// Nothing under that number is shared with the user, or the person
    /// does not exist on this journal: the journal does not say which.
    case notShared
    /// A project, which is never shared, or a kind this build cannot show.
    case unsupported(kindLabel: String)
    case failed
}
