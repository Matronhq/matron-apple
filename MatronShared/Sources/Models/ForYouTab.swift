import Foundation

/// The For you list's two tabs: what still needs the user, and the
/// questions and decisions that are closed. Not persisted: the list opens
/// on `.open` every launch, since that is the working list.
public enum ForYouTab: String, CaseIterable, Sendable {
    case open, closed

    public var title: String {
        switch self {
        case .open: "Needs you"
        case .closed: "Done"
        }
    }
}
