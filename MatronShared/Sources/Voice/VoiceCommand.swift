import Foundation

/// A whole-utterance command (spec 2026-10-03 §3, "What happens to what Dan
/// said", and §4's confirmations). An utterance is a command only when it
/// is the command and nothing else, in any natural phrasing: "tell me
/// more" is `.more`; "tell me more about the tests" is a message for the
/// agent.
public enum VoiceCommand: String, Equatable, Sendable, CaseIterable {
    case `repeat`, more, skip, stop, cancel, yes, no

    /// The command `utterance` is, or `nil` when it is anything else.
    public static func parse(_ utterance: String) -> VoiceCommand? {
        let words = core(VoiceText.words(utterance))
        guard !words.isEmpty else { return nil }
        return table[words.joined(separator: " ")]
    }

    /// Words that may wrap a command without changing it ("um, stop
    /// please"). Stripped from both ends, never from the middle, and never
    /// down to nothing: "okay" alone is still `.yes`.
    private static let leading: Set<String> = ["um", "uh", "er", "erm", "hey", "ok", "okay", "so", "well", "and", "now", "please", "matron", "just"]
    private static let trailing: Set<String> = ["please", "thanks", "thank", "you", "now", "matron", "then"]

    private static func core(_ words: [String]) -> [String] {
        var slice = words[...]
        while slice.count > 1, let first = slice.first, leading.contains(first) { slice = slice.dropFirst() }
        while slice.count > 1, let last = slice.last, trailing.contains(last) { slice = slice.dropLast() }
        return Array(slice)
    }

    private static let phrases: [VoiceCommand: [String]] = [
        .repeat: ["repeat", "repeat that", "repeat it", "say that again", "say it again", "again", "one more time",
                  "come again", "what was that", "pardon", "sorry what", "can you repeat that", "could you repeat that",
                  "what did you say"],
        .more: ["more", "tell me more", "i want to know more", "id like to know more", "go on", "carry on", "continue",
                "keep going", "more detail", "more details", "give me more", "say more", "yes more", "what else",
                "read on", "read the rest", "read it", "read the message", "read it out", "and then",
                // What the hint after a reply invites ("Ask for the detail if you want it.").
                "the detail", "give me the detail", "details", "go into detail", "whats the detail"],
        .skip: ["skip", "next", "skip it", "skip this", "skip that", "skip this one", "skip that one", "next one",
                "the next one", "move on", "pass"],
        .stop: ["stop", "stop talking", "be quiet", "quiet", "enough", "thats enough", "shut up", "pause", "hush",
                "stop it", "stop there"],
        .cancel: ["cancel", "cancel that", "cancel it", "never mind", "nevermind", "dont send", "dont send that",
                  "dont send it", "do not send", "do not send that", "do not send it", "scrap that", "forget it",
                  "forget that"],
        .yes: ["yes", "yeah", "yep", "yup", "correct", "thats right", "right", "do it", "sure", "ok", "okay",
               "affirmative", "go ahead", "yes do", "yes it is", "thats it", "thats the one"],
        .no: ["no", "nope", "nah", "wrong", "thats wrong", "no wait", "wait no", "not that", "no its not",
              "thats not it", "no thanks", "no thank"],
    ]

    private static let table: [String: VoiceCommand] = {
        var out: [String: VoiceCommand] = [:]
        for (command, list) in phrases {
            for phrase in list {
                precondition(out[phrase] == nil, "\(phrase) names two commands")
                out[phrase] = command
            }
        }
        return out
    }()
}

/// How voice mode compares what was heard with what it expects: lowercase
/// words with punctuation, emoji and apostrophes gone ("That's right." →
/// `["thats", "right"]`), so a recogniser's capitals and full stops never
/// decide a match.
public enum VoiceText {
    public static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" {
                continue
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
