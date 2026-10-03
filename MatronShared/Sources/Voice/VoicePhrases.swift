import Foundation
import MatronModels

/// Every fixed thing voice mode says. One place, so the wording can be
/// read and changed without hunting through the engine, and so the player
/// knows which lines are worth caching (`fixed`).
public enum VoicePhrases {
    public static let sent = "Sent."
    public static let cancelled = "Cancelled."
    public static let notSent = "OK, not sent."
    public static let denied = "Denied."
    public static let queueDone = "That's everything."
    /// Said after the first few replies. It must not contain the command
    /// it teaches ("more"), nor any other: a command said over a clip
    /// that contains it is taken for the clip's own words and ignored.
    public static let moreHint = "Ask for the detail if you want it."
    public static let goOn = "Go on?"
    public static let wholeMessage = "That's the whole message."
    public static let nothingToRepeat = "There's nothing to repeat."
    public static let needsScreen = "That one needs the screen. It's in your tracker."
    public static let noConnection = "No connection. I'll send it when you're back online."
    public static let notSentOffline = "No connection. That wasn't sent."
    public static let permissionExpired = "That permission request timed out and was denied."
    public static let allowOrDeny = "Say allow or deny."
    public static let nowhereToSend = "There's no conversation to send that to."
    public static let talkOverOff = "I keep hearing myself on this speaker, so talking over me is off. Tap the screen to interrupt."
    public static let microphoneFailed = "I can't use the microphone."

    /// The lines said often enough to keep on the phone after first use
    /// (spec §3, "Playing").
    public static let fixed: [String] = [
        sent, cancelled, notSent, denied, queueDone, moreHint, goOn, wholeMessage, nothingToRepeat, needsScreen,
        noConnection, notSentOffline, permissionExpired, allowOrDeny, nowhereToSend, talkOverOff, microphoneFailed,
    ] + (0...12).map(needsYou)

    /// "Nothing needs you." / "One thing needs you." / "Three things need you."
    public static func needsYou(_ count: Int) -> String {
        switch count {
        case ..<1: return "Nothing needs you."
        case 1: return "One thing needs you."
        default: return "\(capitalised(spelled(count))) things need you."
        }
    }

    public static func sending(_ label: String) -> String { "Sending: \(label)." }
    public static func didYouMean(_ label: String) -> String { "Did you mean \(label)?" }

    public static func busy(_ boxName: String?) -> String {
        "\(boxName ?? "The agent") is busy. It will get this when it finishes."
    }

    /// "Options: Go, Wait." Empty for no labels.
    public static func options(_ labels: [String]) -> String {
        labels.isEmpty ? "" : "Options: \(labels.joined(separator: ", "))."
    }

    public static func item(_ item: VoiceItem) -> String {
        if item.needsScreen { return needsScreen }
        let lead: String
        switch item.kind {
        case .question: lead = "A question"
        case .decision: lead = "A decision"
        case .task: lead = "A task"
        }
        return joined(["\(lead): \(ended(item.title))", options(item.labels)])
    }

    public static func prompt(_ prompt: VoicePrompt, boxName: String?) -> String {
        if let permission = prompt.permission {
            let who = boxName ?? "The agent"
            let what = permission.tool == "Bash" ? "run a command" : "use \(permission.tool)"
            let detail = permission.detail.isEmpty ? "." : ": \(ended(permission.detail))"
            return "\(who) wants to \(what)\(detail) Allow or deny?"
        }
        return joined([ended(prompt.question), options(prompt.labels)])
    }

    /// What is said for an entry. In the queue the conversation is named
    /// first, since each entry may come from a different one.
    public static func reading(_ entry: VoiceEntry, inQueue: Bool) -> String {
        let place = inQueue && !entry.convoTitle.isEmpty ? "\(ended(entry.convoTitle))" : ""
        switch entry.subject {
        case .reply(let reply): return joined([place, reply.short])
        case .item(let item): return self.item(item)
        case .prompt(let prompt):
            let lead = prompt.isPermission && !place.isEmpty ? "In \(place)" : place
            return joined([lead, self.prompt(prompt, boxName: entry.boxName)])
        }
    }

    // MARK: Helpers

    private static func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `text` ending like a sentence.
    static func ended(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    private static let speller: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_GB")
        return formatter
    }()

    static func spelled(_ number: Int) -> String {
        speller.string(from: NSNumber(value: number)) ?? String(number)
    }

    private static func capitalised(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
