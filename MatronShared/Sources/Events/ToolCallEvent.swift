import Foundation

/// Decoded form of a `chat.matron.tool_call` Matrix event content
/// blob. Renders as a `ToolCallCard` (Phase 5 Task 8) — the args are
/// kept as a pretty-printed sorted-key JSON string so the card can
/// display them as a code block without re-serialising on every
/// render. `resultText` is the string form of whatever the bridge
/// supplied as `result` (string-or-object); structured rendering is
/// out of scope for Phase 5.
///
/// `running` events carry only `started_at`; `ok` / `error` events
/// add `ended_at` + `result` (+ `result_truncated`). Wire-format
/// timestamps are milliseconds-since-epoch as `Double` (the bridge's
/// JSON shape); we convert to `Date` at parse time.
public struct ToolCallEvent: Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case running, ok, error }

    public let tool: String
    public let argsJSON: String
    public let status: Status
    public let resultText: String?
    public let resultTruncated: Bool
    public let startedAt: Date
    public let endedAt: Date?

    public init(
        tool: String,
        argsJSON: String,
        status: Status,
        resultText: String?,
        resultTruncated: Bool,
        startedAt: Date,
        endedAt: Date?
    ) {
        self.tool = tool
        self.argsJSON = argsJSON
        self.status = status
        self.resultText = resultText
        self.resultTruncated = resultTruncated
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    /// Parse a JSON `content` dictionary from a `chat.matron.tool_call`
    /// event. Returns `nil` if any required field is missing or has
    /// the wrong shape — callers fall back to plain-text rendering
    /// when this happens (graceful degradation contract per the plan).
    ///
    /// Timestamps: the wire carries integer milliseconds, and every
    /// production caller feeds this from `JSONSerialization`, whose
    /// `NSNumber` values bridge through `as? Double` for any integer a
    /// Double can represent losslessly (all real timestamps; only
    /// ~2^53+ magnitudes fail). Pinned by
    /// `test_parses_integerTimestamps_fromRealJSON` — don't swap the
    /// dictionaries for Swift-literal `Int` values in new call sites,
    /// pure-Swift `Int` does NOT bridge.
    public static func parse(content: [String: Any]) -> ToolCallEvent? {
        guard let tool = content["tool"] as? String,
              let statusRaw = content["status"] as? String,
              let status = Status(rawValue: statusRaw),
              let startedMs = content["started_at"] as? Double else {
            return nil
        }
        let argsAny = content["args"] ?? [:]
        let argsJSON: String = {
            guard let data = try? JSONSerialization.data(
                withJSONObject: argsAny,
                options: [.prettyPrinted, .sortedKeys]
            ) else { return "{}" }
            return String(data: data, encoding: .utf8) ?? "{}"
        }()
        let resultText: String? = {
            if let s = content["result"] as? String { return s }
            if let obj = content["result"] as? [String: Any],
               let data = try? JSONSerialization.data(
                   withJSONObject: obj,
                   options: [.prettyPrinted, .sortedKeys]
               ),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return nil
        }()
        let resultTruncated = content["result_truncated"] as? Bool ?? false
        let endedAt: Date? = (content["ended_at"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        return ToolCallEvent(
            tool: tool,
            argsJSON: argsJSON,
            status: status,
            resultText: resultText,
            resultTruncated: resultTruncated,
            startedAt: Date(timeIntervalSince1970: startedMs / 1000),
            endedAt: endedAt
        )
    }
}
