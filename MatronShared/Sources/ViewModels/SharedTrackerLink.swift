import Foundation
import Observation
import MatronJournal
import MatronModels

/// Reads another person's shareable link (`https://<journal>/u/<them>/<n>`)
/// for the read-only viewer (`SharedTrackerPreview`). Nothing here is
/// written to the local store: another person's numbers are a different
/// number space from the user's own.
///
/// `GET /lookup` for what the number is, then the item or mission it names.
public struct SharedTrackerLinkLoader: Sendable {
    let lookup: @Sendable (_ user: String, _ num: Int) async throws -> NumberLookup
    let item: @Sendable (_ id: String) async throws -> (item: TrackerItem, comments: [TrackerComment])
    let mission: @Sendable (_ id: String) async throws -> MissionDetail

    public init(lookup: @escaping @Sendable (String, Int) async throws -> NumberLookup,
                item: @escaping @Sendable (String) async throws -> (item: TrackerItem, comments: [TrackerComment]),
                mission: @escaping @Sendable (String) async throws -> MissionDetail) {
        self.lookup = lookup; self.item = item; self.mission = mission
    }

    public init(api: JournalAPI) {
        self.init(lookup: { try await api.lookup(user: $0, num: $1) },
                  item: { try await api.item(id: $0) },
                  mission: { try await api.mission(id: $0) })
    }

    public func load(_ link: TrackerLinkPath) async -> SharedTrackerLinkState {
        do {
            let hit = try await lookup(link.user, link.num)
            let owner = hit.ownerName ?? link.user
            switch hit.kind {
            case .item:
                let r = try await item(hit.id)
                return .loaded(Self.preview(item: r.item, comments: r.comments, owner: owner))
            case .mission:
                return .loaded(Self.preview(mission: try await mission(hit.id), owner: owner))
            case .milestone:
                // A milestone is read on its mission's page.
                guard let missionID = hit.mission?.id else { return .unsupported(kindLabel: "Milestone") }
                return .loaded(Self.preview(mission: try await mission(missionID), owner: owner))
            case .project:
                return .unsupported(kindLabel: "Project")
            }
        } catch JournalAPIError.notFound {
            return .notShared
        } catch {
            return .failed
        }
    }

    static func preview(item: TrackerItem, comments: [TrackerComment], owner: String) -> SharedTrackerPreview {
        let entries = comments.filter { $0.kind == .comment }.map { c in
            SharedTrackerPreview.Entry(id: c.id, heading: c.author == .user ? owner : "Agent",
                                       body: c.body, date: c.createdAt)
        }
        var status = item.state == .open ? "Open" : "Closed"
        if let resolution = item.resolution, item.state == .closed { status += " · \(resolution.rawValue)" }
        return SharedTrackerPreview(owner: owner, kindLabel: item.kind.rawValue.capitalized, num: item.num,
                                    title: item.title, status: status, body: item.body,
                                    entriesHeading: entries.isEmpty ? nil : "Comments", entries: entries)
    }

    static func preview(mission detail: MissionDetail, owner: String) -> SharedTrackerPreview {
        let m = detail.mission
        // Newest first, as the mission page lists them.
        let entries = detail.milestones.sorted { $0.createdAt > $1.createdAt }.map { ms in
            SharedTrackerPreview.Entry(id: ms.id, heading: ms.title, body: ms.body, date: ms.createdAt)
        }
        let body = [m.status, m.body].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n\n")
        return SharedTrackerPreview(owner: owner, kindLabel: "Mission", num: m.num, title: m.title,
                                    status: m.state == .open ? "Open" : "Closed", body: body,
                                    entriesHeading: entries.isEmpty ? nil : "Milestones", entries: entries)
    }
}

/// One open viewer for another person's link. A link tapped inside it to
/// another of that person's numbers (or anyone else's) replaces what it
/// shows.
@MainActor @Observable
public final class SharedTrackerLinkViewModel: Identifiable {
    public private(set) var link: TrackerLinkPath
    /// The web address, for Copy Link.
    public private(set) var url: URL
    public private(set) var state: SharedTrackerLinkState = .loading
    private let loader: SharedTrackerLinkLoader
    /// Bumped by each load, so a slower earlier read never replaces a
    /// later one.
    private var generation = 0

    /// Fixed for the sheet's life: navigating inside it keeps it open.
    public nonisolated let id = UUID()

    public init(link: TrackerLinkPath, url: URL, loader: SharedTrackerLinkLoader) {
        self.link = link; self.url = url; self.loader = loader
    }

    public func load() async {
        generation += 1
        let current = generation
        state = .loading
        let loaded = await loader.load(link)
        guard current == generation else { return }
        state = loaded
    }

    /// Shows `link` instead, reached at `url`.
    public func show(_ link: TrackerLinkPath, url: URL) async {
        self.link = link
        self.url = url
        await load()
    }

    /// Shows number `num` in the same person's number space: what a
    /// `matron://item/<n>` or `matron://mission/<n>` link in their text
    /// names.
    public func showSameOwner(_ num: Int) async {
        // `…/u/<them>/<n>` and `…/u/<them>/<n>/` both lose the `<n>`.
        let next = url.deletingLastPathComponent().appendingPathComponent(String(num))
        await show(TrackerLinkPath(user: link.user, num: num), url: next)
    }
}
