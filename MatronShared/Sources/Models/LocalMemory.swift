import Foundation

/// A box's own Claude Code memories, as its bridge lists them over the
/// agent RPC `local_memories` (matron-bridge spec 2026-09-29): the
/// CLAUDE.md files and, per project, the files under
/// `~/.claude/projects/<project>/memory/`. Read-only — these are files on
/// that box, edited by an agent there. The journal's memories are `Memory`.

/// One file a box can serve with `local_memory_get`: a CLAUDE.md, or a
/// project's `MEMORY.md` index.
public struct LocalMemoryFile: Equatable, Hashable, Sendable {
    public let path: String
    public let size: Int
    public let modifiedAt: Date
    /// The repo a CLAUDE.md belongs to; `nil` for the box's global
    /// `~/.claude/CLAUDE.md` (and for a `MEMORY.md` index).
    public let folder: String?

    public init(path: String, size: Int, modifiedAt: Date, folder: String? = nil) {
        self.path = path; self.size = size; self.modifiedAt = modifiedAt; self.folder = folder
    }

    public init?(json: [String: Any]) {
        guard let path = json["path"] as? String, !path.isEmpty else { return nil }
        self.init(path: path, size: (json["size"] as? NSNumber)?.intValue ?? 0,
                  modifiedAt: LocalMemoryWire.date(json["mtime"]), folder: json["folder"] as? String)
    }
}

/// One memory file in a project's memory directory.
public struct LocalMemoryEntry: Equatable, Hashable, Sendable {
    /// The file name inside the project's memory directory.
    public let file: String
    /// The absolute path `local_memory_get` takes.
    public let path: String
    public let name: String
    /// The index line's title, or the bridge's humanised name.
    public let title: String
    /// The frontmatter's one-line description.
    public let description: String
    /// The frontmatter's `metadata.type` as the box wrote it, if any.
    public let type: String?
    /// The index line's hook, if the index names this file.
    public let hook: String
    public let size: Int
    public let modifiedAt: Date

    public init(file: String, path: String, name: String, title: String, description: String = "",
                type: String? = nil, hook: String = "", size: Int = 0, modifiedAt: Date) {
        self.file = file; self.path = path; self.name = name; self.title = title
        self.description = description; self.type = type; self.hook = hook
        self.size = size; self.modifiedAt = modifiedAt
    }

    public init?(json: [String: Any], memoryDir: String) {
        guard let file = json["file"] as? String, !file.isEmpty else { return nil }
        let stem = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
        let name = LocalMemoryWire.text(json["name"]) ?? stem
        self.init(file: file, path: memoryDir + "/" + file, name: name,
                  title: LocalMemoryWire.text(json["title"]) ?? name,
                  description: LocalMemoryWire.text(json["description"]) ?? "",
                  type: LocalMemoryWire.text(json["type"]),
                  hook: LocalMemoryWire.text(json["hook"]) ?? "",
                  size: (json["size"] as? NSNumber)?.intValue ?? 0,
                  modifiedAt: LocalMemoryWire.date(json["mtime"]))
    }

    /// The line under the title: the index hook, else the description.
    public var summary: String { hook.isEmpty ? description : hook }
}

/// One `~/.claude/projects/<dir>/memory/` directory on a box.
public struct LocalMemoryProject: Equatable, Sendable {
    /// Claude Code's directory name for the project (lossy, never decoded).
    public let dir: String
    /// The folder `dir` encodes, when the box knows it.
    public let path: String?
    public let memoryDir: String
    /// The `MEMORY.md` index, if there is one.
    public let index: LocalMemoryFile?
    /// How many newest-first memories this page skipped.
    public let offset: Int
    public var memories: [LocalMemoryEntry]
    /// How many more memories follow this page.
    public var more: Int

    public init(dir: String, path: String?, memoryDir: String, index: LocalMemoryFile? = nil,
                offset: Int = 0, memories: [LocalMemoryEntry], more: Int = 0) {
        self.dir = dir; self.path = path; self.memoryDir = memoryDir; self.index = index
        self.offset = offset; self.memories = memories; self.more = more
    }

    public init?(json: [String: Any]) {
        guard let dir = json["dir"] as? String, !dir.isEmpty,
              let memoryDir = json["memory_dir"] as? String, !memoryDir.isEmpty else { return nil }
        let rows = json["memories"] as? [[String: Any]] ?? []
        self.init(dir: dir, path: LocalMemoryWire.text(json["path"]), memoryDir: memoryDir,
                  index: (json["index"] as? [String: Any]).flatMap(LocalMemoryFile.init(json:)),
                  offset: max(0, (json["offset"] as? NSNumber)?.intValue ?? 0),
                  memories: rows.compactMap { LocalMemoryEntry(json: $0, memoryDir: memoryDir) },
                  more: max(0, (json["more"] as? NSNumber)?.intValue ?? 0))
    }
}

/// One `local_memories` reply. A full reply carries both lists; a project
/// page carries no `claude_md`, and a `claude_md_offset` page no `projects`.
public struct LocalMemoriesPage: Equatable, Sendable {
    public let home: String?
    public let claudeMD: [LocalMemoryFile]
    public let projects: [LocalMemoryProject]
    /// Whole projects the frame cap dropped; each is fetched by `dir`.
    public let moreProjects: [String]
    /// How many CLAUDE.md entries follow this page.
    public let moreClaudeMD: Int

    public init(home: String? = nil, claudeMD: [LocalMemoryFile] = [], projects: [LocalMemoryProject] = [],
                moreProjects: [String] = [], moreClaudeMD: Int = 0) {
        self.home = home; self.claudeMD = claudeMD; self.projects = projects
        self.moreProjects = moreProjects; self.moreClaudeMD = moreClaudeMD
    }

    /// `nil` when the reply is not a JSON object. Single malformed rows are
    /// dropped rather than failing the box.
    public init?(data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        self.init(home: LocalMemoryWire.text(json["home"]),
                  claudeMD: (json["claude_md"] as? [[String: Any]] ?? []).compactMap(LocalMemoryFile.init(json:)),
                  projects: (json["projects"] as? [[String: Any]] ?? []).compactMap(LocalMemoryProject.init(json:)),
                  moreProjects: (json["more_projects"] as? [Any] ?? []).compactMap { $0 as? String },
                  moreClaudeMD: max(0, (json["more_claude_md"] as? NSNumber)?.intValue ?? 0))
    }
}

/// Everything one box listed, after every page has been read.
public struct LocalMemoriesIndex: Equatable, Sendable {
    public var home: String?
    public var claudeMD: [LocalMemoryFile]
    public var projects: [LocalMemoryProject]

    public init(home: String? = nil, claudeMD: [LocalMemoryFile] = [], projects: [LocalMemoryProject] = []) {
        self.home = home; self.claudeMD = claudeMD; self.projects = projects
    }
}

/// One `local_memory_get` reply: a page of a file's text. `offset` and
/// `nextOffset` are UTF-16 code-unit indices into the decoded text.
public struct LocalMemoryBodyPage: Equatable, Sendable {
    public let body: String
    public let nextOffset: Int?

    public init(body: String, nextOffset: Int?) {
        self.body = body; self.nextOffset = nextOffset
    }

    public init?(data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let body = json["body"] as? String else { return nil }
        self.init(body: body, nextOffset: (json["next_offset"] as? NSNumber)?.intValue)
    }
}

/// Which file on which box — the key a body is loaded and selected by.
public struct LocalMemoryRef: Equatable, Hashable, Sendable {
    public let boxID: Int64
    public let path: String

    public init(boxID: Int64, path: String) {
        self.boxID = boxID; self.path = path
    }
}

enum LocalMemoryWire {
    /// A non-empty string, or `nil` (the bridge sends `null` for unknowns).
    static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// `mtime` is ms since the epoch; a missing one reads as the epoch.
    static func date(_ value: Any?) -> Date {
        Date(timeIntervalSince1970: ((value as? NSNumber)?.doubleValue ?? 0) / 1000)
    }
}

// MARK: Grouping (by repo, then box)

/// One box's share of a repo group: its CLAUDE.md files there and its
/// memory files, newest first as the bridge lists them.
public struct LocalMemoryBoxSlice: Equatable, Sendable, Identifiable {
    public var id: Int64 { boxID }
    public let boxID: Int64
    public let boxName: String
    public var files: [LocalMemoryFile]
    public var memories: [LocalMemoryEntry]

    public init(boxID: Int64, boxName: String, files: [LocalMemoryFile] = [], memories: [LocalMemoryEntry] = []) {
        self.boxID = boxID; self.boxName = boxName; self.files = files; self.memories = memories
    }

    /// What the box's chip counts: every file listed for this repo.
    public var count: Int { files.count + memories.count }
}

/// One repo across the boxes that have memories for it — or the global
/// CLAUDE.md group, one file per box.
public struct LocalMemoryRepoGroup: Equatable, Sendable, Identifiable {
    /// Not a possible last path component, so no repo can collide with it.
    public static let globalID = "//global"

    public let id: String
    public let title: String
    /// The folder as the first box names it, home shortened to `~`.
    public let path: String?
    /// Sorted by box name.
    public var boxes: [LocalMemoryBoxSlice]

    public init(id: String, title: String, path: String?, boxes: [LocalMemoryBoxSlice]) {
        self.id = id; self.title = title; self.path = path; self.boxes = boxes
    }

    public var isGlobal: Bool { id == Self.globalID }
    public var total: Int { boxes.reduce(0) { $0 + $1.count } }

    /// "248 on 7 boxes"; the global group counts boxes only.
    public var countLine: String {
        let boxCount = "\(boxes.count) \(boxes.count == 1 ? "box" : "boxes")"
        return isGlobal ? boxCount : "\(total) on \(boxCount)"
    }
}

public enum LocalMemoryGrouping {
    /// Groups every loaded box's index by repo, then box.
    ///
    /// A repo is keyed by its folder's last path component, so the same
    /// repo checked out at `/home/dan/app` on one box and
    /// `/Users/dan/Dev/app` on another is one group. A project whose folder
    /// the box could not name falls back to Claude Code's directory name.
    /// Repos sort by how much they hold, then by name; the global
    /// CLAUDE.md group is last.
    public static func groups(_ boxes: [(id: Int64, name: String, index: LocalMemoriesIndex)]) -> [LocalMemoryRepoGroup] {
        var order: [String] = []
        var titles: [String: String] = [:]
        var paths: [String: String] = [:]
        var slices: [String: [Int64: LocalMemoryBoxSlice]] = [:]

        func slice(_ key: String, title: String, path: String?, box: (id: Int64, name: String, index: LocalMemoriesIndex),
                   _ change: (inout LocalMemoryBoxSlice) -> Void) {
            if titles[key] == nil {
                order.append(key)
                titles[key] = title
            }
            if paths[key] == nil, let path { paths[key] = shortened(path, home: box.index.home) }
            var entry = slices[key]?[box.id] ?? LocalMemoryBoxSlice(boxID: box.id, boxName: box.name)
            change(&entry)
            slices[key, default: [:]][box.id] = entry
        }

        for box in boxes.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            for project in box.index.projects {
                let title = project.path.map(lastComponent) ?? project.dir
                slice(title, title: title, path: project.path, box: box) { $0.memories += project.memories }
            }
            for file in box.index.claudeMD {
                if let folder = file.folder {
                    let title = lastComponent(folder)
                    slice(title, title: title, path: folder, box: box) { $0.files.append(file) }
                } else {
                    slice(LocalMemoryRepoGroup.globalID, title: "Global CLAUDE.md", path: "~/.claude/CLAUDE.md", box: box) {
                        $0.files.append(file)
                    }
                }
            }
        }

        let groups = order.map { key in
            LocalMemoryRepoGroup(id: key, title: titles[key] ?? key, path: paths[key],
                                 boxes: (slices[key] ?? [:]).values.sorted {
                                     $0.boxName.localizedStandardCompare($1.boxName) == .orderedAscending
                                 })
        }
        return groups.sorted { a, b in
            if a.isGlobal != b.isGlobal { return b.isGlobal }
            if a.total != b.total { return a.total > b.total }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    public static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// `/home/dan/repo` → `~/repo` when `home` is `/home/dan`.
    public static func shortened(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
    }
}

// MARK: Overlap with the journal's memories

/// The "≈ name" check: does a box's memory say something a journal memory
/// already says? Plain word overlap between the two one-line descriptions —
/// enough to point at a likely duplicate, not a judgement.
public struct MemoryOverlapIndex: Sendable {
    /// At least this many words in common…
    static let minimumSharedWords = 3
    /// …making up at least this share of the shorter description.
    static let minimumShare = 0.5

    private let entries: [(name: String, words: Set<String>)]

    public init(memories: [Memory]) {
        entries = memories
            .map { (name: $0.name, words: Self.words($0.description)) }
            .filter { !$0.words.isEmpty }
            .sorted { $0.name < $1.name }
    }

    /// The journal memory this text overlaps most, or `nil`.
    public func match(_ text: String) -> String? {
        let words = Self.words(text)
        guard words.count >= Self.minimumSharedWords else { return nil }
        var best: (name: String, share: Double)?
        for entry in entries {
            let shared = words.intersection(entry.words).count
            guard shared >= Self.minimumSharedWords else { continue }
            let share = Double(shared) / Double(min(words.count, entry.words.count))
            guard share >= Self.minimumShare else { continue }
            if best == nil || share > best!.share { best = (entry.name, share) }
        }
        return best?.name
    }

    public func match(_ entry: LocalMemoryEntry) -> String? {
        match(entry.description.isEmpty ? entry.title + " " + entry.hook : entry.description)
    }

    /// Lowercased words of three letters or more, without the commonest
    /// English filler — which would otherwise make any two sentences overlap.
    static func words(_ text: String) -> Set<String> {
        var words = Set<String>()
        for piece in text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) where piece.count >= 3 {
            let word = String(piece)
            if !stopWords.contains(word) { words.insert(word) }
        }
        return words
    }

    static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "from", "are", "was", "were", "not", "but", "you", "your",
        "all", "any", "can", "has", "have", "had", "its", "use", "uses", "used", "using", "when", "then", "than",
        "into", "over", "only", "never", "always", "must", "should", "will", "they", "them", "their", "there",
        "what", "which", "who", "how", "why", "does", "don", "one", "per", "via", "out", "off", "each", "every",
        "after", "before", "also", "been", "being", "some", "such", "these", "those", "where", "while", "would",
    ]
}

// MARK: What the "On your boxes" section shows

/// The Memories screen's "On your boxes" section, ready to draw: built by
/// `LocalMemoriesViewModel.section(...)`, drawn by `LocalMemoriesSectionRows`.
public struct LocalMemoriesSection: Equatable, Sendable {
    public struct Chip: Equatable, Sendable, Identifiable {
        public var id: Int64 { boxID }
        public let boxID: Int64
        public let name: String
        public let count: Int
        public let isSelected: Bool

        public init(boxID: Int64, name: String, count: Int, isSelected: Bool) {
            self.boxID = boxID; self.name = name; self.count = count; self.isSelected = isSelected
        }
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public var id: LocalMemoryRef { ref }
        public let ref: LocalMemoryRef
        public let title: String
        /// The hook, or the description; for a CLAUDE.md, what it is.
        public let summary: String
        /// The journal memory this one's words overlap ("≈ name").
        public let overlap: String?
        public let isSelected: Bool

        public init(ref: LocalMemoryRef, title: String, summary: String, overlap: String? = nil, isSelected: Bool = false) {
            self.ref = ref; self.title = title; self.summary = summary; self.overlap = overlap; self.isSelected = isSelected
        }
    }

    public struct Group: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let path: String?
        public let countLine: String
        public let isExpanded: Bool
        public let chips: [Chip]
        /// The selected box's rows — the first few, or all of them.
        public let rows: [Row]
        /// How many of the selected box's rows are not listed yet.
        public let hiddenCount: Int
        public let selectedBoxName: String?

        public init(id: String, title: String, path: String?, countLine: String, isExpanded: Bool,
                    chips: [Chip], rows: [Row], hiddenCount: Int = 0, selectedBoxName: String? = nil) {
            self.id = id; self.title = title; self.path = path; self.countLine = countLine
            self.isExpanded = isExpanded; self.chips = chips; self.rows = rows
            self.hiddenCount = hiddenCount; self.selectedBoxName = selectedBoxName
        }
    }

    public var groups: [Group]
    /// False until the roster has been read once.
    public var hasLoaded: Bool
    public var isLoading: Bool
    public var loadError: String?
    /// How many boxes answered with their index (whatever it held).
    public var answeredBoxCount: Int
    public var loadingBoxes: [String]
    public var asleepBoxes: [String]
    public var outdatedBoxes: [String]
    public var failedBoxes: [String]

    public init(groups: [Group] = [], hasLoaded: Bool = false, isLoading: Bool = false, loadError: String? = nil,
                answeredBoxCount: Int = 0, loadingBoxes: [String] = [], asleepBoxes: [String] = [],
                outdatedBoxes: [String] = [], failedBoxes: [String] = []) {
        self.groups = groups; self.hasLoaded = hasLoaded; self.isLoading = isLoading; self.loadError = loadError
        self.answeredBoxCount = answeredBoxCount
        self.loadingBoxes = loadingBoxes; self.asleepBoxes = asleepBoxes; self.outdatedBoxes = outdatedBoxes
        self.failedBoxes = failedBoxes
    }

    public static let noMemoriesText = "None of the boxes that answered has any Claude Code memories."
    public static let noneOnlineText = "None of your boxes is online."
    public static let noBoxesText = "You have no boxes yet."

    /// What to say in place of the groups when there are none, or `nil`
    /// while that is still being found out, or when the box notes below
    /// (a box that didn't answer, or needs an update) already explain it.
    public var emptyNote: String? {
        guard hasLoaded, !isLoading, groups.isEmpty, loadError == nil else { return nil }
        // A box answered and listed nothing: that is the news, whatever
        // the other boxes are doing.
        if answeredBoxCount > 0 { return Self.noMemoriesText }
        guard outdatedBoxes.isEmpty, failedBoxes.isEmpty, loadingBoxes.isEmpty else { return nil }
        return asleepBoxes.isEmpty ? Self.noBoxesText : Self.noneOnlineText
    }

    /// "1.2 KB" for a CLAUDE.md row.
    public static func sizeText(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        return kb < 10 ? String(format: "%.1f KB", kb) : "\(Int(kb.rounded())) KB"
    }

    /// The footer's notes about boxes that listed nothing, in reading order.
    public var boxNotes: [String] {
        var notes: [String] = []
        if !asleepBoxes.isEmpty {
            notes.append("Asleep: \(asleepBoxes.joined(separator: ", ")). Wake a box to read its memories.")
        }
        if !outdatedBoxes.isEmpty {
            notes.append("Needs a bridge update first: \(outdatedBoxes.joined(separator: ", ")).")
        }
        if !failedBoxes.isEmpty {
            notes.append("Didn't answer: \(failedBoxes.joined(separator: ", ")).")
        }
        return notes
    }
}

// MARK: What the detail pane shows

/// One box file as the detail pane draws it: built by
/// `LocalMemoriesViewModel.detail(...)`, drawn by `LocalMemoryDetailView`.
public struct LocalMemoryDetail: Equatable, Sendable {
    public enum TextState: Equatable, Sendable {
        case loading
        case loaded(String)
        case failed(String)
    }

    public var boxName: String
    public var title: String
    public var repoTitle: String
    public var shortPath: String
    /// The memory's type as the box wrote it; `nil` for a CLAUDE.md.
    public var type: String?
    public var modifiedAt: Date?
    /// `true` for a memory file (which can overlap a journal memory),
    /// `false` for a CLAUDE.md.
    public var isMemory: Bool
    /// The journal memory this one's words overlap.
    public var overlap: String?
    public var text: TextState

    public init(boxName: String, title: String, repoTitle: String, shortPath: String, type: String? = nil,
                modifiedAt: Date? = nil, isMemory: Bool, overlap: String? = nil, text: TextState) {
        self.boxName = boxName; self.title = title; self.repoTitle = repoTitle; self.shortPath = shortPath
        self.type = type; self.modifiedAt = modifiedAt; self.isMemory = isMemory
        self.overlap = overlap; self.text = text
    }
}
