import Foundation

/// The two age rules that can rewrite a stored event payload, as one pure
/// function shared by every writer.
///
/// There are exactly two writers of an aged-out payload — the insert paths
/// (`JournalStore.applyOne` / `insertHistory`, which tombstone a row that is
/// already past a cutoff as it lands) and the background sweeps
/// (`JournalStore.purgeExpiredToolOutputSnippets(now:)` /
/// `applyRetention(now:)`). They MUST agree: the sweeps skip everything at or
/// below a persisted watermark, so a row older than that watermark is only
/// ever correct because the insert path applied the identical rule on the way
/// in.
///
/// Both rules are idempotent, and `apply` returns `nil` when it would change
/// nothing — which is how a sweep counts "rows touched" without re-writing
/// the whole range on every pass.
public enum EventTombstone {
    /// The journal server's tool-log TTL (matron-journal docs/protocol.md
    /// Retention): live-streamed output is purged server-side 24 h after the
    /// event, and the client rules make the same TTL binding on local caches.
    /// The single definition — `JournalTimelineMapper.toolLogTTL` aliases it.
    public static let toolLogTTL: TimeInterval = 24 * 3600

    /// How long this device keeps tool-output and diff BODIES (spec §4
    /// decision 1). The server still has them; the local mirror does not,
    /// and the UI already knows how to render a tombstone.
    public static let retentionWindow: TimeInterval = 30 * 24 * 3600

    /// How much of a tool-output `command` survives retention (spec §4
    /// decision 2), before the `…` marker.
    public static let commandStubLength = 200

    /// The rewritten payload, or `nil` when neither rule changes anything.
    ///
    /// - `tool_output` past `retentionWindow`: body keys go, `command` is
    ///   truncated to `commandStubLength` + `…`, `expired: true`.
    ///   `exit_code`, `denied`, `truncated` and `message_ref` stay, so the
    ///   timeline can still say what ran and how it ended.
    /// - `tool_output` past `toolLogTTL` AND `live_log: true`: the same body
    ///   strip with the command left whole. The `live_log` gate is
    ///   deliberate and is the shipped behaviour — an offloaded/legacy
    ///   tool_output carries a durable snippet that no 24 h TTL applies to
    ///   (`JournalStoreTests.testPurgeLeavesYoungAndNonLiveLogRows`).
    /// - `diff` past `retentionWindow`: `diff` and `snippet` go, every other
    ///   key stays so the card can still name the file and its counts.
    public static func apply(to payload: [String: Any], type: String,
                             ts: Date, now: Date) -> [String: Any]? {
        switch type {
        case JournalEventType.toolOutput:
            if ts.addingTimeInterval(retentionWindow) <= now {
                return rewrite(payload, stripping: ["snippet", "live_log"], truncateCommand: true)
            }
            if ts.addingTimeInterval(toolLogTTL) <= now, payload["live_log"] as? Bool == true {
                return rewrite(payload, stripping: ["snippet", "live_log"], truncateCommand: false)
            }
            return nil
        case JournalEventType.diff:
            guard ts.addingTimeInterval(retentionWindow) <= now else { return nil }
            return rewrite(payload, stripping: ["diff", "snippet"], truncateCommand: false)
        default:
            return nil
        }
    }

    /// Applies a strip + `expired: true` (+ optional command truncation) and
    /// reports `nil` when every one of those was already true — the
    /// idempotence the sweeps rely on.
    ///
    /// `blob_ref` is NULLED rather than deleted when present: that is the
    /// shipped tombstone shape, both from the server and from the sweep this
    /// replaces, and readers take it as `payload["blob_ref"] as? String` so
    /// null and absent are indistinguishable to them. An absent key stays
    /// absent, so a server-minted tombstone does not get a pointless rewrite.
    private static func rewrite(_ payload: [String: Any], stripping keys: [String],
                                truncateCommand: Bool) -> [String: Any]? {
        var out = payload
        var changed = false
        for key in keys where out.removeValue(forKey: key) != nil { changed = true }
        if let blobRef = out["blob_ref"], !(blobRef is NSNull) {
            out["blob_ref"] = NSNull()
            changed = true
        }
        if out["expired"] as? Bool != true {
            out["expired"] = true
            changed = true
        }
        if truncateCommand, let command = out["command"] as? String,
           command.count > commandStubLength {
            out["command"] = String(command.prefix(commandStubLength)) + "…"
            changed = true
        }
        return changed ? out : nil
    }
}
