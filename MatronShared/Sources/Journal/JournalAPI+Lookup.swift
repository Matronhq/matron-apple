import Foundation

/// What `GET /lookup` says a number is. Items, missions, milestones and
/// projects share one per-user number space, so a bare `#412` names
/// exactly one of them.
public struct NumberLookup: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case item, mission, milestone, project
    }

    /// A milestone's mission: the page a milestone opens.
    public struct MissionRef: Equatable, Sendable {
        public let id: String
        public let num: Int?
        public init(id: String, num: Int?) { self.id = id; self.num = num }
    }

    public let kind: Kind
    public let id: String
    /// The number the row answers to now. Absent from an older journal;
    /// the number asked for stands in.
    public let num: Int?
    public let title: String?
    /// Only for a milestone.
    public let mission: MissionRef?
    /// The id the number used to name, when that row was merged into this
    /// one.
    public let mergedFrom: String?

    public init(kind: Kind, id: String, num: Int? = nil, title: String? = nil,
                mission: MissionRef? = nil, mergedFrom: String? = nil) {
        self.kind = kind; self.id = id; self.num = num; self.title = title
        self.mission = mission; self.mergedFrom = mergedFrom
    }
}

extension JournalAPI {
    /// Internal so `LookupAPITests` pins the decoding without an HTTP stub
    /// per shape. `owner` is not read: the apps look up their own user's
    /// numbers only.
    static func decodeLookup(_ obj: [String: Any]) throws -> NumberLookup {
        guard let kind = (obj["kind"] as? String).flatMap(NumberLookup.Kind.init(rawValue:)),
              let id = obj["id"] as? String, !id.isEmpty
        else { throw JournalAPIError.transport("malformed lookup response") }
        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mission = (obj["mission"] as? [String: Any]).flatMap { row -> NumberLookup.MissionRef? in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return NumberLookup.MissionRef(id: id, num: (row["num"] as? NSNumber)?.intValue)
        }
        return NumberLookup(kind: kind, id: id, num: (obj["num"] as? NSNumber)?.intValue,
                            title: title?.isEmpty == false ? title : nil, mission: mission,
                            mergedFrom: obj["merged_from"] as? String)
    }

    /// `GET /lookup?user=<login name>&num=<n>`: what `num` names in that
    /// user's number space. Throws `.notFound` when it names nothing the
    /// caller may see.
    public func lookup(user: String, num: Int) async throws -> NumberLookup {
        try Self.decodeLookup(try await request(path: "/lookup", query: [
            URLQueryItem(name: "user", value: user),
            URLQueryItem(name: "num", value: String(num)),
        ]))
    }
}
