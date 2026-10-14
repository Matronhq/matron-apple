import Foundation

/// What a shareable tracker link's number (`https://<journal>/u/<user>/<n>`)
/// turned out to be, for the opener: an item or page to open in-app, or
/// the web page when the app cannot show it (an older journal's milestone,
/// a number that names nothing, a failed lookup — the journal's page says
/// what happened).
public enum TrackerNumberLinkTarget: Equatable, Sendable {
    case item(Int)
    case page(MatronPageLink)
    case web
}
