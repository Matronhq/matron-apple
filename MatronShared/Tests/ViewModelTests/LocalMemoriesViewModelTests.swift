import XCTest
import MatronJournal
import MatronModels
@testable import MatronViewModels

/// Scripted boxes for the "On your boxes" section: every `agentRequest` is
/// answered by `handler`, keyed by box, method and params, so a fan-out to
/// several boxes is deterministic whatever order the legs run in.
private final class FakeBoxes: AgentRPCProviding, @unchecked Sendable {
    typealias Handler = @Sendable (_ boxID: Int64, _ method: String, _ params: [String: Any]) throws -> RPCReply

    private let lock = NSLock()
    private var _devices: Result<[DeviceDTO], JournalAPIError> = .success([])
    private var _handler: Handler = { _, _, _ in .failure(code: "unknown_method", detail: nil) }
    private var _requests: [(boxID: Int64, method: String, params: [String: Any])] = []

    var devicesResult: Result<[DeviceDTO], JournalAPIError> {
        get { lock.withLock { _devices } } set { lock.withLock { _devices = newValue } }
    }
    var handler: Handler {
        get { lock.withLock { _handler } } set { lock.withLock { _handler = newValue } }
    }
    var requests: [(boxID: Int64, method: String, params: [String: Any])] { lock.withLock { _requests } }
    func requests(to boxID: Int64) -> [[String: Any]] { requests.filter { $0.boxID == boxID }.map(\.params) }

    func devices() async throws -> [DeviceDTO] { try devicesResult.get() }

    func agentRequest(agentDeviceID: Int64, method: String, paramsData: Data) async throws -> RPCReply {
        let params = (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any] ?? [:]
        let handler = lock.withLock { () -> Handler in
            _requests.append((agentDeviceID, method, params))
            return _handler
        }
        return try handler(agentDeviceID, method, params)
    }

    func boxStatusUpdates() -> AsyncStream<(deviceID: Int64, status: BoxStatus)> { AsyncStream { $0.finish() } }
    func connectionStates() -> AsyncStream<SyncConnectionState> { AsyncStream { $0.finish() } }
}

private func ok(_ json: Any) -> RPCReply {
    .ok(resultData: try! JSONSerialization.data(withJSONObject: json))
}

private func box(_ id: Int64, _ name: String, connected: Bool = true, kind: String = "agent") -> DeviceDTO {
    DeviceDTO(id: id, kind: kind, name: name, createdAt: 0, cursor: 0, lag: 0, lastSeenAt: nil,
              isSelf: false, connected: connected, status: nil)
}

private func memoryJSON(_ file: String, title: String? = nil, description: String = "", hook: String = "") -> [String: Any] {
    ["file": file, "name": String(file.dropLast(3)), "title": title ?? String(file.dropLast(3)),
     "description": description, "type": "project", "hook": hook, "size": 100, "mtime": 1_790_000_000_000]
}

private func projectJSON(_ dir: String, path: String?, memories: [[String: Any]], offset: Int = 0, more: Int = 0) -> [String: Any] {
    ["dir": dir, "path": path ?? NSNull(), "memory_dir": "/home/dan/.claude/projects/\(dir)/memory",
     "index": NSNull(), "offset": offset, "memories": memories, "more": more]
}

@MainActor
final class LocalMemoriesViewModelTests: XCTestCase {
    private func loaded(_ vm: LocalMemoriesViewModel) async {
        vm.start()
        await vm.loadTaskForTesting?.value
    }

    func test_start_asksOnlyOnlineBoxes_andListsTheRestAsAsleep() async {
        let fake = FakeBoxes()
        fake.devicesResult = .success([box(1, "ang"), box(2, "pat", connected: false),
                                       box(9, "Dan's iPhone", kind: "client")])
        fake.handler = { _, _, _ in
            ok(["home": "/home/dan",
                "claude_md": [["path": "/home/dan/.claude/CLAUDE.md", "size": 10, "mtime": 1]],
                "projects": [projectJSON("-home-dan-app", path: "/home/dan/app",
                                         memories: [memoryJSON("a.md", title: "A rule", hook: "the hook")])]])
        }
        let vm = LocalMemoriesViewModel(api: fake)
        await loaded(vm)

        XCTAssertEqual(Set(fake.requests.map(\.boxID)), [1], "an asleep box is never asked: asking would wake it")
        XCTAssertEqual(fake.requests.first?.method, "local_memories")
        XCTAssertEqual(vm.boxes.map(\.name), ["ang", "pat"], "only boxes, sorted by name")
        XCTAssertEqual(vm.asleepBoxNames, ["pat"])
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.groups.map(\.title), ["app", "Global CLAUDE.md"])
        XCTAssertEqual(vm.groups[0].path, "~/app")
        XCTAssertEqual(vm.groups[0].boxes.map(\.boxName), ["ang"])
        XCTAssertEqual(vm.groups[0].boxes[0].memories.map(\.title), ["A rule"])
        XCTAssertEqual(vm.groups[0].boxes[0].memories[0].path, "/home/dan/.claude/projects/-home-dan-app/memory/a.md")
        XCTAssertTrue(vm.isExpanded(vm.groups[0].id), "the first repo opens once everything has landed")
    }

    /// The screen's `onAppear` runs again on the pop back from a file.
    func test_start_asksOncePerVisit_andAgainAfterStop() async {
        let fake = FakeBoxes()
        fake.devicesResult = .success([box(1, "ang")])
        fake.handler = { _, _, _ in ok(["home": "/home/dan", "claude_md": [], "projects": []]) }
        let vm = LocalMemoriesViewModel(api: fake)
        await loaded(vm)
        await loaded(vm)
        XCTAssertEqual(fake.requests.count, 1)

        vm.stop()
        await loaded(vm)
        XCTAssertEqual(fake.requests.count, 2)
    }

    func test_boxStates_anOldBridgeAnUnreachableBoxAndAFailure() async {
        let fake = FakeBoxes()
        fake.devicesResult = .success([box(1, "old"), box(2, "gone"), box(3, "broken"), box(4, "quiet"), box(5, "garbled")])
        fake.handler = { id, _, _ in
            switch id {
            case 1: return .failure(code: "unknown_method", detail: nil)
            case 2: return .failure(code: "agent_unreachable", detail: nil)
            case 3: return .failure(code: "internal", detail: nil)
            case 4: throw RPCRequestError.timeout
            default: return .ok(resultData: Data("[]".utf8))
            }
        }
        let vm = LocalMemoriesViewModel(api: fake)
        await loaded(vm)

        XCTAssertEqual(vm.outdatedBoxNames, ["old"])
        XCTAssertEqual(vm.asleepBoxNames, ["gone"])
        XCTAssertEqual(vm.failedBoxNames, ["broken", "garbled", "quiet"])
        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertNil(vm.loadError, "boxes that don't answer are named, not raised as an error")
    }

    func test_load_rosterFailureIsReported() async {
        let fake = FakeBoxes()
        fake.devicesResult = .failure(.rateLimited)
        let vm = LocalMemoriesViewModel(api: fake)
        await loaded(vm)
        XCTAssertNotNil(vm.loadError)
        XCTAssertTrue(vm.hasLoaded)
        XCTAssertFalse(vm.isLoading)
    }

    /// The bridge trims its reply to the RPC frame in three ways; each is
    /// read back until nothing is left.
    func test_load_followsEveryKindOfPage() async {
        let fake = FakeBoxes()
        fake.devicesResult = .success([box(1, "ang")])
        fake.handler = { _, _, params in
            if let offset = params["claude_md_offset"] as? Int {
                XCTAssertEqual(offset, 1)
                return ok(["home": "/home/dan", "claude_md_offset": 1,
                           "claude_md": [["path": "/home/dan/app/CLAUDE.md", "size": 5, "mtime": 1, "folder": "/home/dan/app"]]])
            }
            if let project = params["project"] as? String {
                if project == "-home-dan-dropped" {
                    return ok(["home": "/home/dan",
                               "projects": [projectJSON(project, path: "/home/dan/dropped", memories: [memoryJSON("d.md")])]])
                }
                let offset = params["offset"] as? Int ?? 0
                // Three memories in all, one per page.
                return ok(["home": "/home/dan",
                           "projects": [projectJSON(project, path: "/home/dan/app",
                                                    memories: [memoryJSON("m\(offset).md")],
                                                    offset: offset, more: 2 - offset)]])
            }
            return ok(["home": "/home/dan",
                       "claude_md": [["path": "/home/dan/.claude/CLAUDE.md", "size": 10, "mtime": 1]],
                       "more_claude_md": 1,
                       "more_projects": ["-home-dan-dropped"],
                       "projects": [projectJSON("-home-dan-app", path: "/home/dan/app",
                                                memories: [memoryJSON("m0.md")], more: 2)]])
        }
        let vm = LocalMemoriesViewModel(api: fake)
        await loaded(vm)

        let app = vm.groups.first { $0.title == "app" }
        XCTAssertEqual(app?.boxes.first?.memories.map(\.file), ["m0.md", "m1.md", "m2.md"])
        XCTAssertEqual(app?.boxes.first?.files.map(\.path), ["/home/dan/app/CLAUDE.md"],
                       "a repo's CLAUDE.md sits with that repo's memories")
        XCTAssertEqual(vm.groups.first { $0.title == "dropped" }?.total, 1)
        XCTAssertEqual(vm.groups.last?.isGlobal, true)
        XCTAssertEqual(fake.requests.count, 5)
    }

    /// A bridge that keeps promising more without sending any must not
    /// keep us asking.
    func test_load_stopsPagingWhenAPageBringsNothingNew() async {
        let fake = FakeBoxes()
        fake.devicesResult = .success([box(1, "ang")])
        fake.handler = { _, _, _ in
            ok(["home": "/home/dan", "claude_md": [],
                "projects": [projectJSON("-home-dan-app", path: "/home/dan/app", memories: [memoryJSON("a.md")], more: 5)]])
        }
        let vm = LocalMemoriesViewModel(api: fake)
        await loaded(vm)
        XCTAssertEqual(fake.requests.count, 2)
        XCTAssertEqual(vm.groups.first?.total, 1)
    }

    func test_load_aFailedLaterPageKeepsWhatWasRead() async {
        let fake = FakeBoxes()
        fake.devicesResult = .success([box(1, "ang")])
        fake.handler = { _, _, params in
            if params["project"] != nil { throw RPCRequestError.timeout }
            return ok(["home": "/home/dan", "claude_md": [],
                       "projects": [projectJSON("-home-dan-app", path: "/home/dan/app", memories: [memoryJSON("a.md")], more: 5)]])
        }
        let vm = LocalMemoriesViewModel(api: fake)
        await loaded(vm)
        XCTAssertEqual(vm.groups.first?.total, 1)
        XCTAssertTrue(vm.failedBoxNames.isEmpty)
    }

    func test_groups_mergeTheSameRepoAcrossBoxes_andPickingABoxSticks() async {
        let fake = FakeBoxes()
        fake.devicesResult = .success([box(1, "bev"), box(2, "ang"), box(3, "dan-mac")])
        fake.handler = { id, _, _ in
            switch id {
            case 1: return ok(["home": "/home/dan", "claude_md": [],
                               "projects": [projectJSON("-home-dan-app", path: "/home/dan/app",
                                                        memories: [memoryJSON("a.md"), memoryJSON("b.md")])]])
            case 2: return ok(["home": "/home/dan", "claude_md": [],
                               "projects": [projectJSON("-home-dan-app", path: "/home/dan/app", memories: [memoryJSON("a.md")]),
                                            projectJSON("-home-dan-lost", path: nil, memories: [memoryJSON("x.md")])]])
            default: return ok(["home": "/Users/dan", "claude_md": [],
                                "projects": [projectJSON("-Users-dan-Dev-app", path: "/Users/dan/Dev/app",
                                                         memories: [memoryJSON("c.md")])]])
            }
        }
        let vm = LocalMemoriesViewModel(api: fake)
        await loaded(vm)

        XCTAssertEqual(vm.groups.map(\.title), ["app", "-home-dan-lost"],
                       "the same repo is one group wherever a box keeps it; an unnamed folder shows its directory name")
        let app = vm.groups[0]
        XCTAssertEqual(app.boxes.map(\.boxName), ["ang", "bev", "dan-mac"])
        XCTAssertEqual(app.countLine, "4 on 3 boxes")
        XCTAssertEqual(vm.selectedBoxID(in: app), 2, "the first box by name until one is picked")

        vm.showAll(in: app.id)
        vm.selectBox(1, in: app.id)
        XCTAssertEqual(vm.selectedBoxID(in: app), 1)
        XCTAssertFalse(vm.groupsShowingAll.contains(app.id), "another box starts from its first rows")

        vm.toggle(app.id)
        XCTAssertFalse(vm.isExpanded(app.id))
    }

    func test_listing_describesAMemoryAndAClaudeMD() async {
        let fake = FakeBoxes()
        fake.devicesResult = .success([box(1, "ang")])
        fake.handler = { _, _, _ in
            ok(["home": "/home/dan",
                "claude_md": [["path": "/home/dan/app/.claude/CLAUDE.md", "size": 5, "mtime": 1, "folder": "/home/dan/app"]],
                "projects": [projectJSON("-home-dan-app", path: "/home/dan/app",
                                         memories: [memoryJSON("a.md", title: "A rule")])]])
        }
        let vm = LocalMemoriesViewModel(api: fake)
        await loaded(vm)

        let memory = vm.listing(for: LocalMemoryRef(boxID: 1, path: "/home/dan/.claude/projects/-home-dan-app/memory/a.md"))
        XCTAssertEqual(memory?.title, "A rule")
        XCTAssertEqual(memory?.boxName, "ang")
        XCTAssertEqual(memory?.repoTitle, "app")
        XCTAssertEqual(memory?.shortPath, "~/.claude/projects/-home-dan-app/memory/a.md")
        XCTAssertEqual(memory?.type, "project")
        let file = vm.listing(for: LocalMemoryRef(boxID: 1, path: "/home/dan/app/.claude/CLAUDE.md"))
        XCTAssertEqual(file?.title, ".claude/CLAUDE.md")
        XCTAssertNil(file?.entry)
    }

    // MARK: A file's text

    func test_loadBody_readsEveryPage_once() async {
        let fake = FakeBoxes()
        let ref = LocalMemoryRef(boxID: 1, path: "/home/dan/app/CLAUDE.md")
        fake.handler = { _, method, params in
            XCTAssertEqual(method, "local_memory_get")
            XCTAssertEqual(params["path"] as? String, "/home/dan/app/CLAUDE.md")
            switch params["offset"] as? Int {
            case 0: return ok(["path": "p", "size": 9, "mtime": 1, "offset": 0, "body": "one ", "next_offset": 4])
            case 4: return ok(["path": "p", "size": 9, "mtime": 1, "offset": 4, "body": "two", "next_offset": NSNull()])
            default: return .failure(code: "bad_request", detail: nil)
            }
        }
        let vm = LocalMemoriesViewModel(api: fake)
        await vm.loadBody(ref)
        XCTAssertEqual(vm.bodies[ref], .loaded("one two"))

        await vm.loadBody(ref)
        XCTAssertEqual(fake.requests.count, 2, "a text already read this visit is not asked for again")
    }

    func test_loadBody_failureSaysWhy_andCanBeRetried() async {
        let fake = FakeBoxes()
        let ref = LocalMemoryRef(boxID: 1, path: "/home/dan/app/CLAUDE.md")
        fake.handler = { _, _, _ in .failure(code: "not_found", detail: nil) }
        let vm = LocalMemoriesViewModel(api: fake)
        await vm.loadBody(ref)
        XCTAssertEqual(vm.bodies[ref], .failed("That file is no longer on the box."))

        fake.handler = { _, _, _ in ok(["body": "here", "next_offset": NSNull()]) }
        await vm.loadBody(ref)
        XCTAssertEqual(vm.bodies[ref], .loaded("here"))
    }

    func test_loadBody_aNextOffsetThatDoesNotAdvanceEndsTheRead() async {
        let fake = FakeBoxes()
        let ref = LocalMemoryRef(boxID: 1, path: "/p")
        fake.handler = { _, _, _ in ok(["body": "x", "next_offset": 0]) }
        let vm = LocalMemoriesViewModel(api: fake)
        await vm.loadBody(ref)
        XCTAssertEqual(vm.bodies[ref], .loaded("x"))
        XCTAssertEqual(fake.requests.count, 1)
    }

    func test_stop_dropsTheTextsRead() async {
        let fake = FakeBoxes()
        let ref = LocalMemoryRef(boxID: 1, path: "/p")
        fake.handler = { _, _, _ in ok(["body": "x", "next_offset": NSNull()]) }
        let vm = LocalMemoriesViewModel(api: fake)
        await vm.loadBody(ref)
        vm.stop()
        XCTAssertNil(vm.bodies[ref], "the file may change on the box before the next visit")
    }
}

final class MemoryOverlapIndexTests: XCTestCase {
    private func journal(_ name: String, _ description: String) -> Memory {
        Memory(id: "me_\(name)", name: name, type: .feedback, description: description,
               createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    func test_match_namesTheJournalMemorySharingMostWords() {
        let index = MemoryOverlapIndex(memories: [
            journal("merge-train-owns-merges", "yearbook-app merges run in batches through greg's merge train"),
            journal("prod-deploys-only-via-deploy-1", "Production deploys only from deploy-1, as the batch deploy"),
        ])
        XCTAssertEqual(index.match("Merge train: merges run in one batch, one CircleCI run per train"),
                       "merge-train-owns-merges")
        XCTAssertNil(index.match("Psalm dies silently next to jest or a bloated php-fpm container"))
    }

    func test_match_ignoresFillerWordsAndShortTexts() {
        let index = MemoryOverlapIndex(memories: [journal("a", "You should always use the box for this and that")])
        XCTAssertNil(index.match("You should always use this and that for the thing"),
                     "filler alone is not an overlap")
        XCTAssertNil(index.match("box"), "too short to compare")
    }

    func test_match_usesADescriptionlessMemorysTitleAndHook() {
        let index = MemoryOverlapIndex(memories: [journal("full-pr-urls", "Give PRs as full URLs in chat and item bodies")])
        let entry = LocalMemoryEntry(file: "x.md", path: "/x.md", name: "x", title: "Full PR URLs",
                                     hook: "PRs go in chat as full URLs", modifiedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(index.match(entry), "full-pr-urls")
    }
}

final class LocalMemoryWireTests: XCTestCase {
    func test_page_dropsMalformedRows_andReadsNullsAsAbsent() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "home": "/home/dan",
            "claude_md": [["size": 1], ["path": "/home/dan/.claude/CLAUDE.md", "size": 3, "mtime": 2000]],
            "projects": [
                ["dir": "", "memory_dir": "/m"],
                ["dir": "-d", "path": NSNull(), "memory_dir": "/m", "index": NSNull(), "offset": 0, "more": 0,
                 "memories": [["name": "nofile"], ["file": "bare.md", "mtime": 1000]]],
            ],
        ])
        let page = try XCTUnwrap(LocalMemoriesPage(data: data))
        XCTAssertEqual(page.claudeMD.map(\.path), ["/home/dan/.claude/CLAUDE.md"])
        XCTAssertEqual(page.claudeMD[0].modifiedAt, Date(timeIntervalSince1970: 2))
        XCTAssertNil(page.claudeMD[0].folder)
        XCTAssertEqual(page.projects.count, 1)
        XCTAssertNil(page.projects[0].path)
        let memory = try XCTUnwrap(page.projects[0].memories.first)
        XCTAssertEqual(page.projects[0].memories.count, 1)
        XCTAssertEqual(memory.name, "bare", "a memory with no frontmatter is named by its file")
        XCTAssertEqual(memory.title, "bare")
        XCTAssertEqual(memory.path, "/m/bare.md")
        XCTAssertEqual(page.moreClaudeMD, 0)
        XCTAssertTrue(page.moreProjects.isEmpty)
    }

    func test_page_isNilForANonObject() {
        XCTAssertNil(LocalMemoriesPage(data: Data("[]".utf8)))
        XCTAssertNil(LocalMemoryBodyPage(data: Data(#"{"path":"/p"}"#.utf8)))
    }

    func test_shortened_onlyUnderHome() {
        XCTAssertEqual(LocalMemoryGrouping.shortened("/home/dan/app", home: "/home/dan"), "~/app")
        XCTAssertEqual(LocalMemoryGrouping.shortened("/home/dana/app", home: "/home/dan"), "/home/dana/app")
        XCTAssertEqual(LocalMemoryGrouping.shortened("/srv/app", home: nil), "/srv/app")
    }
}

@MainActor
final class LocalMemoriesSectionTests: XCTestCase {
    private func journal(_ name: String, _ description: String) -> Memory {
        Memory(id: "me_\(name)", name: name, type: .feedback, description: description,
               createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    private func viewModel(memories count: Int) async -> LocalMemoriesViewModel {
        let fake = FakeBoxes()
        fake.devicesResult = .success([box(1, "ang"), box(2, "bev"), box(3, "pat", connected: false)])
        fake.handler = { id, _, _ in
            if id == 2 {
                return ok(["home": "/home/dan", "claude_md": [],
                           "projects": [projectJSON("-home-dan-app", path: "/home/dan/app", memories: [memoryJSON("z.md")])]])
            }
            var memories = [memoryJSON("train.md", title: "Merge train: single CI run",
                                       description: "Merges run in one batch through the merge train")]
            memories += (1..<count).map { memoryJSON("m\($0).md") }
            return ok(["home": "/home/dan",
                       "claude_md": [["path": "/home/dan/.claude/CLAUDE.md", "size": 1203, "mtime": 1],
                                     ["path": "/home/dan/app/CLAUDE.md", "size": 30878, "mtime": 1, "folder": "/home/dan/app"]],
                       "projects": [projectJSON("-home-dan-app", path: "/home/dan/app", memories: memories)]])
        }
        let vm = LocalMemoriesViewModel(api: fake)
        vm.start()
        await vm.loadTaskForTesting?.value
        return vm
    }

    func test_section_listsTheSelectedBoxsFirstRows_withChipsOverlapAndFooter() async {
        let vm = await viewModel(memories: 12)
        let train = journal("merge-train-owns-merges", "yearbook-app merges run in batches through greg's merge train")
        let selected = LocalMemoryRef(boxID: 1, path: "/home/dan/app/CLAUDE.md")
        let section = vm.section(journal: [train], selected: selected)

        XCTAssertEqual(section.groups.map(\.title), ["app", "Global CLAUDE.md"])
        let app = section.groups[0]
        XCTAssertTrue(app.isExpanded)
        XCTAssertEqual(app.countLine, "14 on 2 boxes")
        XCTAssertEqual(app.chips, [.init(boxID: 1, name: "ang", count: 13, isSelected: true),
                                   .init(boxID: 2, name: "bev", count: 1, isSelected: false)])
        XCTAssertEqual(app.rows.count, LocalMemoriesViewModel.rowLimit)
        XCTAssertEqual(app.hiddenCount, 13 - LocalMemoriesViewModel.rowLimit)
        XCTAssertEqual(app.selectedBoxName, "ang")
        XCTAssertEqual(app.rows[0].title, "CLAUDE.md", "the repo's CLAUDE.md leads its memories")
        XCTAssertEqual(app.rows[0].summary, "Repo instructions · 30 KB")
        XCTAssertTrue(app.rows[0].isSelected)
        XCTAssertEqual(app.rows[1].title, "Merge train: single CI run")
        XCTAssertEqual(app.rows[1].overlap, "merge-train-owns-merges")
        XCTAssertNil(app.rows[2].overlap)
        XCTAssertTrue(section.groups[1].rows.isEmpty, "a closed group builds no rows")
        XCTAssertEqual(section.boxNotes, ["Asleep: pat. Wake a box to read its memories."])

        vm.showAll(in: app.id)
        XCTAssertEqual(vm.section(journal: nil).groups[0].rows.count, 13)
        XCTAssertEqual(vm.section(journal: nil).groups[0].hiddenCount, 0)

        vm.selectBox(2, in: app.id)
        XCTAssertEqual(vm.section(journal: nil).groups[0].rows.map(\.title), ["z"])

        vm.toggle(section.groups[1].id)
        let global = vm.section(journal: nil).groups[1]
        XCTAssertEqual(global.countLine, "1 box")
        XCTAssertEqual(global.rows.map(\.summary), ["This box's own instructions · 1.2 KB"])
    }

    func test_overlapForRef_isForMemoriesOnly() async {
        let vm = await viewModel(memories: 1)
        let train = journal("merge-train-owns-merges", "yearbook-app merges run in batches through greg's merge train")
        XCTAssertEqual(vm.overlap(for: LocalMemoryRef(boxID: 1, path: "/home/dan/.claude/projects/-home-dan-app/memory/train.md"),
                                  journal: [train]), "merge-train-owns-merges")
        XCTAssertNil(vm.overlap(for: LocalMemoryRef(boxID: 1, path: "/home/dan/app/CLAUDE.md"), journal: [train]))
    }
}

@MainActor
final class LocalMemoriesReloadTests: XCTestCase {
    /// A refresh keeps what each box listed until its new answer lands, and
    /// the load it replaces — whose cancelled legs answer as failures —
    /// changes nothing.
    func test_reload_keepsWhatABoxListedUntilItsNewAnswerLands() async {
        let fake = FakeBoxes()
        fake.devicesResult = .success([box(1, "ang")])
        fake.handler = { _, _, _ in
            ok(["home": "/home/dan", "claude_md": [],
                "projects": [projectJSON("-home-dan-app", path: "/home/dan/app", memories: [memoryJSON("a.md")])]])
        }
        let vm = LocalMemoriesViewModel(api: fake)
        vm.start()
        await vm.loadTaskForTesting?.value
        XCTAssertEqual(vm.groups.first?.total, 1)

        fake.handler = { _, _, _ in throw RPCRequestError.offline }
        vm.reload()
        let failing = vm.loadTaskForTesting
        fake.handler = { _, _, _ in
            ok(["home": "/home/dan", "claude_md": [],
                "projects": [projectJSON("-home-dan-app", path: "/home/dan/app",
                                         memories: [memoryJSON("a.md"), memoryJSON("b.md")])]])
        }
        vm.reload()
        await failing?.value
        XCTAssertEqual(vm.groups.first?.total, 1, "the superseded load's failure is dropped")
        XCTAssertTrue(vm.failedBoxNames.isEmpty)
        await vm.loadTaskForTesting?.value
        XCTAssertEqual(vm.groups.first?.total, 2)
        XCTAssertFalse(vm.isLoading)
    }
}

@MainActor
final class LocalMemoriesStopTests: XCTestCase {
    /// The load `start()` (or a refresh) queued has not begun when the
    /// screen closes: it must not go on to ask the boxes (Bugbot, PR 318).
    func test_stopBeforeTheQueuedLoadBegins_asksNothing() async {
        let fake = FakeBoxes()
        fake.devicesResult = .success([box(1, "ang")])
        fake.handler = { _, _, _ in ok(["home": "/home/dan", "claude_md": [], "projects": []]) }
        let vm = LocalMemoriesViewModel(api: fake)
        vm.start()
        let queued = vm.loadTaskForTesting
        vm.stop()
        await queued?.value

        XCTAssertTrue(fake.requests.isEmpty)
        XCTAssertFalse(vm.hasLoaded)
        XCTAssertFalse(vm.isLoading)

        vm.reload()
        XCTAssertNil(vm.loadTaskForTesting, "a refresh after the screen closed asks nothing either")
    }
}

final class LocalMemoriesEmptyNoteTests: XCTestCase {
    private func section(answered: Int = 0, loading: [String] = [], asleep: [String] = [],
                         outdated: [String] = [], failed: [String] = [], isLoading: Bool = false,
                         hasLoaded: Bool = true, loadError: String? = nil) -> LocalMemoriesSection {
        LocalMemoriesSection(hasLoaded: hasLoaded, isLoading: isLoading, loadError: loadError,
                             answeredBoxCount: answered, loadingBoxes: loading, asleepBoxes: asleep,
                             outdatedBoxes: outdated, failedBoxes: failed)
    }

    /// Online boxes that list nothing, beside asleep ones, are not "none
    /// of your boxes is online" (Bugbot, PR 318).
    func test_boxesThatAnsweredWithNothing_sayJustThat_whateverTheOthersDo() {
        XCTAssertEqual(section(answered: 2, asleep: ["pat"]).emptyNote, LocalMemoriesSection.noMemoriesText)
        XCTAssertEqual(section(answered: 1, outdated: ["mavis"], failed: ["greg"]).emptyNote,
                       LocalMemoriesSection.noMemoriesText)
    }

    func test_noBoxAnswered() {
        XCTAssertEqual(section(asleep: ["pat", "terry"]).emptyNote, LocalMemoriesSection.noneOnlineText)
        XCTAssertEqual(section().emptyNote, LocalMemoriesSection.noBoxesText)
        XCTAssertNil(section(asleep: ["pat"], failed: ["greg"]).emptyNote, "the box notes already say why")
        XCTAssertNil(section(outdated: ["mavis"]).emptyNote)
    }

    func test_nothingIsSaidWhileStillFindingOut_orOverAnErrorOrGroups() {
        XCTAssertNil(section(answered: 1, isLoading: true).emptyNote)
        XCTAssertNil(section(hasLoaded: false).emptyNote)
        XCTAssertNil(section(loadError: "offline").emptyNote)
        var withGroups = section(answered: 1)
        withGroups.groups = [.init(id: "app", title: "app", path: nil, countLine: "1 on 1 box",
                                   isExpanded: false, chips: [], rows: [])]
        XCTAssertNil(withGroups.emptyNote)
    }
}
