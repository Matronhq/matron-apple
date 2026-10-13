import Foundation
import MatronJournal
import MatronModels

/// "Go to #N": items, missions, milestones and projects share one per-user
/// number space, so a typed number names at most one thing to open.
public enum GoToNumber {
    /// The number in what the user typed: `412` or `#412`, with any
    /// whitespace around it. Anything else — words, a sign, a decimal, `#`
    /// alone, zero — is not a number to go to.
    public static func parse(_ text: String) -> Int? {
        var digits = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let num = Int(digits), num > 0 else { return nil }
        return num
    }
}

/// What a number turned out to be, before anything is opened: enough for a
/// search row ("#412 · Item — Fix the parser").
public struct GoToNumberHit: Equatable, Sendable {
    public let kind: NumberLookup.Kind
    /// The number the row answers to — the one asked for, unless the
    /// journal named another (a row merged into this one).
    public let num: Int
    public let title: String?
    /// A milestone's mission, the page it opens. `nil` for every other
    /// kind, and for a milestone from a journal that did not name it.
    public let missionNum: Int?

    public init(kind: NumberLookup.Kind, num: Int, title: String? = nil, missionNum: Int? = nil) {
        self.kind = kind; self.num = num; self.title = title; self.missionNum = missionNum
    }

    /// "Item", "Mission", "Milestone", "Project".
    public var kindLabel: String { kind.rawValue.capitalized }

    /// What the number is, as the number field's row says it: the kind,
    /// then the number.
    public var heading: String { "\(kindLabel) #\(num)" }

    /// Why this cannot be opened, or `nil` when it can be tried. A
    /// milestone is read on its mission's page, and an older journal does
    /// not say which mission that is.
    public var cannotOpenReason: String? {
        guard kind == .milestone, missionNum == nil else { return nil }
        return "Its mission isn't known here, so it can't be opened."
    }

    /// The row's one line: "#412 · Item — Fix the parser".
    public var label: String {
        let head = "#\(num) · \(kindLabel)"
        guard let title, !title.isEmpty else { return head }
        return "\(head) — \(title)"
    }
}

/// Where a resolved number opens.
public enum GoToNumberTarget: Equatable, Sendable {
    case item(id: String)
    /// A mission or project page. A milestone opens its mission's.
    case page(MatronPageTarget)
}

/// Resolves a typed number to something to open.
///
/// 1. `find`: the local store first (instant, works offline) — item, then
///    mission, then project — and on a miss the journal's `GET /lookup`,
///    which also knows milestones and rows this device has not synced.
/// 2. `resolve`: once the kind is known, the number goes through the same
///    resolvers a tapped link uses (`TrackerItemLinkResolver`,
///    `PageLinkResolver`), so a row the journal named but this device lacks
///    is synced before it opens.
public struct GoToNumberResolver: Sendable {

    public enum Finding {
        case found(GoToNumberHit)
        /// The journal has no such number, or none this user may see.
        case none
        /// The store read threw or the journal could not be asked: nothing
        /// is known about the number.
        case failed(Error)
    }

    public enum Resolution {
        case open(GoToNumberTarget, GoToNumberHit)
        case none
        case lookupFailed(Error)
        /// The number is known, but its page could not be opened here; the
        /// message says why.
        case cannotOpen(String)
    }

    private let local: @Sendable (Int) throws -> GoToNumberHit?
    private let remote: @Sendable (Int) async throws -> NumberLookup
    private let items: TrackerItemLinkResolver
    private let pages: PageLinkResolver

    /// Production wiring: the session's `JournalStore`, its `JournalAPI`
    /// lookup for the signed-in user, and the link resolvers.
    public init(store: any TrackerItemNumberReading & PageNumberReading,
                lookup: @escaping @Sendable (Int) async throws -> NumberLookup,
                items: TrackerItemLinkResolver, pages: PageLinkResolver) {
        self.init(
            local: { num in
                if let item = try store.item(num: num) {
                    return GoToNumberHit(kind: .item, num: num, title: item.title)
                }
                if let mission = try store.mission(num: num) {
                    return GoToNumberHit(kind: .mission, num: num, title: mission.title)
                }
                if let project = try store.project(num: num) {
                    return GoToNumberHit(kind: .project, num: num, title: project.title)
                }
                return nil
            },
            remote: lookup, items: items, pages: pages)
    }

    /// Seam init for tests.
    public init(local: @escaping @Sendable (Int) throws -> GoToNumberHit?,
                remote: @escaping @Sendable (Int) async throws -> NumberLookup,
                items: TrackerItemLinkResolver, pages: PageLinkResolver) {
        self.local = local
        self.remote = remote
        self.items = items
        self.pages = pages
    }

    /// What `num` is, without syncing or opening anything.
    public func find(num: Int) async -> Finding {
        do {
            if let hit = try local(num) { return .found(hit) }
        } catch {
            return .failed(error)
        }
        do {
            let found = try await remote(num)
            return .found(GoToNumberHit(kind: found.kind, num: found.num ?? num, title: found.title,
                                        missionNum: found.kind == .milestone ? found.mission?.num : nil))
        } catch JournalAPIError.notFound {
            return .none
        } catch {
            return .failed(error)
        }
    }

    public func resolve(num: Int) async -> Resolution {
        switch await find(num: num) {
        case .none: return .none
        case .failed(let error): return .lookupFailed(error)
        case .found(let hit): return await open(hit)
        }
    }

    /// Where an already found number opens, syncing its row first when
    /// this device lacks it. Never `.none` or `.lookupFailed`.
    public func open(_ hit: GoToNumberHit) async -> Resolution {
        switch hit.kind {
        case .item:
            let resolution = await items.resolve(num: hit.num)
            if case .open(let id) = resolution { return .open(.item(id: id), hit) }
            return .cannotOpen(resolution.alertMessage(num: hit.num) ?? "Couldn't open item #\(hit.num).")
        case .mission:
            return await open(.mission(hit.num), hit)
        case .project:
            return await open(.project(hit.num), hit)
        case .milestone:
            // A milestone has no page of its own: its mission's is where
            // it is read. An older journal does not say which that is.
            guard let missionNum = hit.missionNum else {
                return .cannotOpen("Couldn't open milestone #\(hit.num).")
            }
            return await open(.mission(missionNum), hit)
        }
    }

    private func open(_ link: MatronPageLink, _ hit: GoToNumberHit) async -> Resolution {
        let resolution = await pages.resolve(link)
        if case .open(let target) = resolution { return .open(.page(target), hit) }
        return .cannotOpen(resolution.alertMessage(for: link) ?? "Couldn't open \(link.noun) #\(link.num).")
    }
}

extension GoToNumberResolver.Resolution {
    /// The line to show for a number that did not open, or `nil` when it
    /// did.
    public func message(num: Int) -> String? {
        switch self {
        case .open:
            return nil
        case .none:
            return GoToNumber.nothingMessage(num: num)
        case .lookupFailed:
            return GoToNumber.lookupFailedMessage(num: num)
        case .cannotOpen(let message):
            return message
        }
    }
}

extension GoToNumber {
    /// Nothing carries the number. Not an error: said in secondary text.
    static func nothingMessage(num: Int) -> String { "Nothing is numbered \(num)." }

    /// The store or the journal could not be asked.
    static func lookupFailedMessage(num: Int) -> String {
        "Couldn't look up #\(num). Try again in a moment."
    }
}

/// Drives the "Go to Number" field on both platforms: the text, and what
/// is known about the number in it. The number is looked up as it is
/// typed, so the field shows what it names before anything is opened;
/// Go (or the row) then opens it.
@Observable
@MainActor
public final class GoToNumberViewModel: Identifiable {

    /// What is shown under the field.
    public enum Status: Equatable, Sendable {
        /// Nothing typed, or not a number: nothing to say.
        case idle
        /// The number is waiting to be looked up, or being looked up.
        case looking
        case found(GoToNumberHit)
        /// Nothing carries the number. Not an error.
        case nothing(String)
        /// The number could not be looked up, or is known and could not
        /// be opened.
        case failed(String)
    }

    /// A different number takes back what was said about the old one and
    /// drops anything still in flight for it. The same number typed
    /// another way (a trailing space, a `#`) keeps its answer.
    public var text: String {
        didSet {
            guard text != oldValue else { return }
            let num = GoToNumber.parse(text)
            guard num != GoToNumber.parse(oldValue) else { return }
            generation &+= 1
            isOpening = false
            status = num == nil ? .idle : .looking
        }
    }
    public private(set) var status: Status
    /// Go was pressed and its target is being found or synced.
    public private(set) var isOpening = false

    private let debounce: Duration
    private let find: @Sendable (Int) async -> GoToNumberResolver.Finding
    private let locate: @Sendable (GoToNumberHit) async -> GoToNumberResolver.Resolution
    private let open: (GoToNumberTarget) -> Void
    /// Bumped by every lookup, every `submit()`, every change of number
    /// and by `cancel()`; an answer only lands while its run is still the
    /// latest, so one for an older number, or one that arrives after
    /// Cancel, shows and opens nothing.
    private var generation = 0

    /// - Parameters:
    ///   - text: what the field starts with — empty, or the number a
    ///     search row named.
    ///   - debounce: how long the number must stand before it is looked
    ///     up.
    ///   - find: what a number is, without syncing or opening anything.
    ///   - locate: where a found number opens, syncing its row if needed.
    ///   - open: navigates to the target. The host dismisses the field
    ///     when `submit()` returns `true`.
    public init(text: String = "", debounce: Duration = .milliseconds(200),
                find: @escaping @Sendable (Int) async -> GoToNumberResolver.Finding,
                locate: @escaping @Sendable (GoToNumberHit) async -> GoToNumberResolver.Resolution,
                open: @escaping (GoToNumberTarget) -> Void) {
        self.text = text
        self.status = GoToNumber.parse(text) == nil ? .idle : .looking
        self.debounce = debounce
        self.find = find
        self.locate = locate
        self.open = open
    }

    public convenience init(text: String = "", debounce: Duration = .milliseconds(200),
                            resolver: GoToNumberResolver, open: @escaping (GoToNumberTarget) -> Void) {
        self.init(text: text, debounce: debounce, find: { await resolver.find(num: $0) },
                  locate: { await resolver.open($0) }, open: open)
    }

    /// Whether Go has anything to act on: a number, not already being
    /// opened, and not one known to have nowhere to open.
    public var canGo: Bool {
        guard !isOpening, GoToNumber.parse(text) != nil else { return false }
        if case .found(let hit) = status { return hit.cannotOpenReason == nil }
        return true
    }

    /// Looks the current number up, after `debounce`, and says what it
    /// is. Call it from a task keyed on the text (`.task(id:)`), so a
    /// newer keystroke cancels this run while it is still waiting. A
    /// number already answered is not asked about again.
    public func lookUp() async {
        guard !isOpening, status == .looking, let num = GoToNumber.parse(text) else { return }
        generation &+= 1
        let run = generation
        if debounce > .zero {
            // Cancelled by a newer keystroke or by the field going away.
            guard (try? await Task.sleep(for: debounce)) != nil else { return }
        }
        guard run == generation else { return }
        let finding = await find(num)
        // The number moved on, or Go took over, while this was asked.
        guard run == generation else { return }
        show(finding, num: num)
    }

    /// Opens the number: what the lookup already found, or — pressed
    /// before it answered — what an immediate one finds. `true` when it
    /// opened; otherwise `status` says why not (or it was cancelled).
    @discardableResult
    public func submit() async -> Bool {
        guard !isOpening, let num = GoToNumber.parse(text) else { return false }
        generation &+= 1
        let run = generation
        isOpening = true
        let hit: GoToNumberHit
        if case .found(let known) = status {
            hit = known
        } else {
            status = .looking
            let finding = await find(num)
            guard run == generation else { return false }
            guard let found = show(finding, num: num) else {
                isOpening = false
                return false
            }
            hit = found
        }
        guard hit.cannotOpenReason == nil else {
            isOpening = false
            return false
        }
        let resolution = await locate(hit)
        guard run == generation else { return false }
        isOpening = false
        switch resolution {
        case .open(let target, _):
            open(target)
            return true
        case .none:
            status = .nothing(GoToNumber.nothingMessage(num: num))
        case .lookupFailed:
            status = .failed(GoToNumber.lookupFailedMessage(num: num))
        case .cannotOpen(let message):
            status = .failed(message)
        }
        return false
    }

    /// The field was dismissed: anything still in flight shows and opens
    /// nothing.
    public func cancel() {
        generation &+= 1
        isOpening = false
    }

    /// Says what the lookup found. Returns the hit when there is one.
    @discardableResult
    private func show(_ finding: GoToNumberResolver.Finding, num: Int) -> GoToNumberHit? {
        switch finding {
        case .found(let hit):
            status = .found(hit)
            return hit
        case .none:
            status = .nothing(GoToNumber.nothingMessage(num: num))
        case .failed:
            status = .failed(GoToNumber.lookupFailedMessage(num: num))
        }
        return nil
    }
}
