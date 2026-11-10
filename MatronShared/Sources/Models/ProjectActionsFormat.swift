import Foundation

/// The words of a project page's "···" menu, and of what follows from it.
public enum ProjectActionsFormat {
    public static let addMission = "Add a mission"
    public static let ask = "Ask the Coordinator about this"
    public static let rename = "Rename…"
    public static let mergeInto = "Merge into…"
    public static let close = "Close project…"

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
}
