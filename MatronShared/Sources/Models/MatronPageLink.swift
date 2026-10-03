import Foundation

/// A mission or project page named by its human-facing number — what a
/// `[#61](matron://mission/61)` or `[Promo](matron://project/12)` link in a
/// status or a message body points at. The number is resolved to a local id
/// before anything navigates (`PageLinkResolver`).
public enum MatronPageLink: Hashable, Sendable {
    case mission(Int)
    case project(Int)

    public var num: Int {
        switch self {
        case .mission(let num), .project(let num): return num
        }
    }

    /// "mission" / "project", for a message about the link.
    public var noun: String {
        switch self {
        case .mission: return "mission"
        case .project: return "project"
        }
    }
}

/// The page a resolved `MatronPageLink` opens, by its local id.
public enum MatronPageTarget: Hashable, Sendable {
    case mission(id: String)
    case project(id: String)
}
