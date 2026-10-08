import Foundation

/// One Coordinator briefing (journal "Coordinator briefings"): the sweep or
/// status update the Coordinator published, as markdown. Publishing also
/// appends an ordinary `text` event to the Coordinator's conversation;
/// `seq` is that event's seq, the "Open in chat" anchor.
public struct Briefing: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let body: String
    public let createdAt: Date
    public let convoID: String
    public let seq: Int64

    public init(id: String, body: String, createdAt: Date, convoID: String, seq: Int64) {
        self.id = id; self.body = body; self.createdAt = createdAt; self.convoID = convoID; self.seq = seq
    }

    /// `nil` when a field the card needs is missing.
    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty,
              let body = json["body"] as? String,
              let createdAt = msDate(json["created_at"]),
              let convoID = json["convo_id"] as? String, !convoID.isEmpty,
              let seq = (json["seq"] as? NSNumber)?.int64Value
        else { return nil }
        self.init(id: id, body: body, createdAt: createdAt, convoID: convoID, seq: seq)
    }
}

/// The user's last "ask for a new briefing", until a briefing published at
/// or after `requestedAt` answers it (the journal then sends `null`).
public struct BriefingRefresh: Equatable, Hashable, Sendable {
    public enum State: String, Equatable, Hashable, Sendable {
        /// Asked; the Coordinator has until `expiresAt` to publish.
        case pending
        /// The run could not be fired at the Coordinator.
        case failed
        /// Ten minutes passed with no briefing.
        case timedOut = "timed_out"
    }

    public let requestedAt: Date
    public let state: State
    /// Only while `pending`.
    public let expiresAt: Date?
    /// Only when `failed`: the firer's outcome string.
    public let outcome: String?

    public init(requestedAt: Date, state: State, expiresAt: Date? = nil, outcome: String? = nil) {
        self.requestedAt = requestedAt; self.state = state; self.expiresAt = expiresAt; self.outcome = outcome
    }

    /// `nil` when the state is missing or one this build does not know.
    public init?(json: [String: Any]) {
        guard let requestedAt = msDate(json["requested_at"]),
              let state = (json["state"] as? String).flatMap(State.init(rawValue:))
        else { return nil }
        self.init(requestedAt: requestedAt, state: state, expiresAt: msDate(json["expires_at"]),
                  outcome: json["outcome"] as? String)
    }
}

/// `GET /briefings/latest` (and the `POST /briefings/refresh` answer).
public struct LatestBriefing: Equatable, Hashable, Sendable {
    public let briefing: Briefing?
    public let refresh: BriefingRefresh?
    /// When the next refresh may be asked for; `nil` = now.
    public let nextRefreshAt: Date?
    /// Without a Coordinator there is no one to brief: the card hides.
    public let hasCoordinator: Bool

    public init(briefing: Briefing?, refresh: BriefingRefresh?, nextRefreshAt: Date?, hasCoordinator: Bool) {
        self.briefing = briefing; self.refresh = refresh
        self.nextRefreshAt = nextRefreshAt; self.hasCoordinator = hasCoordinator
    }

    /// `nil` only when `has_coordinator` is missing — the shape is not this
    /// route's. A malformed `briefing` or `refresh` reads as none.
    public init?(json: [String: Any]) {
        guard let hasCoordinator = json["has_coordinator"] as? Bool else { return nil }
        self.init(briefing: (json["briefing"] as? [String: Any]).flatMap(Briefing.init(json:)),
                  refresh: (json["refresh"] as? [String: Any]).flatMap(BriefingRefresh.init(json:)),
                  nextRefreshAt: msDate(json["next_refresh_at"]),
                  hasCoordinator: hasCoordinator)
    }
}

/// What the "Latest briefing" card at the top of Projects draws. Built by
/// `LatestBriefingStore` (MatronViewModels), drawn by `LatestBriefingCard`
/// (MatronDesignSystem). `nil` wherever a card is expected means no card:
/// an older journal, or no Coordinator.
public struct BriefingCardModel: Equatable, Hashable, Sendable {
    public enum State: Equatable, Hashable, Sendable {
        case idle
        /// A refresh is pending (or the ask is in flight).
        case refreshing
        /// The last refresh failed or timed out.
        case failed
    }

    /// `nil`: no briefing yet.
    public var createdAt: Date?
    /// The briefing's markdown, for the card's two-line preview.
    public var body: String
    public var state: State
    /// Whether the refresh button is live: not refreshing and out of the
    /// journal's cooldown.
    public var canRefresh: Bool
    /// Why the last ask failed (busy, offline), as a footnote; `nil` mostly.
    public var notice: String?

    public init(createdAt: Date?, body: String, state: State, canRefresh: Bool, notice: String? = nil) {
        self.createdAt = createdAt; self.body = body; self.state = state; self.canRefresh = canRefresh
        self.notice = notice
    }

    public var hasBriefing: Bool { createdAt != nil }
}
