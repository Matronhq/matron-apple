import SwiftUI
import MatronModels

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

    /// Fill width for a usage bar, proportional with two perceptual
    /// guards sized to the capsule height: a bar that isn't exhausted
    /// never renders flush-full — below 100% the fill leaves at least one
    /// capsule-height of track visible, so 90–95% stops reading as "all
    /// gone" (only a true 100% touches the far edge) — and a nonzero
    /// percent renders at least the capsule's own diameter, below which
    /// the shape distorts.
    public static func barFillWidth(percent: Int, barWidth: CGFloat, barHeight: CGFloat) -> CGFloat {
        let clamped = min(max(percent, 0), 100)
        guard clamped > 0 else { return 0 }
        guard clamped < 100 else { return barWidth }
        let proportional = barWidth * CGFloat(clamped) / 100
        return min(max(proportional, barHeight), barWidth - barHeight)
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
    /// Abbreviate a BRIDGE-machine path's home prefix to "~". Textual only —
    /// the path belongs to the bridge host, so FileManager's local home
    /// would be the wrong machine. Handles the two layouts bridges run on
    /// (macOS /Users/<name>, Linux /home/<name>); anything else passes
    /// through untouched.
    public static func homeAbbreviated(_ path: String) -> String {
        for prefix in ["/Users/", "/home/"] where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            guard !rest.isEmpty else { return path }
            if let slash = rest.firstIndex(of: "/") {
                return "~" + rest[slash...]
            }
            return "~"
        }
        return path
    }

    /// "CPU 12% · RAM 63%" — the bridge host's vitals as one quiet caption
    /// line. Either half can be missing (CPU needs two sampler ticks after
    /// a bridge boot); nil when neither is known so callers drop the line.
    public static func vitalsLine(_ vitals: SessionStatus.Vitals) -> String? {
        var parts: [String] = []
        if let cpu = vitals.cpuPct { parts.append("CPU \(cpu)%") }
        if let ram = vitals.ramPct { parts.append("RAM \(ram)%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "opus" / "opus · high" — the session's model with its effort level
    /// beside it. An unknown effort adds nothing at all: no separator, no
    /// placeholder, nothing for a layout to reserve space for. The bridge
    /// publishes no effort rather than a guess, so absent is the normal
    /// state and must read as normal.
    public static func modelLine(model: String, effort: String?) -> String {
        guard let effort = effort?.trimmingCharacters(in: .whitespaces), !effort.isEmpty
        else { return model }
        return "\(model) · \(effort)"
    }

}
