import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

final class UsageMetersFormatTests: XCTestCase {
    func testCompactTokens() {
        XCTAssertEqual(UsageMetersFormat.compactTokens(0), "0")
        XCTAssertEqual(UsageMetersFormat.compactTokens(999), "999")
        XCTAssertEqual(UsageMetersFormat.compactTokens(1_000), "1k")
        XCTAssertEqual(UsageMetersFormat.compactTokens(265_400), "265k")
        XCTAssertEqual(UsageMetersFormat.compactTokens(999_500), "1000k")
        XCTAssertEqual(UsageMetersFormat.compactTokens(200_000), "200k")
        XCTAssertEqual(UsageMetersFormat.compactTokens(1_000_000), "1m")
        XCTAssertEqual(UsageMetersFormat.compactTokens(1_500_000), "1.5m")
    }

    func testSpokenTokens() {
        XCTAssertEqual(UsageMetersFormat.spokenTokens(265_400), "265 thousand")
        XCTAssertEqual(UsageMetersFormat.spokenTokens(1_000_000), "1 million")
        XCTAssertEqual(UsageMetersFormat.spokenTokens(1_500_000), "1.5 million")
        XCTAssertEqual(UsageMetersFormat.spokenTokens(500), "500")
    }

    func testBarLabelMapping() {
        XCTAssertEqual(UsageMetersFormat.barLabel("Session"), "Session")
        XCTAssertEqual(UsageMetersFormat.barLabel("Week (all models)"), "Week")
        XCTAssertEqual(UsageMetersFormat.barLabel("Week (Fable)"), "Fable")
        XCTAssertEqual(UsageMetersFormat.barLabel("Week (Sonnet 5)"), "Sonnet 5")
        XCTAssertEqual(UsageMetersFormat.barLabel("Something else"), "Something else")
        XCTAssertEqual(UsageMetersFormat.barLabel(""), "")
    }

    func testBarColorThresholds() {
        XCTAssertEqual(UsageMetersFormat.barColor(percent: 0), .green)
        XCTAssertEqual(UsageMetersFormat.barColor(percent: 49), .green)
        XCTAssertEqual(UsageMetersFormat.barColor(percent: 50), .orange)
        XCTAssertEqual(UsageMetersFormat.barColor(percent: 79), .orange)
        XCTAssertEqual(UsageMetersFormat.barColor(percent: 80), .red)
        XCTAssertEqual(UsageMetersFormat.barColor(percent: 100), .red)
    }

    func testBarFillWidth() {
        // Compact scale: 90pt bar, 3pt capsule.
        XCTAssertEqual(UsageMetersFormat.barFillWidth(percent: 0, barWidth: 90, barHeight: 3), 0)
        XCTAssertEqual(UsageMetersFormat.barFillWidth(percent: 50, barWidth: 90, barHeight: 3), 45)
        // Nonzero fills never shrink below the capsule's own diameter.
        XCTAssertEqual(UsageMetersFormat.barFillWidth(percent: 1, barWidth: 90, barHeight: 3), 3)
        // Near-full bars keep a capsule-height sliver of track visible —
        // 95% of 90pt is 85.5pt but caps at 87pt.
        XCTAssertEqual(UsageMetersFormat.barFillWidth(percent: 95, barWidth: 90, barHeight: 3), 85.5)
        XCTAssertEqual(UsageMetersFormat.barFillWidth(percent: 99, barWidth: 90, barHeight: 3), 87)
        // Only a true 100% (or beyond) touches the far edge.
        XCTAssertEqual(UsageMetersFormat.barFillWidth(percent: 100, barWidth: 90, barHeight: 3), 90)
        XCTAssertEqual(UsageMetersFormat.barFillWidth(percent: 120, barWidth: 90, barHeight: 3), 90)
        XCTAssertEqual(UsageMetersFormat.barFillWidth(percent: -5, barWidth: 90, barHeight: 3), 0)
        // Regular scale: 160pt bar, 6pt capsule — cap is 154pt.
        XCTAssertEqual(UsageMetersFormat.barFillWidth(percent: 99, barWidth: 160, barHeight: 6), 154)
    }

    func testResetDisplay() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let utc = TimeZone(identifier: "UTC")!

        // No timestamp -> raw fallback (nil raw -> nil).
        XCTAssertEqual(UsageMetersFormat.resetDisplay(resetsAt: nil, raw: "soon", now: now), "soon")
        XCTAssertNil(UsageMetersFormat.resetDisplay(resetsAt: nil, raw: nil, now: now))

        // Already passed / imminent -> "now".
        XCTAssertEqual(UsageMetersFormat.resetDisplay(resetsAt: now.addingTimeInterval(-300), raw: nil, now: now, timeZone: utc), "now")
        XCTAssertEqual(UsageMetersFormat.resetDisplay(resetsAt: now.addingTimeInterval(30), raw: nil, now: now, timeZone: utc), "now")

        // Under an hour -> minutes.
        XCTAssertEqual(UsageMetersFormat.resetDisplay(resetsAt: now.addingTimeInterval(45 * 60), raw: nil, now: now, timeZone: utc), "45m")

        // Under six hours -> XhMM countdown.
        XCTAssertEqual(UsageMetersFormat.resetDisplay(resetsAt: now.addingTimeInterval(3 * 3600 + 20 * 60), raw: nil, now: now, timeZone: utc), "3h20")
        XCTAssertEqual(UsageMetersFormat.resetDisplay(resetsAt: now.addingTimeInterval(5 * 3600 + 5 * 60), raw: nil, now: now, timeZone: utc), "5h05")

        // Six hours or more -> weekday + hour in the given time zone.
        // 1_760_000_000 is Thu 2025-10-09 08:53:20 UTC; +3 days lands Sun 08:53 -> "Sun 8am".
        XCTAssertEqual(UsageMetersFormat.resetDisplay(resetsAt: now.addingTimeInterval(3 * 24 * 3600), raw: nil, now: now, timeZone: utc), "Sun 8am")
    }
    func testHomeAbbreviated() {
        // The path is the BRIDGE machine's, so abbreviation is textual —
        // never FileManager's local home.
        XCTAssertEqual(UsageMetersFormat.homeAbbreviated("/Users/dan/Dev/matron-bridge"), "~/Dev/matron-bridge")
        XCTAssertEqual(UsageMetersFormat.homeAbbreviated("/home/dan/apps/web"), "~/apps/web")
        // A bare home dir is just "~".
        XCTAssertEqual(UsageMetersFormat.homeAbbreviated("/Users/dan"), "~")
        // Non-home paths pass through untouched.
        XCTAssertEqual(UsageMetersFormat.homeAbbreviated("/opt/matron/web-journal"), "/opt/matron/web-journal")
        // A path that merely STARTS with a home-like prefix but has no
        // separator after the username is not abbreviated.
        XCTAssertEqual(UsageMetersFormat.homeAbbreviated("/Users"), "/Users")
        XCTAssertEqual(UsageMetersFormat.homeAbbreviated(""), "")
    }

    func testVitalsLine() {
        XCTAssertEqual(UsageMetersFormat.vitalsLine(SessionStatus.Vitals(cpuPct: 12, ramPct: 63)), "CPU 12% · RAM 63%")
        // The CPU half is null until the bridge sampler has two samples.
        XCTAssertEqual(UsageMetersFormat.vitalsLine(SessionStatus.Vitals(cpuPct: nil, ramPct: 63)), "RAM 63%")
        XCTAssertEqual(UsageMetersFormat.vitalsLine(SessionStatus.Vitals(cpuPct: 12, ramPct: nil)), "CPU 12%")
        // Nothing to show -> nil so callers drop the line entirely.
        XCTAssertNil(UsageMetersFormat.vitalsLine(SessionStatus.Vitals(cpuPct: nil, ramPct: nil)))
    }

}
