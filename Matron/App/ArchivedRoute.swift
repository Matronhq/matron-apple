import Foundation

/// The Archived screen as a stack entry on the Conversations tab. A fixed
/// entry, not a `PathPrefixedRoute`: it carries no id.
enum ArchivedRoute {
    static let list = "archived/"
}
