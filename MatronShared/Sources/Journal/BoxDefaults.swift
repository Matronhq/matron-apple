import Foundation

/// One agent box's defaults for new sessions (journal "Box defaults": `GET
/// /devices` `defaults`, `PUT /devices/:id/defaults`, live as `box_defaults`):
/// the agent, model and effort a session started on that box gets when
/// nobody names them. `nil` is "Box default": the bridge's own
/// `MATRON_DEFAULT_*` fallback.
///
/// The model and effort belong to the box's default agent — a Claude alias
/// on a Claude box, a Codex model id on a Codex box — so the journal clears
/// the model when the agent changes (`applying`).
public struct BoxDefaults: Equatable, Sendable {
    /// The three settings, keyed as `PUT /devices/:id/defaults` names them.
    public enum Key: String, CaseIterable, Sendable {
        case agent = "default_agent"
        case model = "default_model"
        case effort = "default_effort"

        /// The key inside `GET /devices`'s `defaults` block.
        var rosterKey: String {
            switch self {
            case .agent: return "agent"
            case .model: return "model"
            case .effort: return "effort"
            }
        }
    }

    public var agent: String?
    public var model: String?
    public var effort: String?

    public init(agent: String? = nil, model: String? = nil, effort: String? = nil) {
        self.agent = agent
        self.model = model
        self.effort = effort
    }

    public subscript(key: Key) -> String? {
        get {
            switch key {
            case .agent: return agent
            case .model: return model
            case .effort: return effort
            }
        }
        set {
            switch key {
            case .agent: agent = newValue
            case .model: model = newValue
            case .effort: effort = newValue
            }
        }
    }

    /// What the journal stores for a `PUT` of `key` alone: the value, and —
    /// for a new agent — no model, since the old one belonged to the old
    /// agent. Effort is kept. The same agent again is no change.
    public func applying(_ key: Key, _ value: String?) -> BoxDefaults {
        var next = self
        next[key] = value
        if key == .agent, value != agent { next.model = nil }
        return next
    }

    /// One setting picked: a key and its new value (nil = Box default).
    public struct Pick: Equatable, Sendable {
        public let key: Key
        public let value: String?

        public init(_ key: Key, _ value: String?) {
            self.key = key
            self.value = value
        }
    }

    /// `applying` each pick in order — what the journal stores for one
    /// `PUT` carrying them all. A model sent with a new agent survives,
    /// since it is applied after the agent.
    public func applying(_ picks: [Pick]) -> BoxDefaults {
        picks.reduce(self) { $0.applying($1.key, $1.value) }
    }

    /// A `GET /devices` agent entry's `defaults` block: `{agent, model,
    /// effort}`.
    public static func decodeRoster(_ obj: [String: Any]) -> BoxDefaults? {
        decode(obj, key: \.rosterKey)
    }

    /// A `PUT /devices/:id/defaults` answer or a live `box_defaults` frame:
    /// `{device_id, default_agent, default_model, default_effort}` (the
    /// other keys are ignored).
    public static func decodeState(_ obj: [String: Any]) -> BoxDefaults? {
        decode(obj, key: \.rawValue)
    }

    /// A missing, null or empty value is "Box default"; any other non-string
    /// rejects the whole block, so a malformed one never half-applies (the
    /// `NewChatDefaults.decode` rule).
    private static func decode(_ obj: [String: Any], key name: (Key) -> String) -> BoxDefaults? {
        var defaults = BoxDefaults()
        for key in Key.allCases {
            switch obj[name(key)] {
            case nil, is NSNull: break
            case let string as String: defaults[key] = string.isEmpty ? nil : string
            default: return nil
            }
        }
        return defaults
    }
}

/// A live `box_defaults` frame: the full new state of one box's defaults,
/// from any device's or agent's `PUT`, including this device's own echo.
public struct BoxDefaultsUpdate: Equatable, Sendable {
    public let deviceID: Int64
    public let defaults: BoxDefaults

    public init(deviceID: Int64, defaults: BoxDefaults) {
        self.deviceID = deviceID
        self.defaults = defaults
    }
}
