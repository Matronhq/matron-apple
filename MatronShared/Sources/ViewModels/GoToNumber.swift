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

    private func open(_ hit: GoToNumberHit) async -> Resolution {
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
    /// The line to show under the field, or `nil` when the number opened.
    public func message(num: Int) -> String? {
        switch self {
        case .open:
            return nil
        case .none:
            return "No #\(num)"
        case .lookupFailed(let error):
            return "Couldn't look up #\(num) — \(error.localizedDescription)"
        case .cannotOpen(let message):
            return message
        }
    }
}

/// Drives the "Go to Number" field on both platforms: the text, the busy
/// state while the number is looked up, and the line under the field when
/// it leads nowhere ("No #412") — said in place, not in an alert, so the
/// number can be corrected and tried again.
@Observable
@MainActor
public final class GoToNumberViewModel: Identifiable {
    /// Editing the number takes back what was said about the old one, and
    /// drops a lookup of it still in flight.
    public var text: String {
        didSet {
            guard text != oldValue else { return }
            message = nil
            if isBusy { cancel() }
        }
    }
    public private(set) var message: String?
    public private(set) var isBusy = false

    private let resolve: @Sendable (Int) async -> GoToNumberResolver.Resolution
    private let open: (GoToNumberTarget) -> Void
    /// Bumped by every `submit()` and by `cancel()`; a lookup only opens
    /// its target while it is still the latest, so one that answers after
    /// Cancel, or after the number was edited, moves nothing.
    private var generation = 0

    /// - Parameters:
    ///   - text: what the field starts with — empty, or the number a
    ///     search row named.
    ///   - open: navigates to the resolved target. The host dismisses the
    ///     field when `submit()` returns `true`.
    public init(text: String = "", resolve: @escaping @Sendable (Int) async -> GoToNumberResolver.Resolution,
                open: @escaping (GoToNumberTarget) -> Void) {
        self.text = text
        self.resolve = resolve
        self.open = open
    }

    public convenience init(text: String = "", resolver: GoToNumberResolver,
                            open: @escaping (GoToNumberTarget) -> Void) {
        self.init(text: text, resolve: { await resolver.resolve(num: $0) }, open: open)
    }

    /// Whether Go has anything to act on.
    public var canGo: Bool {
        !isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let invalidMessage = "Type a number, such as 412."

    /// Looks the number up and opens it. `true` when it opened; otherwise
    /// `message` says why not (or the lookup was cancelled).
    @discardableResult
    public func submit() async -> Bool {
        guard !isBusy else { return false }
        guard let num = GoToNumber.parse(text) else {
            message = Self.invalidMessage
            return false
        }
        generation &+= 1
        let run = generation
        message = nil
        isBusy = true
        let resolution = await resolve(num)
        guard run == generation else { return false }
        isBusy = false
        if case .open(let target, _) = resolution {
            open(target)
            return true
        }
        message = resolution.message(num: num)
        return false
    }

    /// The field was dismissed: a lookup still in flight opens nothing.
    public func cancel() {
        generation &+= 1
        isBusy = false
    }
}
