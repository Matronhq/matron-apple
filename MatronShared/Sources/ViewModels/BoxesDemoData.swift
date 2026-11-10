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
