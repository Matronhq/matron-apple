import SwiftUI

/// Pure formatting for the usage/context meters — kept off the views so
/// the label mapping, countdown wording, and thresholds unit-test without
/// rendering. Thresholds mirror the bridge's /usage colors (usage-limits.js
/// percentColor): green < 50, orange < 80, red >= 80.
public enum UsageMetersFormat {
    /// 265_400 -> "265k", 1_000_000 -> "1m", 1_500_000 -> "1.5m".
    public static func compactTokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        let millions = (Double(n) / 1_000_000 * 10).rounded() / 10
        return millions == millions.rounded()
            ? "\(Int(millions))m"
            : String(format: "%.1fm", millions)
    }

    /// VoiceOver variant: "265 thousand", "1 million".
    public static func spokenTokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return "\(Int((Double(n) / 1000).rounded())) thousand" }
        let millions = (Double(n) / 1_000_000 * 10).rounded() / 10
        return millions == millions.rounded()
            ? "\(Int(millions)) million"
            : String(format: "%.1f million", millions)
    }

    /// "Session" -> "Session"; "Week (all models)" -> "Week"; any other
    /// label ending in a parenthesized name -> the inner name, so a model
    /// rename upstream never needs an app change.
    public static func barLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"),
              let open = trimmed.range(of: "(", options: .backwards)
        else { return trimmed }
        let inner = String(trimmed[open.upperBound..<trimmed.index(before: trimmed.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return trimmed }
        return inner.lowercased() == "all models"
            ? String(trimmed[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
            : inner
    }

    public static func barColor(percent: Int) -> Color {
        if percent < 50 { return .green }
        if percent < 80 { return .orange }
        return .red
    }

    /// Reset time for a bar's trailing text. Near resets read as a
    /// countdown, far ones as local weekday + hour; no timestamp falls
    /// back to the raw text the bridge scraped.
    public static func resetDisplay(resetsAt: Date?, raw: String?, now: Date, timeZone: TimeZone = .current) -> String? {
        guard let resetsAt else { return raw }
        let interval = resetsAt.timeIntervalSince(now)
        if interval < 60 { return "now" }
        let totalMinutes = Int(interval / 60)
        if interval < 3600 { return "\(totalMinutes)m" }
        if interval < 6 * 3600 {
            return String(format: "%dh%02d", totalMinutes / 60, totalMinutes % 60)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        formatter.dateFormat = "EEE ha"
        return formatter.string(from: resetsAt)
    }
}
