import SwiftUI

/// Pure formatter for the date-separator label shown between message
/// clusters from different days. Split out as a static helper so the
/// labelling logic is unit-testable without driving SwiftUI.
///
/// Output rules (matches Element / Telegram / iMessage conventions so
/// the timeline reads natively to anyone moving between chat apps):
///   * Same calendar day as `now` → "Today"
///   * Previous calendar day → "Yesterday"
///   * Inside the trailing 7 days → weekday name ("Tuesday")
///   * Older → localised medium-style date ("5 Mar 2026")
///
/// `calendar` is injected so tests can pin a deterministic timezone /
/// locale instead of relying on the host runtime.
public enum DateSeparatorLabel {
    public static func format(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }

        // Within the trailing week → weekday name. We compare the
        // *start* of each calendar day so a separator written at 23:59
        // still resolves to the right weekday for events earlier the
        // same day; the raw `Date` arithmetic would otherwise drift by
        // up to 24h either side of the boundary.
        let startOfNow = calendar.startOfDay(for: now)
        let startOfThen = calendar.startOfDay(for: date)
        if let days = calendar.dateComponents([.day], from: startOfThen, to: startOfNow).day,
           days > 0, days < 7 {
            let f = DateFormatter()
            f.calendar = calendar
            f.locale = calendar.locale ?? .current
            f.timeZone = calendar.timeZone
            f.setLocalizedDateFormatFromTemplate("EEEE")
            return f.string(from: date)
        }

        // Older — localised short date. `medium` (e.g. "5 Mar 2026")
        // reads naturally in every locale; `short` collapses to digits
        // ("3/5/26") which loses the month context the reader needs to
        // tell apart events from the same week-of-month last year.
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = calendar.locale ?? .current
        f.timeZone = calendar.timeZone
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}

/// Centred capsule label shown between message clusters from different
/// days. Visual weight is deliberately subdued — a separator is a
/// reading aid, not a notification — so it sits behind a translucent
/// material with caption-grade typography.
public struct DateSeparator: View {
    private let label: String

    public init(label: String) {
        self.label = label
    }

    /// Convenience initialiser that resolves the label via
    /// `DateSeparatorLabel.format(_:now:calendar:)`. Keeps call sites
    /// terse for the common case where the caller doesn't need to
    /// override `now` or `calendar`.
    public init(date: Date, now: Date = .now, calendar: Calendar = .current) {
        self.label = DateSeparatorLabel.format(date, now: now, calendar: calendar)
    }

    public var body: some View {
        HStack {
            Spacer()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
