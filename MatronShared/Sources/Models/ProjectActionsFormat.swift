import Foundation

/// The words of a project page's "···" menu, and of what follows from it.
public enum ProjectActionsFormat {
    public static let addMission = "Add a mission"
    public static let ask = "Ask the Coordinator about this"
    /// The entry once the question was sent from this page.
    public static let asked = "Asked the Coordinator"
    public static let rename = "Rename…"
    public static let mergeInto = "Merge into…"
    public static let close = "Close project…"

    /// The Ask entry's words: what it offers, or that it was sent.
    public static func askLabel(asked: Bool) -> String { asked ? Self.asked : ask }

    /// What "Ask the Coordinator about this" sends.
    public static func askMessage(title: String) -> String {
        "Tell me about the project “\(title)”: where it is and what is next."
    }

    /// Asked before a project is closed.
    public static func closeConfirmation(title: String) -> String {
        "Close “\(title)”? Its missions stay as they are."
    }

    /// The summary the journal records with a close made from the app.
    public static let closeSummary = "Closed from the app."

    /// Said when the journal refuses to close a project over its open missions.
    public static let openMissions = "This project still has open missions. Close or move them first."

    /// Said when a rename or a close reaches a project that is not open.
    public static let notOpen = "This project is closed, so it can't be changed."
}

/// Which of a project page's "···" entries can be chosen. The writes need
/// an open project and its missions and projects loaded; a list with
/// nothing in it is a dimmed entry, never a submenu that opens empty.
public struct ProjectActionsAvailability: Equatable, Sendable {
    /// "Add a mission" opens its list of missions in no project.
    public let addMission: Bool
    public let rename: Bool
    /// "Merge into…" opens its list of the other open projects.
    public let merge: Bool
    public let close: Bool

    /// `isOpen`: the project is open (not closed or finished). `isLoaded`:
    /// the project's missions and the other projects have been read.
    public init(isOpen: Bool, isLoaded: Bool, hasUnfiled: Bool, hasMergeTargets: Bool) {
        let writable = isOpen && isLoaded
        addMission = writable && hasUnfiled
        rename = writable
        merge = writable && hasMergeTargets
        close = writable
    }
}
