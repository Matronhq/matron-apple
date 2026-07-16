import Foundation
import MatronEvents

extension TimelineItem {
    /// Pretty-printed, JSON-shaped dump of the DTO for the long-press /
    /// right-click "View source" sheet (Phase 2 Task 16).
    ///
    /// Phase 2 only has access to the `TimelineItem` DTO — not the underlying
    /// raw Matrix event JSON. This synthesises a JSON-shaped record from the
    /// DTO so the sheet is useful as a developer diagnostic surface
    /// regardless. Phase 3+ will swap this for the SDK's
    /// `EventTimelineItem.originalJson` once we wire that through.
    ///
    /// Output is real JSON (parseable by `JSONSerialization`), so users can
    /// copy the contents into another tool. The `kind` field is a nested
    /// object with a `type` discriminator and the kind's payload fields.
    public func prettyJSON() -> String {
        let payload: [String: Any] = [
            "id": id,
            "sender": sender,
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "isOwn": isOwn,
            "kind": kindAsJSON(),
            "sendState": sendStateAsJSON(),
        ]
        // `.prettyPrinted` emits a multi-line layout. `.sortedKeys` keeps
        // field order deterministic so two snapshots of the same DTO render
        // byte-identically — useful for snapshotting and for users diffing
        // two source dumps. `.withoutEscapingSlashes` keeps `mxc://` URLs
        // readable instead of `mxc:\/\/`.
        let options: JSONSerialization.WritingOptions = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes
        ]
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: options),
            let string = String(data: data, encoding: .utf8)
        else {
            // Should be unreachable — every value above is a JSON-safe
            // primitive (String / Bool / nested [String: Any]). If this ever
            // does fire, fall back to a minimal description so the sheet
            // doesn't show an empty box.
            return "{ \"id\": \"\(id)\", \"error\": \"could not serialise\" }"
        }
        return string
    }

    private func kindAsJSON() -> [String: Any] {
        switch kind {
        case .text(let body, let formattedHTML):
            // `formattedHTML` is optional; emit `NSNull` (which serialises to
            // JSON `null`) rather than dropping the key, so the shape stays
            // stable across rows.
            return [
                "type": "text",
                "body": body,
                "formattedHTML": formattedHTML ?? NSNull(),
            ]
        case .image(let url, let caption, let sizeBytes):
            return [
                "type": "image",
                "url": url?.absoluteString ?? NSNull(),
                "caption": caption ?? NSNull(),
                "sizeBytes": sizeBytes.map { NSNumber(value: $0) } ?? NSNull(),
            ]
        case .file(let url, let filename, let caption, let sizeBytes):
            return [
                "type": "file",
                "url": url?.absoluteString ?? NSNull(),
                "filename": filename,
                "caption": caption ?? NSNull(),
                "sizeBytes": sizeBytes.map { NSNumber(value: $0) } ?? NSNull(),
            ]
        case .stateChange(let text):
            return [
                "type": "stateChange",
                "text": text,
            ]
        case .toolCall(let eventID, let evt):
            return [
                "type": "toolCall",
                "eventID": eventID,
                "tool": evt.tool,
                "status": evt.status.rawValue,
                "argsJSON": evt.argsJSON,
                "resultText": evt.resultText ?? NSNull(),
                "resultTruncated": evt.resultTruncated,
                "startedAt": ISO8601DateFormatter().string(from: evt.startedAt),
                "endedAt": evt.endedAt.map(ISO8601DateFormatter().string(from:)) ?? NSNull(),
            ]
        case .diff(let eventID, let evt):
            return [
                "type": "diff",
                "eventID": eventID,
                "file": (evt.displayPath ?? evt.filePath).map { $0 as Any } ?? NSNull(),
                "tool": evt.tool ?? NSNull(),
                "label": evt.label ?? NSNull(),
                "added": evt.added.map { NSNumber(value: $0) } ?? NSNull(),
                "removed": evt.removed.map { NSNumber(value: $0) } ?? NSNull(),
                "truncated": evt.truncated,
                "newFile": evt.newFile,
                "diff": evt.diff,
            ]
        case .liveOutput(let eventID, let evt):
            return [
                "type": "liveOutput",
                "eventID": eventID,
                "toolUseID": evt.toolUseID,
                "command": evt.command,
                "viewerURL": evt.viewerURL.absoluteString,
                "expiresAt": evt.expiresAt.map(ISO8601DateFormatter().string(from:)) ?? NSNull(),
            ]
        case .askUser(let eventID, let evt):
            return [
                "type": "askUser",
                "eventID": eventID,
                "prompt": evt.prompt,
                "kind": askInputKindAsJSON(evt.kind),
                "expiresAt": evt.expiresAt.map(ISO8601DateFormatter().string(from:)) ?? NSNull(),
            ]
        case .askUserAnswer(let promptEventID, let selectedValues):
            return [
                "type": "askUserAnswer",
                "promptEventID": promptEventID,
                "selectedValues": selectedValues,
            ]
        case .activityIndicator(let label):
            return [
                "type": "activityIndicator",
                "label": label,
            ]
        case .toolStreamLive(let messageRef, let command, let text, let headTruncated):
            return [
                "type": "toolStreamLive",
                "messageRef": messageRef,
                "command": command ?? NSNull(),
                "text": text,
                "headTruncated": headTruncated,
            ]
        case .unknown(let eventType):
            return [
                "type": "unknown",
                "eventType": eventType,
            ]
        }
    }

    private func askInputKindAsJSON(_ kind: AskUserEvent.InputKind) -> [String: Any] {
        switch kind {
        case .text:
            return ["kind": "text"]
        case .boolean:
            return ["kind": "boolean"]
        case .choice(let options, let allowOther):
            return [
                "kind": "choice",
                "allowOther": allowOther,
                "options": options.map { ["id": $0.id, "label": $0.label, "value": $0.value] },
            ]
        case .multiChoice(let options, let allowOther):
            return [
                "kind": "multiChoice",
                "allowOther": allowOther,
                "options": options.map { ["id": $0.id, "label": $0.label, "value": $0.value] },
            ]
        }
    }

    private func sendStateAsJSON() -> [String: Any] {
        switch sendState {
        case .sent:
            return ["status": "sent"]
        case .sending:
            return ["status": "sending"]
        case .failed(let reason):
            return ["status": "failed", "reason": reason]
        }
    }
}
