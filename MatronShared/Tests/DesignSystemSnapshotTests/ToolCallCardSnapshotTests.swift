import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem
@testable import MatronEvents

final class ToolCallCardSnapshotTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1745000000)

    func test_running_collapsed() {
        let evt = ToolCallEvent(
            tool: "Bash", argsJSON: #"{ "command": "ls -la" }"#,
            status: .running, resultText: nil, resultTruncated: false,
            startedAt: baseDate, endedAt: nil
        )
        assertVariants(of: ToolCallCard(event: evt).frame(width: 320), named: "running_collapsed")
    }

    func test_ok_collapsed() {
        let evt = ToolCallEvent(
            tool: "Read", argsJSON: #"{ "file_path": "/etc/hosts" }"#,
            status: .ok, resultText: "127.0.0.1 localhost\n::1 ip6-localhost",
            resultTruncated: false, startedAt: baseDate, endedAt: baseDate.addingTimeInterval(0.5)
        )
        assertVariants(of: ToolCallCard(event: evt).frame(width: 320), named: "ok_collapsed")
    }

    func test_error_collapsed() {
        let evt = ToolCallEvent(
            tool: "Bash", argsJSON: #"{ "command": "false" }"#,
            status: .error, resultText: "exit 1", resultTruncated: false,
            startedAt: baseDate, endedAt: baseDate.addingTimeInterval(0.1)
        )
        assertVariants(of: ToolCallCard(event: evt).frame(width: 320), named: "error_collapsed")
    }

    func test_ok_expanded_showsArgsAndResult() {
        let evt = ToolCallEvent(
            tool: "Read", argsJSON: #"{ "file_path": "/etc/hosts" }"#,
            status: .ok, resultText: "127.0.0.1 localhost\n::1 ip6-localhost",
            resultTruncated: false, startedAt: baseDate, endedAt: baseDate.addingTimeInterval(0.5)
        )
        assertVariants(of: ToolCallCard(event: evt, expanded: true).frame(width: 320),
                       named: "ok_expanded")
    }

    func test_error_expanded_showsErrorBody() {
        let evt = ToolCallEvent(
            tool: "Bash", argsJSON: #"{ "command": "false" }"#,
            status: .error, resultText: "exit 1: command not found",
            resultTruncated: false, startedAt: baseDate, endedAt: baseDate.addingTimeInterval(0.1)
        )
        assertVariants(of: ToolCallCard(event: evt, expanded: true).frame(width: 320),
                       named: "error_expanded")
    }

    func test_ok_expanded_truncatedResult() {
        let evt = ToolCallEvent(
            tool: "Bash", argsJSON: #"{ "command": "ls -la /" }"#,
            status: .ok, resultText: String(repeating: "drwxr-xr-x  1 root root  4096 Jan  1 00:00 .\n", count: 30),
            resultTruncated: true, startedAt: baseDate, endedAt: baseDate.addingTimeInterval(0.2)
        )
        assertVariants(of: ToolCallCard(event: evt, expanded: true).frame(width: 320),
                       named: "ok_expanded_truncated")
    }

    // MARK: Command-completion states (journal tool_output shapes)

    func test_exitCode_collapsed_showsExitBadge() {
        let evt = ToolCallEvent(
            tool: "make", argsJSON: "make test",
            status: .error, resultText: "error: no rule to make target",
            resultTruncated: false, startedAt: baseDate, endedAt: nil,
            exitCode: 2
        )
        assertVariants(of: ToolCallCard(event: evt).frame(width: 320),
                       named: "exitCode_collapsed")
    }

    func test_denied_collapsed_showsDeniedBadge() {
        let evt = ToolCallEvent(
            tool: "rm", argsJSON: "rm -rf build/",
            status: .error, resultText: nil, resultTruncated: false,
            startedAt: baseDate, endedAt: nil,
            denied: true
        )
        assertVariants(of: ToolCallCard(event: evt).frame(width: 320),
                       named: "denied_collapsed")
    }

    func test_expired_expanded_showsExpiredAffordance() {
        // Tombstone / TTL state: command and exit survive, output doesn't —
        // no snippet area, no fetch button (protocol.md binding rule).
        let evt = ToolCallEvent(
            tool: "make", argsJSON: "make test",
            status: .ok, resultText: nil, resultTruncated: false,
            startedAt: baseDate, endedAt: nil,
            exitCode: 0, expired: true
        )
        assertVariants(of: ToolCallCard(event: evt, expanded: true).frame(width: 320),
                       named: "expired_expanded")
    }

    #if os(macOS)
    /// Mac-only: collapsed card with the "Click to expand" hover hint surfaced
    /// via `forceHovered`. iOS has no hover state, so the test is compiled out
    /// under `#if os(macOS)` — only the Mac scheme records this baseline.
    func test_mac_collapsed_hovered_showsExpandHint() {
        let evt = ToolCallEvent(
            tool: "Read", argsJSON: #"{ "file_path": "/etc/hosts" }"#,
            status: .ok, resultText: "127.0.0.1 localhost",
            resultTruncated: false, startedAt: baseDate, endedAt: baseDate.addingTimeInterval(0.1)
        )
        assertVariants(
            of: ToolCallCard(event: evt, expanded: false, forceHovered: true).frame(width: 320),
            named: "collapsedHovered"
        )
    }
    #endif
}
