import Foundation

/// How current a chooser row's capacity numbers are.
///
/// Deliberately separate from the per-line reset rule
/// (`BoxCapacity.hasReset`): a line can be expired on a box that is answering
/// right now, and a box that has been asleep for an hour can hold lines well
/// inside their window. The two de-emphasise for different reasons, so they
/// caption at different levels — this one once per block, `resetText` once
/// per line — and never restate each other.
public enum AgentCapacityFreshness: Equatable, Sendable {
    /// Fetched from the box during this roster visit.
    case live
    /// Last-known numbers for a box that is offline now, captured at the
    /// given moment. The host suspends idle boxes, so this is the only way
    /// their quota is visible at all.
    case offline(capturedAt: Date)

    /// True when the numbers predate this visit: every percent renders
    /// de-emphasised rather than in the usual green/orange/red, which would
    /// vouch for them as current.
    public var isStale: Bool {
        if case .offline = self { return true }
        return false
    }

    /// Block-level age caption ("offline · as of 2h ago"), or nil for live
    /// numbers. Abbreviated units, the same style as `RecentFolder`'s
    /// last-used captions — this sits under a name line, not on its own.
    public func ageText(now: Date = Date(), locale: Locale = .current) -> String? {
        guard case .offline(let capturedAt) = self else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = locale
        // Clock skew between the box's journal and this device can stamp a
        // capture at or ahead of now. Spelled out rather than handed to the
        // formatter, which renders a zero interval as "in 0s": both that and
        // "as of in 3 hr" read as promises about the future, and this caption
        // exists only to disclaim the past.
        guard capturedAt < now else { return "offline · as of just now" }
        return "offline · as of \(formatter.localizedString(for: capturedAt, relativeTo: now))"
    }
}
