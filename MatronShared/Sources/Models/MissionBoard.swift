import Foundation

/// The Mac mission page's Board (three kanban columns of the mission's
/// items — never its sessions). Pure, so every rule is a plain test:
///
/// - **To do**: open items awaiting the user (they need you, so they sort
///   first), then open items awaiting nobody (not picked up yet).
/// - **In progress**: open items awaiting the agent.
/// - **Done**: closed items, most recently closed first, capped at
///   `doneLimit`, with every other closed item the mission has — loaded or
///   not — counted in `moreDone` ("Show more").
///
/// A consent ask is an ordinary question item, so it lands wherever its
/// `awaiting` puts it — there is no special case.
public struct MissionBoard: Equatable, Sendable {
    public enum Column: String, CaseIterable, Sendable {
        case toDo, inProgress, done

        public var title: String {
            switch self {
            case .toDo: return "To do"
            case .inProgress: return "In progress"
            case .done: return "Done"
            }
        }
    }

    public var toDo: [TrackerItem]
    public var inProgress: [TrackerItem]
    public var done: [TrackerItem]
    /// Closed items not shown — past the cap, or not loaded yet — for
    /// "Show more" and the Done count.
    public var moreDone: Int

    public init(toDo: [TrackerItem] = [], inProgress: [TrackerItem] = [], done: [TrackerItem] = [], moreDone: Int = 0) {
        self.toDo = toDo; self.inProgress = inProgress; self.done = done; self.moreDone = moreDone
    }

    public func items(in column: Column) -> [TrackerItem] {
        switch column {
        case .toDo: return toDo
        case .inProgress: return inProgress
        case .done: return done
        }
    }

    /// How many cards a column counts in its header — Done counts every
    /// closed item it knows of, not only the ones shown.
    public func count(of column: Column) -> Int {
        column == .done ? done.count + moreDone : items(in: column).count
    }

    /// Closed items are counted but none has loaded yet (the count stream
    /// landed before the closed-items stream): Done is loading, not empty.
    public var isDoneLoading: Bool { done.isEmpty && moreDone > 0 }

    /// "Show more" is offered only past cards already shown — with none
    /// shown there is nothing to show more of, only loading.
    public var showsMoreDone: Bool { !done.isEmpty && moreDone > 0 }

    /// How many Done cards the board shows before "Show more", and how
    /// many more each tap reveals.
    public static let donePageSize = 10

    /// Groups `open` and `closed` (either may hold an item the other also
    /// holds mid-transition: the newer `updatedAt` wins, and the item's own
    /// `state` decides its column). `closed` may be a prefix of the
    /// mission's closed items; `closedTotal` is how many there are in all
    /// (`nil`: `closed` is all of them).
    public static func assemble(open: [TrackerItem], closed: [TrackerItem], closedTotal: Int? = nil,
                                doneLimit: Int) -> MissionBoard {
        var byID: [String: TrackerItem] = [:]
        for item in open + closed {
            if let existing = byID[item.id], existing.updatedAt >= item.updatedAt { continue }
            byID[item.id] = item
        }
        var toDo: [TrackerItem] = [], inProgress: [TrackerItem] = [], done: [TrackerItem] = []
        for item in byID.values {
            switch (item.state, item.awaiting) {
            case (.closed, _): done.append(item)
            case (.open, .agent): inProgress.append(item)
            case (.open, .user), (.open, nil): toDo.append(item)
            }
        }
        toDo.sort { a, b in
            let (userA, userB) = (a.awaiting == .user, b.awaiting == .user)
            if userA != userB { return userA }
            return newerFirst(a, b, a.updatedAt, b.updatedAt)
        }
        inProgress.sort { newerFirst($0, $1, $0.updatedAt, $1.updatedAt) }
        done.sort { newerFirst($0, $1, closedTime($0), closedTime($1)) }
        let shown = Array(done.prefix(max(0, doneLimit)))
        let total = max(closedTotal ?? 0, done.count)
        return MissionBoard(toDo: toDo, inProgress: inProgress, done: shown, moreDone: total - shown.count)
    }

    /// When an item closed, for ordering and its meta line; `updatedAt`
    /// for a row that predates `closed_at`.
    public static func closedTime(_ item: TrackerItem) -> Date { item.closedAt ?? item.updatedAt }

    private static func newerFirst(_ a: TrackerItem, _ b: TrackerItem, _ dateA: Date, _ dateB: Date) -> Bool {
        if dateA != dateB { return dateA > dateB }
        return a.num > b.num
    }

    // MARK: Card meta line

    /// The card's grey line under the title — who has it and since when:
    /// "Needs you · 3h", "Not started · 14h", "dan-mac · 20m" (or
    /// "Agent · 20m" when the working box is unknown), "Answered · 30m ago".
    /// An open decision awaiting nobody is a standing record, not work
    /// waiting to start: "Decision · 14h".
    /// `boxName` is the box of the item's origin conversation, when known.
    public static func meta(for item: TrackerItem, boxName: String?, now: Date) -> String {
        switch (item.state, item.awaiting) {
        case (.closed, _):
            let what = item.resolution.map(resolutionLabel) ?? "Closed"
            let when = ago(closedTime(item), now: now)
            return "\(what) · \(when == "now" ? "just now" : "\(when) ago")"
        case (.open, .user):
            return "Needs you · \(ago(item.updatedAt, now: now))"
        case (.open, .agent):
            let who = boxName.flatMap { $0.isEmpty ? nil : $0 } ?? "Agent"
            return "\(who) · \(ago(item.updatedAt, now: now))"
        case (.open, nil):
            let what = item.kind == .decision ? "Decision" : "Not started"
            return "\(what) · \(ago(item.createdAt, now: now))"
        }
    }

    public static func resolutionLabel(_ resolution: ItemResolution) -> String {
        switch resolution {
        case .done: return "Done"
        case .answered: return "Answered"
        case .decided: return "Decided"
        case .reversed: return "Reversed"
        case .cancelled: return "Cancelled"
        }
    }

    /// "now", "12m", "3h", "2d" — then weeks. Short on purpose: a card's
    /// meta line is one line.
    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<(86_400 * 7): return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / (86_400 * 7)))w"
        }
    }
}
