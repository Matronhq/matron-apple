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
        case JournalEventType.readMarker, JournalEventType.edit, JournalEventType.sessionStatus:
            return nil

        case JournalEventType.text:
            kind = .text(body: payload["body"] as? String ?? "", formattedHTML: nil)

        case JournalEventType.toolOutput:
            kind = .toolCall(eventID: String(event.seq),
                             toolCallEvent(fromToolOutput: payload, ts: event.ts))

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
                kind = .askUserAnswer(promptEventID: inReplyTo ?? "", selectedValues: [choice])
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
}
