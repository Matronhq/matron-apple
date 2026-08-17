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

    /// Host CPU/RAM sample from the bridge machine, published top-level
    /// (deliberately NOT a `Limit` — these are machine metrics, not account
    /// subscription meters, and must never render as one). Either half can
    /// be nil: CPU needs two sampler ticks, so the first frames after a
    /// bridge boot carry RAM alone.
    public struct Vitals: Equatable, Sendable {
        public let cpuPct: Int?
        public let ramPct: Int?

        public init(cpuPct: Int?, ramPct: Int?) {
            self.cpuPct = cpuPct
            self.ramPct = ramPct
        }
    }

    /// One value the bridge offers for a session-scoped command argument —
    /// a model alias for `/model`, an effort level for `/effort`. The
    /// bridge owns these lists (they're agent-dependent: Claude aliases for
    /// one session, Codex model ids for another), so they travel on the
    /// status frame rather than being copied into the app's catalog.
    /// `label` is absent when it would only repeat `value`.
    public struct Option: Equatable, Sendable {
        public let value: String
        public let label: String?

        public init(value: String, label: String?) {
            self.value = value
            self.label = label
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
    /// The session's absolute working directory on the bridge machine.
    public var workdir: String?
    /// Last host CPU/RAM sample from the bridge machine.
    public var vitals: Vitals?
    /// Model aliases this session can switch to — the palette's `/model`
    /// argument suggestions. Optional, and the optionality is load-bearing:
    /// `nil` means this bridge doesn't say (an older one, or an agent the
    /// bridge can't enumerate), `[]` means it says there is nothing to
    /// offer. Both render as no suggestions; only `[]` may overwrite a
    /// known list.
    public var modelOptions: [Option]?
    /// Effort levels this session accepts — `/effort`'s suggestions. Same
    /// absent-versus-empty rule as `modelOptions`.
    public var effortLevels: [Option]?
    /// The session's current effort level, when the bridge knows it. The
    /// bridge tracks this optimistically (nothing reads it back off the
    /// TUI) and publishes nothing rather than a guess, so absent is the
    /// normal state until the user sets effort through Matron. Renderers
    /// show nothing at all when it's absent.
    public var effort: String?

    public init(model: String? = nil, context: Context? = nil, limits: [Limit]? = nil, email: String? = nil, taskRef: String? = nil, workdir: String? = nil, vitals: Vitals? = nil, modelOptions: [Option]? = nil, effortLevels: [Option]? = nil, effort: String? = nil) {
        self.model = model
        self.context = context
        self.limits = limits
        self.email = email
        self.taskRef = taskRef
        self.workdir = workdir
        self.vitals = vitals
        self.modelOptions = modelOptions
        self.effortLevels = effortLevels
        self.effort = effort
    }

    /// Merge an update: each part replaces the held value only when the
    /// frame carries it (absent = unchanged, per the status protocol).
    public mutating func apply(_ update: SessionStatusUpdate) {
        if let model = update.model { self.model = model }
        if let context = update.context { self.context = context }
        if let limits = update.limits { self.limits = limits }
        if let email = update.email { self.email = email }
        if let taskRef = update.taskRef { self.taskRef = taskRef }
        if let workdir = update.workdir { self.workdir = workdir }
        if let vitals = update.vitals { self.vitals = vitals }
        // An empty list arrives as `[]`, not nil, and legitimately replaces
        // a held one — "this agent offers nothing" is a statement, absence
        // is silence.
        if let modelOptions = update.modelOptions { self.modelOptions = modelOptions }
        if let effortLevels = update.effortLevels { self.effortLevels = effortLevels }
        if let effort = update.effort { self.effort = effort }
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
    /// Absolute workdir on the bridge machine. `nil` when absent.
    public let workdir: String?
    /// Host CPU/RAM sample. `nil` when absent or carrying no numbers.
    public let vitals: SessionStatus.Vitals?
    /// Model aliases and effort levels the bridge offers for this session
    /// (see `SessionStatus.modelOptions`). `nil` when the frame omits the
    /// field — distinct from an empty array, which the decoder preserves.
    public let modelOptions: [SessionStatus.Option]?
    public let effortLevels: [SessionStatus.Option]?
    /// Current effort level. `nil` when the bridge doesn't know it.
    public let effort: String?

    /// No parameter defaults, deliberately: every constructor names every
    /// field, so merge sites (SessionStatus.apply, the sync engine's
    /// replay cache) can't silently drop a newly added one.
    public init(convoID: String, model: String?, context: SessionStatus.Context?, limits: [SessionStatus.Limit]?, email: String?, taskRef: String?, workdir: String?, vitals: SessionStatus.Vitals?, modelOptions: [SessionStatus.Option]?, effortLevels: [SessionStatus.Option]?, effort: String?) {
        self.convoID = convoID
        self.model = model
        self.context = context
        self.limits = limits
        self.email = email
        self.taskRef = taskRef
        self.workdir = workdir
        self.vitals = vitals
        self.modelOptions = modelOptions
        self.effortLevels = effortLevels
        self.effort = effort
    }
}
