import Foundation
import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

/// A stream that hands its continuation to the test.
final class Feed<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<Value>.Continuation] = []
    private var last: Value?
    func stream() -> AsyncStream<Value> {
        let (s, c) = AsyncStream<Value>.makeStream()
        lock.withLock {
            continuations.append(c)
            if let last { c.yield(last) }
        }
        return s
    }
    func send(_ value: Value) {
        let cs = lock.withLock { () -> [AsyncStream<Value>.Continuation] in last = value; return continuations }
        for c in cs { c.yield(value) }
    }
    var subscribers: Int { lock.withLock { continuations.count } }
}

final class FakeProjectsStore: ProjectsStoreReading, @unchecked Sendable {
    let projects = Feed<[Project]>()
    let unfiled = Feed<[Mission]>()
    private let lock = NSLock()
    private var projectFeeds: [String: Feed<Project?>] = [:]
    private var missionFeeds: [String: Feed<[Mission]>] = [:]
    private var needsYouFeeds: [String: Feed<[TrackerItem]>] = [:]
    private var milestoneFeeds: [String: Feed<[Milestone]>] = [:]
    private var sessionFeeds: [String: Feed<[String: Int]>] = [:]

    private func feed<V>(_ table: ReferenceWritableKeyPath<FakeProjectsStore, [String: Feed<V>]>, _ id: String) -> Feed<V> {
        lock.withLock {
            if let f = self[keyPath: table][id] { return f }
            let f = Feed<V>(); self[keyPath: table][id] = f; return f
        }
    }
    func project(_ id: String) -> Feed<Project?> { feed(\.projectFeeds, id) }
    func missions(_ id: String) -> Feed<[Mission]> { feed(\.missionFeeds, id) }
    func needsYou(_ id: String) -> Feed<[TrackerItem]> { feed(\.needsYouFeeds, id) }
    func milestones(_ id: String) -> Feed<[Milestone]> { feed(\.milestoneFeeds, id) }
    func sessions(_ id: String) -> Feed<[String: Int]> { feed(\.sessionFeeds, id) }

    func projectsStream() -> AsyncStream<[Project]> { projects.stream() }
    func projectStream(id: String) -> AsyncStream<Project?> { project(id).stream() }
    func missionsStream(projectID: String) -> AsyncStream<[Mission]> { missions(projectID).stream() }
    func unfiledOpenMissionsStream() -> AsyncStream<[Mission]> { unfiled.stream() }
    func needsYouItemsStream(projectID: String) -> AsyncStream<[TrackerItem]> { needsYou(projectID).stream() }
    func recentMilestonesStream(projectID: String, limit: Int) -> AsyncStream<[Milestone]> { milestones(projectID).stream() }
    func projectSessionsByBoxStream(id: String) -> AsyncStream<[String: Int]> { sessions(id).stream() }
}

final class FakeProjectsSync: ProjectsSyncing, @unchecked Sendable {
    private let lock = NSLock()
    let supported = Feed<Bool>()
    var refreshCalls: Int { lock.withLock { _refreshCalls } }
    var projectOutcomes: [String: ProjectRefreshOutcome] {
        get { lock.withLock { _projectOutcomes } } set { lock.withLock { _projectOutcomes = newValue } }
    }
    var refreshedProjects: [String] { lock.withLock { _refreshedProjects } }
    var created: [(String, String?)] { lock.withLock { _created } }
    var merged: [(String, String)] { lock.withLock { _merged } }
    var filed: [(String, String?)] { lock.withLock { _filed } }
    var failWrites: Error? { get { lock.withLock { _failWrites } } set { lock.withLock { _failWrites = newValue } } }
    private var _refreshCalls = 0
    private var _projectOutcomes: [String: ProjectRefreshOutcome] = [:]
    private var _refreshedProjects: [String] = []
    private var _created: [(String, String?)] = []
    private var _merged: [(String, String)] = []
    private var _filed: [(String, String?)] = []
    private var _failWrites: Error?

    init() { supported.send(true) }
    func refresh() async -> ProjectsRefreshOutcome { lock.withLock { _refreshCalls += 1 }; return .succeeded }
    func refreshProject(id: String) async -> ProjectRefreshOutcome {
        lock.withLock { _refreshedProjects.append(id) }
        return projectOutcomes[id] ?? .loaded(projectID: id)
    }
    func beginWatching(convoID: String) async {}
    func endWatching(convoID: String) async {}
    func createProject(title: String, body: String?) async throws -> Project {
        if let e = failWrites { throw e }
        lock.withLock { _created.append((title, body)) }
        return Project(id: "pj_new", num: 9000, title: title)
    }
    func mergeProject(id: String, into: String) async throws {
        if let e = failWrites { throw e }
        lock.withLock { _merged.append((id, into)) }
    }
    func setMissionProject(missionID: String, project: String?) async throws -> Mission {
        if let e = failWrites { throw e }
        lock.withLock { _filed.append((missionID, project)) }
        return Mission(id: missionID, num: 1, title: "M", originConvoID: "c1", projectID: project)
    }
    func supportedStream() async -> AsyncStream<Bool> { supported.stream() }
}

final class FakeMissionsSyncForProjects: MissionsSyncing, @unchecked Sendable {
    private let lock = NSLock()
    private var _refreshedMissions: [String] = []
    var refreshedMissions: [String] { lock.withLock { _refreshedMissions } }
    func refresh() async -> MissionsRefreshOutcome { .succeeded }
    func refreshMission(id: String) async -> MissionsRefreshOutcome {
        lock.withLock { _refreshedMissions.append(id) }; return .succeeded
    }
    func closeMission(id: String, summary: String) async throws -> Mission {
        Mission(id: id, num: 1, state: .closed, title: "M", originConvoID: "c1")
    }
    func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
}

final class FakeDashboardStoreForProjects: MissionsDashboardStoreReading, @unchecked Sendable {
    let missions = Feed<[Mission]>()
    let needsYou = Feed<[String: [TrackerItem]]>()
    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]> { missions.stream() }
    func allMissionConversationsStream() -> AsyncStream<[String: [MissionConversation]]> { AsyncStream { $0.yield([:]) } }
    func latestMilestonesStream() -> AsyncStream<[String: Milestone]> { AsyncStream { $0.yield([:]) } }
    func needsYouItemsByMissionStream() -> AsyncStream<[String: [TrackerItem]]> { needsYou.stream() }
    func latestSummaryTOCsStream() -> AsyncStream<[String: String]> { AsyncStream { $0.yield([:]) } }
    func sessionStatesStream() -> AsyncStream<[String: String]> { AsyncStream { $0.yield([:]) } }
}

final class FakeMissionPageStore: MissionsStoreReading, @unchecked Sendable {
    let mission = Feed<Mission?>()
    let milestones = Feed<[Milestone]>()
    let items = Feed<[TrackerItem]>()
    let conversations = Feed<[MissionConversation]>()
    private let lock = NSLock()
    private var _taggedIDs: Set<String> = []
    var taggedIDs: Set<String> { lock.withLock { _taggedIDs } }
    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]> { AsyncStream { $0.yield([]) } }
    func missionStream(id: String) -> AsyncStream<Mission?> { mission.stream() }
    func milestonesStream(missionID: String) -> AsyncStream<[Milestone]> { milestones.stream() }
    func itemsStream(missionID: String) -> AsyncStream<[TrackerItem]> { items.stream() }
    func missionConversationsStream(missionID: String) -> AsyncStream<[MissionConversation]> { conversations.stream() }
    func sessionTag(convoID: String) -> SessionTagInputs? { nil }
    func sessionTags(convoIDs: Set<String>) -> [String: SessionTagInputs] {
        lock.withLock { _taggedIDs = convoIDs }
        return [:]
    }
}

@MainActor
func waitForProjects(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool,
               file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return XCTFail("timed out", file: file, line: line) }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
