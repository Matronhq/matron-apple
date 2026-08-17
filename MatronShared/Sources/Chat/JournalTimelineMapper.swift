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
             JournalEventType.sessionStatus, JournalEventType.convoMeta,
             JournalEventType.summary:
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
            kind = .diff(eventID: String(event.seq), DiffEvent.parse(payload: payload))

        case JournalEventType.prompt:
            kind = .askUser(eventID: String(event.seq), askUserEvent(fromPrompt: payload))

        case JournalEventType.permissionRequest:
            // The agent-chat consent card first: it carries none of the keys
            // the generic branch reads, so it used to render as the literal
            // string "Permission request" with Allow/Deny buttons that
            // answered over `prompt_reply` — a channel that never reaches the
            // parked row. The tap did nothing and the ask expired 24h later.
            if let request = AgentChatRequest.parse(payload: payload) {
                kind = .agentChatRequest(eventID: String(event.seq), request)
            } else if let spawn = AgentSpawnRequest.parse(payload: payload) {
                // The agent-spawn card, same story: no `description`, no
                // `options`, and an answer that leaves over HTTP.
                kind = .agentSpawnRequest(eventID: String(event.seq), spawn)
            } else if let consentKind = payload["kind"] as? String,
                      consentKind == "agent_spawn" || consentKind == "agent_chat" {
                // A consent-kind payload the parser rejected (malformed —
                // e.g. no request_id). It answers over HTTP
                // (`POST /agent-spawn/answer` / `/agent-chat/answer`), never
                // `prompt_reply`, so the generic branch below would draw
                // Allow/Deny wired to a channel nothing reads — dead taps
                // until the ask expires. Render an inert notice instead,
                // matching android; web renders the spawn card read-only.
                let headline = (payload["topic"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (payload["task"] as? String).flatMap {
                        let first = $0.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
                        return first.isEmpty ? nil : first
                    }
                let notice = headline.map { "Agent request that can't be answered here: \($0)" }
                    ?? "Agent request that can't be answered here"
                kind = .stateChange(text: notice)
            } else {
                let description = payload["description"] as? String ?? "Permission request"
                let optionValues = (payload["options"] as? [String]) ?? ["Allow", "Deny"]
                kind = .askUser(eventID: String(event.seq), AskUserEvent(
                    prompt: description,
                    kind: .choice(options: optionValues.map { AskUserEvent.Option(id: $0, label: $0) },
                                  allowOther: false),
                    expiresAt: nil, replyChannel: .buttonResponse))
            }

        case JournalEventType.spawnOutcome:
            // How a spawn request ended. Server-minted and agent-visible
            // (unlike the card), so it replays like any other row — which is
            // exactly what lets the card derive its resolved state from the
            // timeline instead of remembering an answer locally.
            if let outcome = SpawnOutcome.parse(payload: payload) {
                kind = .spawnOutcomeRow(eventID: String(event.seq), outcome)
            } else {
                kind = .unknown(eventType: event.type)
            }

        case JournalEventType.promptReply:
            // A bridge-authored queued_release resolution: prompt_id +
            // action, no target_seq and no choice. Hide it as an answer
            // row namespaced by the bridge prompt id ("qr:pr_…") so a
            // flush retires every sent card's buttons on every device —
            // the generic branches below would render it as an empty
            // text bubble and resolve nothing.
            if (payload["kind"] as? String) == "queued_release" {
                // A release is never meant to be visible, so a malformed
                // one (no prompt_id / no action) drops entirely rather
                // than falling through to the generic path's empty bubble.
                guard let releasePromptID = payload["prompt_id"] as? String,
                      let action = payload["action"] as? String else { return nil }
                kind = .askUserAnswer(promptEventID: "qr:\(releasePromptID)",
                                      selectedValues: [action])
                break
            }
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
            let caption = payload["caption"] as? String
            // Reaper tombstone (matron-journal#63): blob deleted server-side,
            // payload rewritten in place with `expired: true`.
            let expired = (payload["expired"] as? Bool) ?? false
            if event.type == JournalEventType.image {
                kind = .image(url: url, caption: caption, sizeBytes: size, expired: expired)
            } else {
                // `name`, not `filename`: that's the key the media-send
                // contract defines, and what both producers actually emit
                // (the app's `.sendMedia` op and the bridge's
                // publishFile/publishImage). Reading `filename` meant the
                // fallback fired every single time, so every file in the
                // timeline rendered as a generic "file" no matter what it
                // was really called.
                kind = .file(url: url, filename: payload["name"] as? String ?? "file",
                             caption: caption, sizeBytes: size, expired: expired)
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

    /// The journal server's tool-log TTL (docs/protocol.md Retention):
    /// live-streamed output is purged server-side 24h after the event, and
    /// the client rules make the same TTL binding on local caches.
    public static let toolLogTTL: TimeInterval = 24 * 3600

    public static func toolCallEvent(fromToolOutput payload: [String: Any], ts: Date,
                                     now: Date = Date()) -> ToolCallEvent {
        // Rich payloads (bridge keeps chat.matron.tool_call keys) parse directly.
        if let parsed = ToolCallEvent.parse(content: payload) { return parsed }
        // Command-completion shape ({message_ref, command, exit_code, denied,
        // truncated, snippet, blob_ref, live_log} — and its server tombstone,
        // same minus snippet plus expired: true): command as the tool's args,
        // snippet as the result, exit_code/denied driving the status icon.
        // Also covers the older command-only payloads (no exit_code, no
        // snippet), which fall out as a plain .ok command card exactly as
        // before.
        if let command = payload["command"] as? String, !command.isEmpty {
            let exitCode = (payload["exit_code"] as? NSNumber)?.intValue
            let denied = payload["denied"] as? Bool ?? false
            var expired = payload["expired"] as? Bool ?? false
            // Binding client TTL rule: a cached live_log snippet must stop
            // rendering once ts + 24h passes locally, without waiting for
            // the server's tombstone to re-sync (JournalStore's purge sweep
            // rewrites the stored payload; this guard covers rows the sweep
            // hasn't reached yet).
            if !expired, payload["live_log"] as? Bool == true,
               ts.addingTimeInterval(toolLogTTL) <= now {
                expired = true
            }
            return ToolCallEvent(
                tool: commandLabel(command),
                argsJSON: command,
                status: denied || (exitCode ?? 0) != 0 ? .error : .ok,
                resultText: expired ? nil : payload["snippet"] as? String,
                resultTruncated: payload["truncated"] as? Bool ?? false,
                startedAt: ts,
                endedAt: nil,
                exitCode: exitCode,
                denied: denied,
                expired: expired
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
        // Busy-queue cards carry the bridge-owned prompt id their durable
        // release frames will later name — see the promptReply branch.
        let queuedReleasePromptID = (payload["kind"] as? String) == "queued_release"
            ? payload["prompt_id"] as? String
            : nil
        return AskUserEvent(
            prompt: question, kind: kind, expiresAt: nil,
            replyChannel: options.isEmpty ? .textReply : .buttonResponse,
            queuedReleasePromptID: queuedReleasePromptID)
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

    /// Renders a tool-stream byte buffer for display. Keeps only the last
    /// `displayCapBytes` (the server buffer is 1 MiB; SwiftUI Text does not
    /// enjoy megabyte strings), then drops any orphaned continuation bytes
    /// at the front of the cut and any incomplete multibyte sequence at the
    /// tail (a chunk boundary can split a character — rendering the partial
    /// bytes would flicker a U+FFFD until the next append completes it).
    public static func toolStreamText(bytes: [UInt8], displayCapBytes: Int = 65536) -> String {
        var slice = bytes[...]
        if slice.count > displayCapBytes {
            slice = slice.suffix(displayCapBytes)
            while let first = slice.first, first & 0xC0 == 0x80 {
                slice = slice.dropFirst()
            }
        }
        // Walk back over trailing continuation bytes to the lead byte; if
        // the sequence it starts is longer than what we have, trim it off.
        var index = slice.endIndex
        var walked = 0
        while walked < 4, index > slice.startIndex {
            let previous = slice.index(before: index)
            let byte = slice[previous]
            if byte & 0x80 == 0 { break } // ASCII tail — complete
            walked += 1
            if byte & 0xC0 == 0xC0 { // lead byte of a multibyte sequence
                let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
                if walked < needed { slice = slice[..<previous] }
                break
            }
            index = previous
        }
        return String(decoding: slice, as: UTF8.self)
    }

    /// A live tool-output tile row. Stable id ("toolstream:<ref>") so
    /// appends redraw one row in place; `convoTS` follows the same
    /// day-bucket rule as `streamingItem`/`activityItem`.
    public static func toolStreamItem(messageRef: String, command: String?, text: String,
                                      headTruncated: Bool, convoTS: Date) -> TimelineItem {
        TimelineItem(
            id: "toolstream:\(messageRef)", sender: "agent", timestamp: convoTS,
            kind: .toolStreamLive(messageRef: messageRef, command: command,
                                  text: text, headTruncated: headTruncated),
            isOwn: false, sendState: .sent)
    }
}
