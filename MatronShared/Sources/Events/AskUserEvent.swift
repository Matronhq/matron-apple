import Foundation

/// Decoded form of a `chat.matron.ask_user` Matrix event content blob.
/// Drives the `AskUserSheet` (iOS half-sheet) / `MacAskUserSheet`
/// (Mac fixed-size sheet) UI in Phase 5 Task 9. Four input kinds —
/// free-form text, single-choice, multi-choice, boolean — modelled
/// as an `InputKind` enum with associated values for the choice
/// variants so the sheet body can switch over them exhaustively.
///
/// `expiresAt` is optional: bots can omit it for indefinitely-valid
/// prompts; when present, the sheet should grey out the submit
/// button + show "expired" copy past the deadline.
public struct AskUserEvent: Equatable, Sendable {
    public enum InputKind: Equatable, Sendable {
        case text
        case choice(options: [Option], allowOther: Bool)
        case multiChoice(options: [Option], allowOther: Bool)
        case boolean
    }

    public struct Option: Equatable, Sendable {
        public let id: String
        public let label: String
        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public let prompt: String
    public let kind: InputKind
    public let expiresAt: Date?

    public init(prompt: String, kind: InputKind, expiresAt: Date?) {
        self.prompt = prompt
        self.kind = kind
        self.expiresAt = expiresAt
    }

    /// Parse a JSON `content` dictionary from a `chat.matron.ask_user`
    /// event. Returns `nil` if `prompt` / `input.kind` are missing or
    /// `kind` is an unknown string — graceful-degradation contract
    /// (callers fall back to plain-text rendering).
    public static func parse(content: [String: Any]) -> AskUserEvent? {
        guard let prompt = content["prompt"] as? String,
              let inputDict = content["input"] as? [String: Any],
              let kindRaw = inputDict["kind"] as? String else {
            return nil
        }
        let allowOther = inputDict["allow_other"] as? Bool ?? false
        let optionsArr = (inputDict["options"] as? [[String: Any]]) ?? []
        let options = optionsArr.compactMap { dict -> Option? in
            guard let id = dict["id"] as? String,
                  let label = dict["label"] as? String else {
                return nil
            }
            return Option(id: id, label: label)
        }
        let kind: InputKind
        switch kindRaw {
        case "text":
            kind = .text
        case "choice":
            kind = .choice(options: options, allowOther: allowOther)
        case "multi_choice":
            kind = .multiChoice(options: options, allowOther: allowOther)
        case "boolean":
            kind = .boolean
        default:
            return nil
        }
        let expiresAt = (content["expires_at"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        return AskUserEvent(prompt: prompt, kind: kind, expiresAt: expiresAt)
    }
}
