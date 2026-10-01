import Foundation

/// The `routine` journal event (protocol: "Coordinator routines → Marker
/// event"), appended into the Coordinator conversation on every routine
/// create / update / delete / fire. The journal means it as the apps'
/// cue to refetch `GET /routines`; the apps have no Routines screen yet,
/// so here it is only a one-line timeline row — which routine fired and
/// whether it reached the Coordinator. An undelivered fire leaves no other
/// trace in the transcript, so its reason is always on the row.
public struct RoutineMarkerEvent: Equatable, Sendable {
    public enum Action: String, Sendable { case saved, deleted, fired }
    public let routineID: String
    public let name: String
    public let action: Action
    /// `saved` only: a create rather than an edit.
    public let created: Bool
    /// `saved`/`deleted`: `user`, or `agent` — only the Coordinator may write.
    public let by: String?
    /// `fired` only: `applied now`, `applied deferred`, `failed <code>`,
    /// `no_coordinator` or `missed` (journal `src/routines-sweep.js`).
    public let outcome: String?

    public init(routineID: String, name: String, action: Action, created: Bool = false,
                by: String? = nil, outcome: String? = nil) {
        self.routineID = routineID; self.name = name; self.action = action
        self.created = created; self.by = by; self.outcome = outcome
    }

    public static func parse(payload: [String: Any]) -> RoutineMarkerEvent? {
        guard let routineID = payload["routine_id"] as? String, !routineID.isEmpty,
              let name = (payload["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              let action = (payload["action"] as? String).flatMap(Action.init(rawValue:))
        else { return nil }
        return RoutineMarkerEvent(routineID: routineID, name: name, action: action,
                                  created: payload["created"] as? Bool ?? false,
                                  by: payload["by"] as? String,
                                  outcome: payload["outcome"] as? String)
    }

    /// Whether a fire reached the Coordinator. Undelivered and missed fires
    /// leave no other trace in the transcript, so the row flags them.
    public var isUndelivered: Bool {
        guard action == .fired, let outcome else { return false }
        return outcome == "missed" || outcome == "no_coordinator" || outcome.hasPrefix("failed")
    }

    /// The row's one line: "Routine fired · daily-sweep", "Routine not
    /// delivered · daily-sweep — agent_unreachable", "You created a routine
    /// · deploy-window".
    public var text: String {
        switch action {
        case .saved, .deleted:
            let who = by == "user" ? "You" : "Coordinator"
            let verb = action == .deleted ? "deleted" : (created ? "created" : "updated")
            return "\(who) \(verb) a routine · \(name)"
        case .fired:
            let outcome = (outcome ?? "").trimmingCharacters(in: .whitespaces)
            if outcome == "missed" { return "Routine missed · \(name)" }
            if outcome == "no_coordinator" { return "Routine not delivered · \(name) — no Coordinator box" }
            if outcome.hasPrefix("failed") {
                let code = outcome.dropFirst("failed".count).trimmingCharacters(in: .whitespaces)
                return "Routine not delivered · \(name)" + (code.isEmpty ? "" : " — \(code)")
            }
            if outcome == "applied deferred" { return "Routine fired · \(name) — queued for the next idle point" }
            return "Routine fired · \(name)"
        }
    }
}
