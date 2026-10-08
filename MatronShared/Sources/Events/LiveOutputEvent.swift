import Foundation

/// A live command-output announcement — the journal `tool_output` payload
/// the bridge publishes when a Bash tool call starts with live output
/// enabled (`{tool_use_id, command, viewer_url, expires_at}`). The output
/// itself never rides the journal: it streams from the bridge's viewer
/// service over a separate WebSocket derived from `viewerURL`, exactly as
/// matron-web's `chat.matron.live_output.v1` tile does.
public struct LiveOutputEvent: Equatable, Hashable, Sendable {
    public let toolUseID: String
    public let command: String
    /// The signed viewer URL (`https://host/live?token=…`). HMAC-scoped
    /// to one command's log file; useless for anything else.
    public let viewerURL: URL
    /// Token/log expiry. Past this, the viewer socket rejects connects
    /// and the log may be GC'd — render "expired" instead of connecting.
    public let expiresAt: Date?

    public init(toolUseID: String, command: String, viewerURL: URL, expiresAt: Date?) {
        self.toolUseID = toolUseID
        self.command = command
        self.viewerURL = viewerURL
        self.expiresAt = expiresAt
    }

    /// Parses the bridge's payload shape. `command` + a parseable
    /// `viewer_url` are what make live rendering possible — without either
    /// the caller should fall back to the static tool-call card.
    /// `tool_use_id` falls back to the URL string so a (malformed) payload
    /// missing it still gets a stable identity for session reuse.
    public static func parse(payload: [String: Any]) -> LiveOutputEvent? {
        guard let command = payload["command"] as? String, !command.isEmpty,
              let urlString = payload["viewer_url"] as? String,
              let url = URL(string: urlString), url.scheme != nil
        else { return nil }
        let expiresSeconds = (payload["expires_at"] as? NSNumber)?.doubleValue
        return LiveOutputEvent(
            toolUseID: payload["tool_use_id"] as? String ?? urlString,
            command: command,
            viewerURL: url,
            expiresAt: expiresSeconds.map { Date(timeIntervalSince1970: $0) }
        )
    }

    /// The WebSocket endpoint for the stream: `http(s)` → `ws(s)`,
    /// path `…/live` → `…/live/ws`, query (the token) preserved.
    /// Mirrors matron-web's `viewerUrlToWsUrl`.
    public var socketURL: URL? {
        guard var components = URLComponents(url: viewerURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        case "wss", "ws": break
        default: return nil
        }
        if components.path.hasSuffix("/live") {
            components.path += "/ws"
        } else if !components.path.hasSuffix("/live/ws") {
            return nil
        }
        return components.url
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }
}

/// One frame of the viewer socket's protocol.
/// `{type:"data", chunk}` appends output; `{type:"complete", exitCode,
/// denied, truncated}` is terminal (spread from the bridge's `.done`
/// sentinel). Anything else is ignored so the protocol can grow.
public enum LiveOutputFrame: Equatable, Sendable {
    case data(chunk: String)
    case complete(exitCode: Int?, denied: Bool, truncated: Bool)

    public static func decode(_ text: String) -> LiveOutputFrame? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        switch obj["type"] as? String {
        case "data":
            guard let chunk = obj["chunk"] as? String else { return nil }
            return .data(chunk: chunk)
        case "complete":
            return .complete(
                exitCode: (obj["exitCode"] as? NSNumber)?.intValue,
                denied: obj["denied"] as? Bool ?? false,
                truncated: obj["truncated"] as? Bool ?? false
            )
        default:
            return nil
        }
    }
}
