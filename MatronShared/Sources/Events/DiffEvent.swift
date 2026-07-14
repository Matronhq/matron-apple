import Foundation

/// Decoded form of a journal `diff` event payload (spec:
/// docs/superpowers/specs/2026-07-14-diff-cards-design.md §2) — a file-edit
/// snippet the bridge publishes at tool_use time, replacing the old
/// "✏️ Editing …" text message. Renders as a `DiffCard`. The pre-spec bare
/// shape (`{diff: "…"}` or `{snippet: "…"}` alone) parses into the same
/// type with nil metadata so there is exactly one render path.
public struct DiffEvent: Equatable, Sendable {
    public let filePath: String?
    public let displayPath: String?
    public let viewerURL: URL?
    public let tool: String?
    /// Subagent label; nil for parent-agent edits.
    public let label: String?
    public let diff: String
    public let added: Int?
    public let removed: Int?
    public let truncated: Bool
    public let newFile: Bool

    public init(filePath: String? = nil, displayPath: String? = nil,
                viewerURL: URL? = nil, tool: String? = nil, label: String? = nil,
                diff: String, added: Int? = nil, removed: Int? = nil,
                truncated: Bool = false, newFile: Bool = false) {
        self.filePath = filePath
        self.displayPath = displayPath
        self.viewerURL = viewerURL
        self.tool = tool
        self.label = label
        self.diff = diff
        self.added = added
        self.removed = removed
        self.truncated = truncated
        self.newFile = newFile
    }

    /// Total parse — every field is optional metadata around the diff text,
    /// and a payload with neither `diff` nor `snippet` yields an empty
    /// string (the card renders header-only). No nil return: the mapper
    /// has already routed on the event TYPE, so there is nothing better to
    /// fall back to.
    public static func parse(payload: [String: Any]) -> DiffEvent {
        DiffEvent(
            filePath: payload["file_path"] as? String,
            displayPath: payload["display_path"] as? String,
            viewerURL: (payload["viewer_url"] as? String).flatMap(URL.init(string:)),
            tool: payload["tool"] as? String,
            label: payload["label"] as? String,
            diff: payload["diff"] as? String ?? payload["snippet"] as? String ?? "",
            added: (payload["added"] as? NSNumber)?.intValue,
            removed: (payload["removed"] as? NSNumber)?.intValue,
            truncated: payload["truncated"] as? Bool ?? false,
            newFile: payload["new_file"] as? Bool ?? false
        )
    }

    /// Header filename: last component of the display path (falling back to
    /// the absolute path); nil when the payload carried no path at all.
    public var filename: String? {
        (displayPath ?? filePath).map { ($0 as NSString).lastPathComponent }
    }
}
