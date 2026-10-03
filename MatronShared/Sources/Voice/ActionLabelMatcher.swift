import Foundation

/// What an utterance says about a set of labels (spec 2026-10-03 §4).
public enum ActionMatch: Equatable, Sendable {
    /// The utterance is this label, or this label with filler: send it,
    /// with a read-back and a moment to cancel.
    case clear(String)
    /// Close to this label: ask "Did you mean …?" and send only on yes.
    case unsure(String)
    /// Not an answer to the options: send it as a spoken reply.
    case none
}

/// Matches what was heard against the labels of the item or prompt just
/// read out. The journal accepts an action only when it equals one of the
/// item's labels exactly, so the result is always one of `labels` as
/// written: a wrong match can pick the wrong real label, never invent one.
public enum ActionLabelMatcher {
    public static func match(_ utterance: String, labels: [String]) -> ActionMatch {
        let heard = VoiceText.words(utterance)
        guard !heard.isEmpty, !labels.isEmpty else { return .none }
        let labelWords = labels.map(VoiceText.words)
        // Filler never includes a word a label needs: every word of a label
        // made only of filler ("Go", "Yes"), and the telling words of the
        // others ("close" in "Close it", whose "it" stays filler).
        var protected: Set<String> = []
        for words in labelWords {
            let telling = words.filter { !baseFiller.contains($0) }
            protected.formUnion(telling.isEmpty ? words : telling)
        }
        let filler = baseFiller.subtracting(protected)
        let core = heard.filter { !filler.contains($0) }
        let labelCores = labelWords.map { $0.filter { !filler.contains($0) } }

        // 1. The label itself, with or without filler around it.
        if let exact = labelWords.firstIndex(of: heard) { return .clear(labels[exact]) }
        let sameCore = labelCores.indices.filter { !labelCores[$0].isEmpty && labelCores[$0] == core }
        if sameCore.count == 1 { return .clear(labels[sameCore[0]]) }
        if let first = sameCore.first { return .unsure(labels[first]) }
        // 2. "Option one", "the second one", "the last one".
        if let index = ordinal(heard, count: labels.count) { return .clear(labels[index]) }
        guard !core.isEmpty else { return .none }

        // 3. Near misses, best first. A tie goes to the earlier label.
        var best: (score: Double, index: Int)?
        func offer(_ score: Double, _ index: Int) {
            if best == nil || score > best!.score { best = (score, index) }
        }
        for (index, words) in labelCores.enumerated() where !words.isEmpty {
            if core.count < words.count, contains(words, run: core) {
                // Part of a label: "merge" for "Merge now".
                offer(0.9 * Double(core.count) / Double(words.count) + 0.05, index)
            } else if let extras = extras(in: core, around: words) {
                // The label inside a few more words: "go, I think".
                if extras.count <= maxExtras, !extras.contains(where: blockers.contains) {
                    offer(0.8 - 0.05 * Double(extras.count), index)
                }
            } else {
                let similarity = similarity(core.joined(separator: " "), words.joined(separator: " "))
                if similarity >= fuzzyThreshold { offer(0.7 * similarity, index) }
            }
        }
        if let best { return .unsure(labels[best.index]) }
        return .none
    }

    // MARK: Tool permissions

    /// What was said to a tool-permission prompt. Its three buttons are
    /// "Allow once", "Always allow <tool> (session)" and "Deny"; nobody
    /// says those labels, so the verdict is read from the words instead.
    public enum PermissionVerdict: String, Equatable, Sendable { case allow, always, deny }

    public static func permissionVerdict(_ utterance: String) -> PermissionVerdict? {
        let words = VoiceText.words(utterance).filter { !politeness.contains($0) }
        return permissionTable[words.joined(separator: " ")]
    }

    private static let politeness: Set<String> = ["please", "um", "uh", "er", "thanks", "thank", "you", "just", "it", "that", "this"]
    private static let permissionTable: [String: PermissionVerdict] = {
        let phrases: [PermissionVerdict: [String]] = [
            .allow: ["allow", "allow once", "yes", "yeah", "yep", "ok", "okay", "approve", "approved", "go ahead",
                     "do", "run", "fine", "sure", "permit", "yes allow", "let"],
            .always: ["always", "always allow", "allow always", "yes always"],
            .deny: ["deny", "denied", "no", "nope", "reject", "refuse", "block", "dont", "dont allow", "do not allow",
                    "dont run", "do not run", "stop", "cancel", "no deny", "no dont"],
        ]
        var out: [String: PermissionVerdict] = [:]
        for (verdict, list) in phrases { for phrase in list { out[phrase] = verdict } }
        return out
    }()

    // MARK: Rules

    static let maxExtras = 3
    static let fuzzyThreshold = 0.8

    /// Words that carry no choice. Deliberately broad: anything here that
    /// is also in a label stops being filler for that set of labels.
    static let baseFiller: Set<String> = [
        "yes", "yeah", "yep", "ok", "okay", "please", "um", "uh", "er", "erm", "thanks", "thank", "you",
        "i", "id", "ill", "we", "would", "like", "want", "choose", "pick", "select", "take", "say", "said",
        "lets", "go", "with", "for", "the", "that", "this", "one", "option", "answer", "it", "is", "its",
        "to", "do", "a", "an", "just", "think", "should", "definitely", "probably", "then", "and", "so",
    ]

    /// An utterance with one of these beside the label is not a choice:
    /// "don't go", "what does wait mean".
    static let blockers: Set<String> = [
        "not", "dont", "never", "neither", "nor", "cant", "wont", "shouldnt", "no", "without", "instead",
        "why", "what", "how", "when", "which", "who", "does", "explain", "mean", "means", "but", "if", "unless",
    ]

    private static let ordinals: [String: Int] = ["first": 0, "second": 1, "third": 2, "fourth": 3]
    private static let numbers: [String: Int] = ["one": 0, "two": 1, "three": 2, "four": 3, "1": 0, "2": 1, "3": 2, "4": 3]
    private static let ordinalLead: Set<String> = [
        "yes", "yeah", "ok", "okay", "please", "um", "uh", "i", "ill", "id", "take", "pick", "choose", "go",
        "with", "for", "lets", "the", "say", "think", "like", "would", "want",
    ]

    /// The index named by "option two", "the second one", "the last".
    /// The whole utterance must be the reference: "check the tests first"
    /// names nothing.
    private static func ordinal(_ heard: [String], count: Int) -> Int? {
        let words = heard.filter { !ordinalLead.contains($0) }
        let index: Int?
        switch words.count {
        case 1:
            index = words[0] == "last" ? count - 1 : ordinals[words[0]]
        case 2:
            if ["option", "number", "choice", "answer"].contains(words[0]) {
                index = numbers[words[1]]
            } else if ["one", "option", "choice", "answer"].contains(words[1]) {
                index = words[0] == "last" ? count - 1 : ordinals[words[0]]
            } else {
                index = nil
            }
        default:
            index = nil
        }
        guard let index, index >= 0, index < count else { return nil }
        return index
    }

    private static func contains(_ words: [String], run: [String]) -> Bool {
        guard !run.isEmpty, run.count <= words.count else { return false }
        return (0...(words.count - run.count)).contains { Array(words[$0..<($0 + run.count)]) == run }
    }

    /// The words of `core` outside the first place `label` appears in it,
    /// or `nil` when it does not appear (or is all of it).
    private static func extras(in core: [String], around label: [String]) -> [String]? {
        guard core.count > label.count else { return nil }
        for start in 0...(core.count - label.count) where Array(core[start..<(start + label.count)]) == label {
            return Array(core[..<start]) + Array(core[(start + label.count)...])
        }
        return nil
    }

    /// 1 for the same string, 0 for nothing in common (Levenshtein
    /// distance over the longer length).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }
}
