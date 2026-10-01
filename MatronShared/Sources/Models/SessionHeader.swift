import Foundation

/// A conversation's persisted session header as `GET /roster` serves it
/// (`conversations[].status`, journal `conversation_status`, spec
/// 2026-09-29 coordinator session control §1): the model, the context
/// gauge and any usage-limit stall from the bridge's last status op. It
/// answers "how full is that session" for every session on the fleet, not
/// only the one whose chat is open (`SessionStatus` is that live stream).
public struct SessionHeader: Equatable, Hashable, Sendable {
    public let model: String?
    public let context: SessionStatus.Context?
    /// The session reported a usage-limit stall.
    public let isStalled: Bool
    /// When the stalled limit resets, when the bridge knew.
    public let stallResetsAt: Date?

    public init(model: String? = nil, context: SessionStatus.Context? = nil, isStalled: Bool = false,
                stallResetsAt: Date? = nil) {
        self.model = model; self.context = context; self.isStalled = isStalled; self.stallResetsAt = stallResetsAt
    }

    /// Stalled now: a stall is reported and its reset, when known, is still
    /// ahead. Past the reset the bridge carries the session on by itself,
    /// so the stall the roster still holds is no longer the session's state.
    public func isStalled(at now: Date) -> Bool {
        guard isStalled else { return false }
        guard let stallResetsAt else { return true }
        return stallResetsAt > now
    }

    /// Parses one roster row's `status` block. Each part degrades on its
    /// own (the journal validates them block by block too); nil when no
    /// part is usable.
    public static func parse(statusObject: [String: Any]) -> SessionHeader? {
        let model = (statusObject["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = (statusObject["context"] as? [String: Any]).flatMap { raw -> SessionStatus.Context? in
            guard let tokens = BoxCapacity.wholeNumber(raw["tokens"]), tokens >= 0,
                  let window = BoxCapacity.wholeNumber(raw["window"]), window > 0,
                  let pct = BoxCapacity.wholeNumber(raw["pct"]) else { return nil }
            return SessionStatus.Context(tokens: tokens, window: window, pct: min(max(pct, 0), 100))
        }
        let stall = statusObject["stall"] as? [String: Any]
        let header = SessionHeader(model: model?.isEmpty == false ? model : nil, context: context,
                                   isStalled: stall != nil,
                                   stallResetsAt: (stall?["resets_at"] as? String).flatMap(BoxCapacity.parseISODate))
        return header.model == nil && header.context == nil && !header.isStalled ? nil : header
    }
}
