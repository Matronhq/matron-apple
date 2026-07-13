import Foundation
import MatronEvents
import MatronJournal

/// Pure mapping from journal events to the render model. Unknown types get
/// a labeled fallback so the protocol can grow without lockstep upgrades.
public enum JournalTimelineMapper {
    public static func displayName(fromSender sender: String) -> String {
        if let colon = sender.firstIndex(of: ":"),
           ["user", "agent"].contains(String(sender[..<colon])) {
            return String(sender[sender.index(after: colon)...])
        }
        return sender
    }

    public static func timelineItem(from event: JournalEvent, ownSender: String, serverURL: URL) -> TimelineItem? {
        let payload = event.payload
        let kind: TimelineItem.Kind
        var inReplyTo: String?

        switch event.type {
        case JournalEventType.readMarker, JournalEventType.edit,
             JournalEventType.sessionStatus, JournalEventType.convoMeta:
            return nil

        case JournalEventType.text:
            kind = .text(body: payload["body"] as? String ?? "", formattedHTML: nil)

        case JournalEventType.toolOutput:
            // A tool_output carrying a viewer_url is a live command-output
            // announcement (the bridge's Bash live-output shape) — render
            // the streaming tile. Everything else stays a static card.
            if let live = LiveOutputEvent.parse(payload: payload) {
                kind = .liveOutput(eventID: String(event.seq), live)
            } else {
                kind = .toolCall(eventID: String(event.seq),
                                 toolCallEvent(fromToolOutput: payload, ts: event.ts))
            }

        case JournalEventType.diff:
            let text = payload["diff"] as? String ?? payload["snippet"] as? String ?? ""
            kind = .toolCall(eventID: String(event.seq), ToolCallEvent(
                tool: "diff", argsJSON: "{}", status: .ok,
                resultText: text, resultTruncated: payload["truncated"] as? Bool ?? false,
                startedAt: event.ts, endedAt: event.ts))

        case JournalEventType.prompt:
            kind = .askUser(eventID: String(event.seq), askUserEvent(fromPrompt: payload))

        case JournalEventType.permissionRequest:
            let description = payload["description"] as? String ?? "Permission request"
            let optionValues = (payload["options"] as? [String]) ?? ["Allow", "Deny"]
            kind = .askUser(eventID: String(event.seq), AskUserEvent(
                prompt: description,
                kind: .choice(options: optionValues.map { AskUserEvent.Option(id: $0, label: $0) },
                              allowOther: false),
                expiresAt: nil, replyChannel: .buttonResponse))

        case JournalEventType.promptReply:
            let target = (payload["target_seq"] as? NSNumber)?.int64Value
            inReplyTo = target.map(String.init)
            if let choice = payload["choice"] as? String {
                if let targetID = inReplyTo {
                    kind = .askUserAnswer(promptEventID: targetID, selectedValues: [choice])
                } else {
                    kind = .unknown(eventType: JournalEventType.promptReply)
                }
            } else {
                kind = .text(body: payload["text"] as? String ?? "", formattedHTML: nil)
            }

        case JournalEventType.file, JournalEventType.image:
            let url = (payload["blob_ref"] as? String).map {
                serverURL.appendingPathComponent("media").appendingPathComponent($0)
            }
            let size = (payload["size"] as? NSNumber)?.int64Value
            if event.type == JournalEventType.image {
                kind = .image(url: url, caption: payload["caption"] as? String, sizeBytes: size)
            } else {
                kind = .file(url: url, filename: payload["filename"] as? String ?? "file", sizeBytes: size)
            }

        default:
            kind = .unknown(eventType: event.type)
        }

        return TimelineItem(
            id: String(event.seq),
            sender: displayName(fromSender: event.sender),
            timestamp: event.ts,
            kind: kind,
            isOwn: event.sender == ownSender,
            sendState: .sent,
            inReplyToEventID: inReplyTo
        )
    }

    public static func toolCallEvent(fromToolOutput payload: [String: Any], ts: Date) -> ToolCallEvent {
        // Rich payloads (bridge keeps chat.matron.tool_call keys) parse directly.
        if let parsed = ToolCallEvent.parse(content: payload) { return parsed }
        // Bridge command-tool shape: {tool_use_id, command, viewer_url}. The
        // command is the only human-meaningful content in the journal — the
        // actual output streams to viewer_url and is never persisted here — so
        // surface the command as the tool's args. Without this the fallback
        // below produced tool "tool" with empty args and no result, which
        // rendered as a blank, un-expandable card.
        if let command = payload["command"] as? String, !command.isEmpty {
            return ToolCallEvent(
                tool: commandLabel(command),
                argsJSON: command,
                status: .ok,
                resultText: nil,
                resultTruncated: false,
                startedAt: ts,
                endedAt: nil
            )
        }
        return ToolCallEvent(
            tool: payload["tool_name"] as? String ?? "tool",
            argsJSON: "{}",
            status: .ok,
            resultText: payload["snippet"] as? String,
            resultTruncated: payload["truncated"] as? Bool ?? false,
            startedAt: ts,
            endedAt: nil
        )
    }

    /// A short label for a shell command: the first whitespace-delimited
    /// token of the first non-empty line (e.g. "grep -rn …" → "grep",
    /// a script starting "cd /x\n…" → "cd"). Bounded so a pathological
    /// one-liner can't produce a runaway label; empty input → "command".
    static func commandLabel(_ command: String) -> String {
        let firstLine = command.split(whereSeparator: \.isNewline).first ?? ""
        let token = firstLine.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return token.isEmpty ? "command" : String(token.prefix(24))
    }

    public static func askUserEvent(fromPrompt payload: [String: Any]) -> AskUserEvent {
        let question = payload["question"] as? String ?? ""
        let allowsFreeText = payload["allows_free_text"] as? Bool ?? false
        var options: [AskUserEvent.Option] = []
        for raw in payload["options"] as? [Any] ?? [] {
            if let label = raw as? String {
                options.append(AskUserEvent.Option(id: label, label: label))
            } else if let obj = raw as? [String: Any], let label = obj["label"] as? String {
                options.append(AskUserEvent.Option(
                    id: obj["id"] as? String ?? label, label: label,
                    value: obj["value"] as? String))
            }
        }
        let kind: AskUserEvent.InputKind
        if options.isEmpty {
            kind = .text
        } else if (payload["mode"] as? String) == "pick_many" {
            kind = .multiChoice(options: options, allowOther: allowsFreeText)
        } else {
            kind = .choice(options: options, allowOther: allowsFreeText)
        }
        return AskUserEvent(
            prompt: question, kind: kind, expiresAt: nil,
            replyChannel: options.isEmpty ? .textReply : .buttonResponse)
    }

    public static func streamingItem(messageRef: String, text: String, convoTS: Date) -> TimelineItem {
        TimelineItem(
            id: "eph:\(messageRef)", sender: "agent", timestamp: convoTS,
            kind: .text(body: text, formattedHTML: nil), isOwn: false, sendState: .sent)
    }

    /// Human label for an activity indicator. `nil` for `.idle` — the caller
    /// never renders an idle indicator, so there's nothing to show.
    public static func activityLabel(state: ActivityUpdate.State, detail: String?) -> String? {
        switch state {
        case .thinking:
            return "Thinking…"
        case .tool:
            let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty { return "Running \(trimmed)" }
            return "Working…"
        case .idle:
            return nil
        }
    }

    /// A trailing indicator row. Stable `id` ("activity") so successive
    /// updates redraw one row in place rather than stacking. `convoTS`
    /// should match the last real row's day so it never spawns a date
    /// separator.
    public static func activityItem(label: String, convoTS: Date) -> TimelineItem {
        TimelineItem(
            id: "activity", sender: "agent", timestamp: convoTS,
            kind: .activityIndicator(label: label), isOwn: false, sendState: .sent)
    }
}
