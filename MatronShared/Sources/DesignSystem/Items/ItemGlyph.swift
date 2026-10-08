import SwiftUI
import Foundation
import MatronModels

public enum ItemGlyph {
    public static func symbol(_ kind: ItemKind) -> String {
        switch kind {
        case .question: return "questionmark.circle.fill"; case .task: return "checklist"; case .decision: return "scalemass.fill"
        case .notice: return "eye"
        }
    }
    public static func tint(_ kind: ItemKind) -> Color {
        switch kind {
        case .question: return .orange; case .task: return .accentColor; case .decision: return .purple
        case .notice: return .secondary
        }
    }
    public static func label(_ kind: ItemKind) -> String {
        switch kind {
        case .question: return "Question"; case .task: return "Task"; case .decision: return "Decision"
        case .notice: return "To read"
        }
    }
    public static func label(_ r: ItemResolution) -> String {
        switch r { case .done: return "Done"; case .answered: return "Answered"; case .decided: return "Decided"; case .reversed: return "Reversed"; case .cancelled: return "Cancelled" }
    }

    /// "Answered · 2h ago" — the Decisions view's "Decided" section caption:
    /// the resolution plus a relative read on when it
    /// closed. `nil` for anything not actually closed. Falls back to
    /// "Closed · 2h ago" when the item has no `resolution` (review,
    /// 2026-09-29: a `nil` resolution used to render no caption at all,
    /// making a closed item indistinguishable from an open one with no
    /// badge). `now` is a parameter (not `Date()`) so callers stay
    /// deterministic for snapshot tests, the same discipline
    /// `ItemDetailView.relativeDate`/`MemoriesListView.relative` already
    /// use for comment/memory timestamps.
    public static func closedCaption(_ item: TrackerItem, at date: Date? = nil, now: Date) -> String? {
        guard item.state == .closed else { return nil }
        let resolutionLabel = item.resolution.map(label) ?? "Closed"
        return "\(resolutionLabel) \u{00B7} \(relativeTime(date ?? item.closedAt ?? item.updatedAt, now: now))"
    }

    /// Abbreviated relative time ("2h ago"), falling back to a short
    /// absolute date once `date` is more than 7 days before `now` —
    /// mirrors `ItemDetailView.relativeDate`'s own cutoff, restated here
    /// since that one is `private` to its view.
    private static func relativeTime(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        if now.timeIntervalSince(date) > sevenDays {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
