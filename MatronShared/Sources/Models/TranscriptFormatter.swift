import Foundation

/// One line of a copied transcript: who said what, when.
public struct TranscriptEntry: Equatable, Sendable {
    public let timestamp: Date
    public let name: String
    public let text: String

    public init(timestamp: Date, name: String, text: String) {
        self.timestamp = timestamp
        self.name = name
        self.text = text
    }
}

/// WhatsApp-style transcript text:
///
/// ```
/// [05/09/2026, 14:33] Claude: line 42 expects
/// the fixture is unsorted
/// [05/09/2026, 14:35] Me: ok, fix
/// ```
///
/// Date and time follow the locale's short styles (so the user's pasted
/// text reads like their other apps); multi-line bodies continue on their
/// own lines unprefixed; entries are joined by one newline with no
/// trailing newline. Pure and cross-platform — the Mac cross-message copy
/// is the first consumer.
public enum TranscriptFormatter {
    public static func format(
        _ entries: [TranscriptEntry],
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard !entries.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return entries.map { entry in
            let stamp = formatter.string(from: entry.timestamp)
            let body = trimNewlines(entry.text)
            return "[\(stamp)] \(entry.name): \(body)"
        }.joined(separator: "\n")
    }

    /// Trims leading/trailing line breaks only — inner spaces and indents
    /// are part of the message (code, lists) and are kept verbatim.
    private static func trimNewlines(_ text: String) -> String {
        var scalars = Substring(text)
        while let first = scalars.first, first.isNewline { scalars = scalars.dropFirst() }
        while let last = scalars.last, last.isNewline { scalars = scalars.dropLast() }
        return String(scalars)
    }
}
