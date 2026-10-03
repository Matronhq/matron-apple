import Foundation
import Observation
import MatronJournal
import MatronModels

/// Backs the Memories screen's "On your boxes" section: each box's own
/// Claude Code memories (CLAUDE.md files and the per-project memory
/// directories), read over the agent RPC the folder picker uses
/// (`local_memories` / `local_memory_get`, matron-bridge spec 2026-09-29).
///
/// Read-only, and nothing runs in the background: only boxes that are
/// online are asked, once, when the screen opens (`start()`), and a file's
/// text is read when it is opened (`loadBody`). A box that is asleep is
/// listed as asleep with no content — asking would wake it.
@MainActor @Observable
public final class LocalMemoriesViewModel {
    public enum BoxState: Equatable, Sendable {
        case loading
        case loaded(LocalMemoriesIndex)
        /// Offline when the roster was read, or unreachable when asked.
        case asleep
        /// The box's bridge predates `local_memories` (`unknown_method`).
        case needsUpdate
        /// It was asked and did not give a usable answer.
        case failed
    }

    public struct Box: Equatable, Identifiable, Sendable {
        public let id: Int64
        public let name: String
        public var state: BoxState
    }

    public typealias BodyState = LocalMemoryDetail.TextState

    /// What the detail pane shows about one file, besides its text.
    public struct Listing: Equatable, Sendable {
        public let boxName: String
        public let repoTitle: String
        public let title: String
        /// The file's path with the box's home shortened to `~`.
        public let shortPath: String
        public let type: String?
        public let modifiedAt: Date
        /// The memory itself; `nil` for a CLAUDE.md.
        public let entry: LocalMemoryEntry?
    }

    /// Every box on the roster, sorted by name.
    public private(set) var boxes: [Box] = []
    /// The loaded boxes' memories, by repo then box.
    public private(set) var groups: [LocalMemoryRepoGroup] = []
    /// True from `load()` until every asked box has answered.
    public private(set) var isLoading = false
    /// Set when the roster itself could not be read.
    public private(set) var loadError: String?
    /// False until the first roster read lands, so the section can tell
    /// "nothing yet" from "no boxes".
    public private(set) var hasLoaded = false
    public private(set) var expandedGroups: Set<String> = []
    /// Groups whose selected box lists every row rather than the first few.
    public private(set) var groupsShowingAll: Set<String> = []
    public private(set) var bodies: [LocalMemoryRef: BodyState] = [:]

    /// How many rows a box lists before "Show N more".
    public static let rowLimit = 8
    /// Ceilings on how much one box, and one file, may be paged for: well
    /// past anything real, there so a misbehaving bridge cannot loop us.
    nonisolated static let maxIndexRequests = 60
    nonisolated static let maxBodyPages = 80

    private let api: any AgentRPCProviding
    private var isStarted = false
    private var loadTask: Task<Void, Never>?
    /// Bumped by every load and by `stop()`: an answer for an earlier
    /// generation describes a screen nobody is looking at.
    private var generation = 0
    private var pickedBox: [String: Int64] = [:]
    /// Once the user has opened or closed a group, the first group is no
    /// longer opened for them.
    private var userChoseExpansion = false
    private var listings: [LocalMemoryRef: Listing] = [:]

    public init(api: any AgentRPCProviding) {
        self.api = api
    }

    /// The loading task; tests await it for determinism.
    var loadTaskForTesting: Task<Void, Never>? { loadTask }

    /// The screen opened: ask the boxes, once. Later appearances of the
    /// same visit (the pop back from a file) do nothing.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        reload()
    }

    /// The screen closed: drop anything in flight and the texts read. The
    /// index is kept, so coming back shows it at once while it reloads.
    public func stop() {
        isStarted = false
        generation += 1
        loadTask?.cancel(); loadTask = nil
        isLoading = false
        bodies = [:]
    }

    /// An explicit refresh: ask every online box again.
    public func reload() {
        // Retire the load in flight before cancelling it: a cancelled leg
        // answers as a failure, which must not replace what its box listed.
        generation += 1
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load() }
    }

    public func load() async {
        generation += 1
        let generation = generation
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }

        let agents: [DeviceDTO]
        do {
            agents = try await api.devices().filter { $0.kind == "agent" }
        } catch {
            guard generation == self.generation else { return }
            loadError = "Couldn't reach the journal to list your boxes."
            hasLoaded = true
            return
        }
        guard generation == self.generation else { return }
        loadError = nil
        hasLoaded = true

        // A box asked again keeps what it last listed until the new answer
        // lands, so a refresh does not empty the section first.
        let previous = Dictionary(boxes.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        boxes = agents
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { agent in
                guard agent.connected else { return Box(id: agent.id, name: agent.name, state: .asleep) }
                if case .loaded = previous[agent.id] { return Box(id: agent.id, name: agent.name, state: previous[agent.id]!) }
                return Box(id: agent.id, name: agent.name, state: .loading)
            }
        regroup()

        let api = api
        await withTaskGroup(of: (Int64, BoxState).self) { group in
            for agent in agents where agent.connected {
                group.addTask { (agent.id, await Self.fetchIndex(api: api, boxID: agent.id)) }
            }
            for await (boxID, state) in group {
                guard generation == self.generation else { continue }
                if let index = boxes.firstIndex(where: { $0.id == boxID }) { boxes[index].state = state }
                regroup()
            }
        }
        guard generation == self.generation else { return }
        if !userChoseExpansion, expandedGroups.isEmpty, let first = groups.first {
            expandedGroups = [first.id]
        }
    }

    // MARK: What the section shows

    public var asleepBoxNames: [String] { boxes.filter { $0.state == .asleep }.map(\.name) }
    public var outdatedBoxNames: [String] { boxes.filter { $0.state == .needsUpdate }.map(\.name) }
    public var failedBoxNames: [String] { boxes.filter { $0.state == .failed }.map(\.name) }
    public var loadingBoxNames: [String] { boxes.filter { $0.state == .loading }.map(\.name) }

    public func isExpanded(_ groupID: String) -> Bool { expandedGroups.contains(groupID) }

    public func toggle(_ groupID: String) {
        userChoseExpansion = true
        if expandedGroups.contains(groupID) { expandedGroups.remove(groupID) } else { expandedGroups.insert(groupID) }
    }

    /// The box whose rows a group lists: the user's pick while that box
    /// still has something there, else the first.
    public func selectedBoxID(in group: LocalMemoryRepoGroup) -> Int64? {
        if let picked = pickedBox[group.id], group.boxes.contains(where: { $0.boxID == picked }) { return picked }
        return group.boxes.first?.boxID
    }

    public func selectBox(_ boxID: Int64, in groupID: String) {
        guard pickedBox[groupID] != boxID else { return }
        pickedBox[groupID] = boxID
        groupsShowingAll.remove(groupID)
    }

    public func showAll(in groupID: String) { groupsShowingAll.insert(groupID) }

    public func listing(for ref: LocalMemoryRef) -> Listing? { listings[ref] }

    /// The section as the list draws it. `journal` is the journal's
    /// memories, for the "≈ name" overlap tags; `selected` is the file the
    /// detail pane shows (Mac), highlighted in the list.
    public func section(journal: [Memory]?, selected: LocalMemoryRef? = nil) -> LocalMemoriesSection {
        let overlap = MemoryOverlapIndex(memories: journal ?? [])
        let sectionGroups = groups.map { group -> LocalMemoriesSection.Group in
            let expanded = isExpanded(group.id)
            let boxID = selectedBoxID(in: group)
            let box = group.boxes.first { $0.boxID == boxID }
            var rows: [LocalMemoriesSection.Row] = []
            var hidden = 0
            // Rows are only built for a group that is open.
            if expanded, let box {
                let files = box.files.map { file in
                    LocalMemoriesSection.Row(
                        ref: LocalMemoryRef(boxID: box.boxID, path: file.path), title: Self.fileTitle(file),
                        summary: (group.isGlobal ? "This box's own instructions" : "Repo instructions")
                            + " · " + LocalMemoriesSection.sizeText(file.size))
                }
                let memories = box.memories.map { memory in
                    LocalMemoriesSection.Row(
                        ref: LocalMemoryRef(boxID: box.boxID, path: memory.path), title: memory.title,
                        summary: memory.summary, overlap: overlap.match(memory))
                }
                let all = files + memories
                let shown = groupsShowingAll.contains(group.id) ? all : Array(all.prefix(Self.rowLimit))
                hidden = all.count - shown.count
                rows = shown.map {
                    LocalMemoriesSection.Row(ref: $0.ref, title: $0.title, summary: $0.summary,
                                             overlap: $0.overlap, isSelected: $0.ref == selected)
                }
            }
            return LocalMemoriesSection.Group(
                id: group.id, title: group.title, path: group.path, countLine: group.countLine,
                isExpanded: expanded,
                chips: group.boxes.map {
                    LocalMemoriesSection.Chip(boxID: $0.boxID, name: $0.boxName, count: $0.count,
                                              isSelected: $0.boxID == boxID)
                },
                rows: rows, hiddenCount: hidden, selectedBoxName: box?.boxName)
        }
        return LocalMemoriesSection(groups: sectionGroups, hasLoaded: hasLoaded, isLoading: isLoading,
                                    loadError: loadError, loadingBoxes: loadingBoxNames,
                                    asleepBoxes: asleepBoxNames, outdatedBoxes: outdatedBoxNames,
                                    failedBoxes: failedBoxNames)
    }

    /// The journal memory a file's words overlap, for the detail pane.
    public func overlap(for ref: LocalMemoryRef, journal: [Memory]?) -> String? {
        guard let entry = listings[ref]?.entry else { return nil }
        return MemoryOverlapIndex(memories: journal ?? []).match(entry)
    }

    /// One file as the detail pane draws it. A file the index no longer
    /// lists (its box stopped answering, or the screen was restored before
    /// the boxes were asked) is still shown by its path, so its text can
    /// be read.
    public func detail(for ref: LocalMemoryRef, journal: [Memory]?) -> LocalMemoryDetail {
        let text = bodies[ref] ?? .loading
        guard let listing = listings[ref] else {
            return LocalMemoryDetail(
                boxName: boxes.first { $0.id == ref.boxID }?.name ?? "a box",
                title: LocalMemoryGrouping.lastComponent(ref.path), repoTitle: "", shortPath: ref.path,
                isMemory: false, text: text)
        }
        return LocalMemoryDetail(
            boxName: listing.boxName, title: listing.title, repoTitle: listing.repoTitle,
            shortPath: listing.shortPath, type: listing.type, modifiedAt: listing.modifiedAt,
            isMemory: listing.entry != nil, overlap: overlap(for: ref, journal: journal), text: text)
    }

    private func regroup() {
        var loaded: [(id: Int64, name: String, index: LocalMemoriesIndex)] = []
        for box in boxes {
            if case .loaded(let index) = box.state { loaded.append((box.id, box.name, index)) }
        }
        groups = LocalMemoryGrouping.groups(loaded)
        let homes = Dictionary(loaded.map { ($0.id, $0.index.home) }, uniquingKeysWith: { first, _ in first })
        var listings: [LocalMemoryRef: Listing] = [:]
        for group in groups {
            for box in group.boxes {
                let home = homes[box.boxID] ?? nil
                for file in box.files {
                    listings[LocalMemoryRef(boxID: box.boxID, path: file.path)] = Listing(
                        boxName: box.boxName, repoTitle: group.title, title: Self.fileTitle(file),
                        shortPath: LocalMemoryGrouping.shortened(file.path, home: home),
                        type: nil, modifiedAt: file.modifiedAt, entry: nil)
                }
                for memory in box.memories {
                    listings[LocalMemoryRef(boxID: box.boxID, path: memory.path)] = Listing(
                        boxName: box.boxName, repoTitle: group.title, title: memory.title,
                        shortPath: LocalMemoryGrouping.shortened(memory.path, home: home),
                        type: memory.type, modifiedAt: memory.modifiedAt, entry: memory)
                }
            }
        }
        self.listings = listings
    }

    /// `CLAUDE.md`, or `.claude/CLAUDE.md` for the copy kept under `.claude`.
    public static func fileTitle(_ file: LocalMemoryFile) -> String {
        file.folder != nil && file.path.hasSuffix("/.claude/CLAUDE.md") ? ".claude/CLAUDE.md" : "CLAUDE.md"
    }

    // MARK: One box's index

    private struct Refused: Error { let state: BoxState }

    /// Reads everything one box lists, following the bridge's paging (its
    /// reply is capped at the RPC frame). Only the first reply decides the
    /// box's state: if a later page fails, what was read is still shown.
    nonisolated static func fetchIndex(api: any AgentRPCProviding, boxID: Int64) async -> BoxState {
        var requests = 0
        func ask(_ params: [String: Any]) async throws -> LocalMemoriesPage {
            guard requests < maxIndexRequests else { throw Refused(state: .failed) }
            requests += 1
            let data = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
            let reply: RPCReply
            do {
                reply = try await api.agentRequest(agentDeviceID: boxID, method: "local_memories", paramsData: data)
            } catch {
                throw Refused(state: .failed)
            }
            switch reply {
            case .ok(let resultData):
                guard let page = LocalMemoriesPage(data: resultData) else { throw Refused(state: .failed) }
                return page
            case .failure(let code, _):
                switch code {
                case "unknown_method": throw Refused(state: .needsUpdate)
                case "agent_unreachable": throw Refused(state: .asleep)
                default: throw Refused(state: .failed)
                }
            }
        }

        let first: LocalMemoriesPage
        do { first = try await ask([:]) } catch { return (error as? Refused)?.state ?? .failed }
        var index = LocalMemoriesIndex(home: first.home, claudeMD: first.claudeMD, projects: first.projects)

        do {
            var more = first.moreClaudeMD
            while more > 0 {
                let page = try await ask(["claude_md_offset": index.claudeMD.count])
                let known = Set(index.claudeMD.map(\.path))
                let fresh = page.claudeMD.filter { !known.contains($0.path) }
                guard !fresh.isEmpty else { break }
                index.claudeMD += fresh
                more = page.moreClaudeMD
            }
            for dir in first.moreProjects where !index.projects.contains(where: { $0.dir == dir }) {
                let page = try await ask(["project": dir])
                index.projects += page.projects.filter { $0.dir == dir }
            }
            for position in index.projects.indices {
                while index.projects[position].more > 0 {
                    let project = index.projects[position]
                    let page = try await ask(["project": project.dir,
                                              "offset": project.offset + project.memories.count])
                    guard let next = page.projects.first(where: { $0.dir == project.dir }) else { break }
                    let known = Set(project.memories.map(\.file))
                    let fresh = next.memories.filter { !known.contains($0.file) }
                    guard !fresh.isEmpty else { break }
                    index.projects[position].memories += fresh
                    index.projects[position].more = next.more
                }
            }
        } catch {
            // A page past the first failed: keep what was read.
        }
        return .loaded(index)
    }

    // MARK: One file's text

    /// Reads a file's text from its box, page by page. A text already read
    /// (or being read) this visit is not asked for again.
    public func loadBody(_ ref: LocalMemoryRef) async {
        switch bodies[ref] {
        case .loading, .loaded: return
        case .failed, nil: break
        }
        bodies[ref] = .loading
        let generation = generation
        // Its own task: the view's `.task` that asked may be cancelled and
        // restarted while the read is in flight, and a cancelled read must
        // not land as a failure.
        let api = api
        let result = await Task { await Self.fetchBody(api: api, ref: ref) }.value
        guard generation == self.generation else { return }
        bodies[ref] = result
    }

    nonisolated static func fetchBody(api: any AgentRPCProviding, ref: LocalMemoryRef) async -> BodyState {
        var text = ""
        var offset = 0
        for _ in 0..<maxBodyPages {
            let params: [String: Any] = ["path": ref.path, "offset": offset]
            let data = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
            let reply: RPCReply
            do {
                reply = try await api.agentRequest(agentDeviceID: ref.boxID, method: "local_memory_get", paramsData: data)
            } catch {
                return .failed("The box didn't answer. Check your connection and try again.")
            }
            switch reply {
            case .failure(let code, _):
                return .failed(bodyErrorCopy(code))
            case .ok(let resultData):
                guard let page = LocalMemoryBodyPage(data: resultData) else {
                    return .failed("The box sent something this app couldn't read.")
                }
                text += page.body
                // A next offset that does not move forward would loop.
                guard let next = page.nextOffset, next > offset else { return .loaded(text) }
                offset = next
            }
        }
        return .failed("That file is too long to show here.")
    }

    nonisolated static func bodyErrorCopy(_ code: String) -> String {
        switch code {
        case "not_found": return "That file is no longer on the box."
        case "forbidden": return "The box won't share that file."
        case "too_large": return "That file is too large to show here."
        case "agent_unreachable": return "The box is asleep or offline."
        case "unknown_method": return "The box's bridge needs an update to share its memories."
        default: return "The box couldn't read that file."
        }
    }
}
