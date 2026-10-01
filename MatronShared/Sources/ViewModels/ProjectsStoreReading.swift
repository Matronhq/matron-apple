import Foundation
import MatronModels
import MatronJournal

/// The store reads the projects surfaces need, as a protocol so tests fake
/// the store. Conformance declared here because MatronJournal cannot import
/// this module.
public protocol ProjectsStoreReading: Sendable {
    func projectsStream() -> AsyncStream<[Project]>
    func projectStream(id: String) -> AsyncStream<Project?>
    func missionsStream(projectID: String) -> AsyncStream<[Mission]>
    func unfiledOpenMissionsStream() -> AsyncStream<[Mission]>
    func needsYouItemsStream(projectID: String) -> AsyncStream<[TrackerItem]>
    func openItemsStream(projectID: String) -> AsyncStream<[TrackerItem]>
    func recentMilestonesStream(projectID: String, limit: Int) -> AsyncStream<[Milestone]>
    func projectSessionsByBoxStream(id: String) -> AsyncStream<[String: Int]>
    func projectFeedStream(id: String) -> AsyncStream<ProjectFeed?>
}

extension JournalStore: ProjectsStoreReading {}

/// The refresh/write surface, mirroring `MissionsSyncing`.
public protocol ProjectsSyncing: Sendable {
    @discardableResult func refresh() async -> ProjectsRefreshOutcome
    @discardableResult func refreshProject(id: String) async -> ProjectRefreshOutcome
    func beginWatching(convoID: String) async
    func endWatching(convoID: String) async
    func createProject(title: String, body: String?) async throws -> Project
    func mergeProject(id: String, into: String) async throws
    @discardableResult func setMissionProject(missionID: String, project: String?) async throws -> Mission
    func supportedStream() async -> AsyncStream<Bool>
    func projectFeed(id: String, kind: ProjectFeedKind, before: String?, limit: Int?) async throws -> ProjectFeedSlice
}

extension ProjectsSync: ProjectsSyncing {}
