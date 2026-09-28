import Foundation
import MatronModels

/// The dashboard's words (spec 2026-09-28 §3.2 / §3.4), pure so each is a
/// plain test and the cards never disagree.
public enum MissionsDashboardFormat {
    /// "just now", "12m ago", "3h ago", "2d ago", then "on <date>" —
    /// `RelativeMinuteTimeView`'s buckets, worded for a sentence.
    public static func relative(_ date: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "just now" }
        let short = RelativeMinuteTimeView.format(date, now: now)
        return interval < 86_400 * 7 ? "\(short) ago" : "on \(short)"
    }

    /// "Updated 12m ago by an agent" / "… by you"; nil when unset.
    public static func statusByline(updatedAt: Date?, by author: ItemAuthor?, now: Date) -> String? {
        guard let updatedAt else { return nil }
        let who: String
        switch author {
        case .user: who = " by you"
        case .agent: who = " by an agent"
        case nil: who = ""
        }
        return "Updated \(relative(updatedAt, now: now))\(who)"
    }

    public static func askedLabel(askedAt: Date, now: Date) -> String {
        "Asked \(relative(askedAt, now: now))"
    }

    public static func moreSessions(_ count: Int) -> String {
        "+\(count) more session\(count == 1 ? "" : "s")"
    }

    /// Inline-only markdown: bold, code and links render, but nothing is
    /// read as a block — so `[blocked]: waiting on Dan` (a CommonMark link
    /// reference definition, which renders as nothing) stays visible.
    public static func statusText(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}
