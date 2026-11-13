#if DEBUG
import Foundation
import MatronJournal
import MatronModels

/// Made-up boxes for screenshots and previews. DEBUG builds only.
public struct BoxesDemoData: BoxesProviding {
    public init() {}

    /// Whether the build was launched to show the made-up boxes.
    public static var isRequested: Bool {
        ProcessInfo.processInfo.environment["MATRON_DEBUG_BOXES_DEMO"] != nil
    }

    /// Whether the made-up boxes should open on their usage history.
    public static var isHistoryRequested: Bool {
        isRequested && ProcessInfo.processInfo.environment["MATRON_DEBUG_BOXES_HISTORY"] != nil
    }

    private static func date(in days: Double) -> Date { Date().addingTimeInterval(days * 86_400) }

    private static func box(_ id: Int64, _ name: String, connected: Bool, live: Int?, email: String?,
                            all: Int?, fable: Int?, resetsIn days: Double, agent: String = "claude",
                            model: String = "opus", effort: String? = nil,
                            freeGB: Int64, totalGB: Int64, ageMinutes: Double) -> DeviceDTO {
        let gigabyte: Int64 = 1024 * 1024 * 1024
        var lines: [LimitLine] = []
        if let all {
            lines.append(LimitLine(id: BoxAllowances.allModelsLineID, label: "Week (all models)",
                                   percent: all, resetsAt: date(in: days)))
        }
        if let fable {
            lines.append(LimitLine(id: "week_fable", label: "Week (Fable)", percent: fable,
                                   resetsAt: date(in: days)))
        }
        let readAt = Date().addingTimeInterval(-ageMinutes * 60)
        let capacity = BoxCapacity(
            liveSessions: live, limitLines: lines, accountEmail: email,
            disk: BoxDisk(freeBytes: freeGB * gigabyte, totalBytes: totalGB * gigabyte),
            limitsAsOf: lines.isEmpty ? nil : readAt,
            defaults: BoxResolvedDefaults(agent: agent, model: model, effort: effort))
        return DeviceDTO(id: id, kind: "agent", name: name, createdAt: 0, cursor: 0, lag: 0,
                         lastSeenAt: nil, isSelf: false, connected: connected,
                         status: BoxStatus(reportedAt: readAt, capacity: capacity))
    }

    public func devices() async throws -> [DeviceDTO] {
        [
            Self.box(1, "box-a", connected: true, live: 4, email: "alice@example.com", all: 21, fable: 3,
                     resetsIn: 2.7, freeGB: 47, totalGB: 145, ageMinutes: 4),
            Self.box(2, "box-b", connected: true, live: 7, email: "bob@example.com", all: 23, fable: 6,
                     resetsIn: 1.8, freeGB: 45, totalGB: 145, ageMinutes: 2),
            Self.box(3, "box-c", connected: true, live: 5, email: "carol@example.com", all: 94, fable: 4,
                     resetsIn: 4.6, freeGB: 327, totalGB: 1800, ageMinutes: 4),
            Self.box(4, "box-d", connected: true, live: 3, email: "carol@example.com", all: 94, fable: 4,
                     resetsIn: 4.6, freeGB: 46, totalGB: 145, ageMinutes: 1),
            Self.box(5, "box-e", connected: true, live: 7, email: "dave@example.com", all: 15, fable: 12,
                     resetsIn: 6.4, agent: "codex", model: "gpt-example", effort: "xhigh",
                     freeGB: 30, totalGB: 145, ageMinutes: 6),
            Self.box(6, "box-f", connected: true, live: 0, email: nil, all: nil, fable: nil,
                     resetsIn: 0, freeGB: 30, totalGB: 145, ageMinutes: 1),
            Self.box(7, "box-g", connected: false, live: nil, email: "erin@example.com", all: 48, fable: 11,
                     resetsIn: 3.8, freeGB: 51, totalGB: 145, ageMinutes: 120),
        ]
    }

    public func roster() async throws -> RosterSnapshot {
        let now = Date()
        func session(_ id: String, _ title: String, running: Bool, ago minutes: Double) -> RosterSession {
            RosterSession(id: id, title: title, isRunning: running,
                          lastActivity: now.addingTimeInterval(-minutes * 60))
        }
        return RosterSnapshot(wakeableBoxes: [7], sessionsByBox: [
            2: [session("demo-1", "Fix the failing import test", running: true, ago: 1),
                session("demo-2", "Write the release notes", running: false, ago: 9)],
            3: [session("demo-3", "Review the settings page", running: true, ago: 2)],
        ])
    }

    public func agentRequest(agentDeviceID: Int64, method: String, paramsData: Data) async throws -> RPCReply {
        .failure(code: "agent_unreachable", detail: nil)
    }

    public func boxStatusUpdates() -> AsyncStream<(deviceID: Int64, status: BoxStatus)> {
        AsyncStream { _ in }
    }

    public func connectionStates() -> AsyncStream<SyncConnectionState> {
        AsyncStream { _ in }
    }
}
#endif

#if DEBUG
extension BoxesDemoData: UsageHistoryProviding {
    /// Twelve made-up weeks for the same made-up logins.
    public func usageHistory(weeks: Int) async throws -> UsageHistory {
        func meter(_ id: String, _ label: String, primary: Bool, resetsIn days: Double, left: Int,
                   unused: [Int]) -> UsageMeter {
            let next = Self.date(in: days)
            let finished = unused.enumerated().map { index, value in
                UsageWeek(resetsAt: next.addingTimeInterval(-Double(index + 1) * 7 * 86_400), unused: value,
                          peak: 100 - value, lastReadingAt: nil)
            }
            return UsageMeter(id: id, label: label, isPrimary: primary,
                              current: UsageWeekInProgress(resetsAt: next, unused: left, asOf: Date()),
                              weeks: finished)
        }
        func account(_ email: String, boxes: [String], resetsIn days: Double, left: Int, unused: [Int],
                     fable: [Int]) -> UsageAccount {
            UsageAccount(id: "claude:login:\(email)", agent: "claude", email: email, boxes: boxes, meters: [
                meter("week_all", "Week (all models)", primary: true, resetsIn: days, left: left, unused: unused),
                meter("week_fable", "Week (Fable)", primary: false, resetsIn: days, left: 100 - (100 - left) / 4,
                      unused: fable),
            ])
        }
        return UsageHistory(accounts: [
            account("alice@example.com", boxes: ["box-a"], resetsIn: 2.7, left: 79,
                    unused: [18, 6, 0, 3, 27, 14, 0, 9, 41, 22, 38, 30],
                    fable: [70, 64, 52, 60, 81, 77, 49, 66, 90, 84, 88, 85]),
            account("bob@example.com", boxes: ["box-b"], resetsIn: 1.8, left: 77,
                    unused: [31, 25, 12, 36, 21, 44, 30, 52, 47, 55, 61, 58],
                    fable: [88, 80, 71, 86, 79, 92, 84, 95, 90, 93, 97, 96]),
            account("carol@example.com", boxes: ["box-c", "box-d"], resetsIn: 4.6, left: 6,
                    unused: [0, 0, 2, 0, 7, 0, 0, 12, 0, 4, 0, 1],
                    fable: [40, 35, 48, 30, 55, 38, 42, 60, 36, 50, 44, 47]),
            UsageAccount(id: "codex:device:5", agent: "codex", email: nil, boxes: ["box-e"], meters: [
                meter("codex:codex:secondary", "Codex · Weekly", primary: true, resetsIn: 6.4, left: 85,
                      unused: [62, 55, 49, 73, 66, 58, 70, 64, 91, 76, 80, 78]),
            ]),
        ])
    }
}
#endif
