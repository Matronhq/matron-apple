import SwiftUI

/// Coarse-grained relative-time label suitable for chat-list rows. Renders:
///
///   - `"now"` when the source is < 1 minute ago
///   - `"Nm"` when < 1 hour
///   - `"Nh"` when < 24 hours
///   - `"Nd"` when < 7 days
///   - localised short date otherwise
///
/// Refreshes itself once a minute via `TimelineView(.periodic)`. Replaces
/// SwiftUI's built-in `Text(date, style: .relative)`, which ticks every
/// second and was distracting on the chat list — minute resolution is the
/// right granularity for "how stale is this conversation."
public struct RelativeMinuteTimeView: View {
    private let source: Date

    public init(_ source: Date) {
        self.source = source
    }

    public var body: some View {
        // Periodic re-evaluation aligned to a minute boundary keeps every
        // row's "5m" → "6m" transition synchronised across the list,
        // instead of each row's clock drifting from its mount time.
        TimelineView(.periodic(from: Self.nextMinuteBoundary(after: Date()), by: 60)) { context in
            Text(Self.format(source, now: context.date))
        }
    }

    private static func nextMinuteBoundary(after date: Date) -> Date {
        let cal = Calendar.current
        var components = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.minute = (components.minute ?? 0) + 1
        return cal.date(from: components) ?? date.addingTimeInterval(60)
    }

    static func format(_ source: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(source)
        if interval < 60 { return "now" }
        if interval < 3600 {
            let m = Int(interval / 60)
            return "\(m)m"
        }
        if interval < 86400 {
            let h = Int(interval / 3600)
            return "\(h)h"
        }
        if interval < 86400 * 7 {
            let d = Int(interval / 86400)
            return "\(d)d"
        }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f.string(from: source)
    }
}
