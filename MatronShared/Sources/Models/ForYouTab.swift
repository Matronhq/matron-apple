import Foundation

/// The For you list's tabs: what still needs the user, the questions,
/// decisions and notices that are closed, and the spare-allowance backlog
/// (open tasks labelled `spare-allowance`, next first). Not persisted: the
/// list opens on `.open` every launch, since that is the working list.
public enum ForYouTab: String, CaseIterable, Sendable {
    case open, closed, spare

    public var title: String {
        switch self {
        case .open: "Needs you"
        case .closed: "Done"
        case .spare: "Spare allowance"
        }
    }
}
