import Foundation

/// Per-conversation session status published by the bridge at turn end
/// (journal `status` ephemeral): model name, a context-window gauge, and
/// account rate limits. Parts are independently optional — the bridge
/// omits what it doesn't know, and absent parts mean "unchanged", so the
/// held value merges updates rather than replacing wholesale.
public struct SessionStatus: Equatable, Sendable {
    /// Context-window gauge — an estimate computed by the bridge from the
    /// last request's usage block, not /context's exact accounting.
    public struct Context: Equatable, Sendable {
        public let tokens: Int
        public let window: Int
        public let pct: Int

        public init(tokens: Int, window: Int, pct: Int) {
            self.tokens = tokens
            self.window = window
            self.pct = pct
        }
    }

    /// One account rate-limit line (session / week / per-model week).
    /// `resets` is the raw text claude printed; `resetsAt` is the bridge's
    /// normalised timestamp, nil when the bridge couldn't parse the text —
    /// renderers fall back to showing `resets` verbatim.
    public struct Limit: Equatable, Sendable {
        public let label: String
        public let percent: Int
        public let resets: String?
        public let resetsAt: Date?

        public init(label: String, percent: Int, resets: String?, resetsAt: Date?) {
            self.label = label
            self.percent = percent
            self.resets = resets
            self.resetsAt = resetsAt
        }
    }

    public var model: String?
    public var context: Context?
    public var limits: [Limit]?
    /// Logged-in account email on the bridge's machine (read from
    /// ~/.claude.json's oauthAccount). Absent when the bridge can't read
    /// it — e.g. API-key accounts.
    public var email: String?
    /// For a subagent child conversation, the `tool_use_id` of the parent's
    /// spawning Task call — the bridge publishes it on every status frame
    /// for the child, and the server replays the last one on `viewing`. Lets
    /// the parent link its Task tool card to this child. `nil` for normal
    /// conversations (and for children until a status frame carries it).
    public var taskRef: String?

    public init(model: String? = nil, context: Context? = nil, limits: [Limit]? = nil, email: String? = nil, taskRef: String? = nil) {
        self.model = model
        self.context = context
        self.limits = limits
        self.email = email
        self.taskRef = taskRef
    }

    /// Merge an update: each part replaces the held value only when the
    /// frame carries it (absent = unchanged, per the status protocol).
    public mutating func apply(_ update: SessionStatusUpdate) {
        if let model = update.model { self.model = model }
        if let context = update.context { self.context = context }
        if let limits = update.limits { self.limits = limits }
        if let email = update.email { self.email = email }
        if let taskRef = update.taskRef { self.taskRef = taskRef }
    }
}

/// One decoded `status` ephemeral frame. Lives in MatronModels (not
/// MatronJournal) so view models and the design system can consume it
/// without a journal dependency.
public struct SessionStatusUpdate: Equatable, Sendable {
    public let convoID: String
    public let model: String?
    public let context: SessionStatus.Context?
    public let limits: [SessionStatus.Limit]?
    public let email: String?
    /// The spawning Task call's `tool_use_id` for a subagent child (see
    /// `SessionStatus.taskRef`). `nil` when the frame doesn't carry one.
    public let taskRef: String?

    /// No parameter defaults, deliberately: every constructor names every
    /// field, so merge sites (SessionStatus.apply, the sync engine's
    /// replay cache) can't silently drop a newly added one.
    public init(convoID: String, model: String?, context: SessionStatus.Context?, limits: [SessionStatus.Limit]?, email: String?, taskRef: String?) {
        self.convoID = convoID
        self.model = model
        self.context = context
        self.limits = limits
        self.email = email
        self.taskRef = taskRef
    }
}
