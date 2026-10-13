import Foundation

/// The Projects home's filter field: narrows the page to what the typed
/// words name. Every word must be found, in any order, ignoring case and
/// accents. A project is kept by its title or `#num`, or by the title or
/// short name of any of its missions (closed ones too); a mission row by
/// its own title, name or `#num`. An empty query keeps everything.
public struct ProjectsHomeFilter: Equatable, Sendable {
    let terms: [String]

    public init(_ query: String) {
        terms = query.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
    }

    public var isActive: Bool { !terms.isEmpty }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Every term is in at least one of `texts`.
    func matches(_ texts: [String]) -> Bool {
        let folded = texts.map(Self.fold)
        return terms.allSatisfy { term in folded.contains { $0.contains(term) } }
    }

    func matchesTitle(of card: ProjectCard) -> Bool {
        matches([card.project.title, "#\(card.project.num)"])
    }

    public func matches(_ card: ProjectCard) -> Bool {
        matches([card.project.title, "#\(card.project.num)"] + card.missionTitles)
    }

    public func matches(_ mission: Mission) -> Bool {
        matches([mission.title, mission.name ?? "", "#\(mission.num)"])
    }

    /// Why a card is kept when its own title doesn't say: the first of its
    /// missions' titles that holds every term, else the first that holds
    /// any. Nil when the filter is off or the project's title matches.
    public func matchedMission(in card: ProjectCard) -> String? {
        guard isActive, !matchesTitle(of: card) else { return nil }
        return card.missionTitles.first { matches([$0]) }
            ?? card.missionTitles.first { title in
                let folded = Self.fold(title)
                return terms.contains { folded.contains($0) }
            }
    }

    /// The page with only what matches, in the same order except that
    /// projects named by their own title come before those found through
    /// a mission.
    public func apply(to home: ProjectsHomeSnapshot) -> ProjectsHomeSnapshot {
        guard isActive else { return home }
        let kept = home.cards.filter(matches)
        var filtered = home
        filtered.cards = kept.filter(matchesTitle) + kept.filter { !matchesTitle(of: $0) }
        filtered.unfiled = home.unfiled.filter { matches($0.mission) }
        filtered.quiet = home.quiet.filter { matches($0.mission) }
        filtered.closed = home.closed.filter(matches)
        return filtered
    }
}
