import Foundation

/// Shared relative-date formatters ("5 min. ago", "5 minutes ago").
///
/// Building a `RelativeDateTimeFormatter` loads locale data. Making a new
/// one for every comment caption was a large share of the time a long
/// tracker item took to open on the Mac, so keep one per style here. Each
/// formatter is set up once and never changed afterwards, which is what
/// lets Foundation formatters be shared across threads.
public enum RelativeDates {
    /// "5 min. ago".
    public static let abbreviated = make(.abbreviated)
    /// "5 minutes ago" (also `RelativeDateTimeFormatter`'s default style).
    public static let full = make(.full)
    /// "5 minutes ago" in British English, whatever the device's locale.
    public static let fullBritish = make(.full, locale: Locale(identifier: "en_GB"))

    private static func make(_ style: RelativeDateTimeFormatter.UnitsStyle,
                             locale: Locale? = nil) -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = style
        if let locale { formatter.locale = locale }
        return formatter
    }
}
