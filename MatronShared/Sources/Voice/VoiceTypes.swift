import Foundation
import MatronChat
import MatronEvents
import MatronJournal
import MatronModels

/// One reply as voice mode says it, in the three levels of spec 2026-10-03
/// §1: `short` when the turn ends, `more` on the first "more", then
/// `sections` (the message itself, about a minute each).
public struct SpokenReply: Equatable, Sendable {
    public let convoID: String
    /// The reply's journal seq: what "already heard" is measured against.
    public let seq: Int64
    public let short: String
    public let more: String?
    public let sections: [String]

    public init(convoID: String, seq: Int64, short: String, more: String? = nil, sections: [String] = []) {
        self.convoID = convoID; self.seq = seq; self.short = short; self.more = more; self.sections = sections
    }
}

/// A tracker item as voice mode reads and answers it.
public struct VoiceItem: Equatable, Sendable {
    public let id: String
    public let kind: ItemKind
    public let convoID: String
    public let title: String
    /// The item's action labels while it is open; `[]` when it has none.
    public let labels: [String]
    /// The body through the cleaner, for "more".
    public let sections: [String]
    /// A secret request or a consent card: it cannot be answered by voice.
    public let needsScreen: Bool

    public init(id: String, kind: ItemKind, convoID: String, title: String, labels: [String] = [],
                sections: [String] = [], needsScreen: Bool = false) {
        self.id = id; self.kind = kind; self.convoID = convoID; self.title = title
        self.labels = labels; self.sections = sections; self.needsScreen = needsScreen
    }

    /// `sections` come from the caller because the cleaner lives beside the
    /// Markdown renderers, which this module does not import.
    public init(_ item: TrackerItem, sections: [String]) {
        self.init(id: item.id, kind: item.kind, convoID: item.originConvoID, title: item.title,
                  labels: item.offeredActions, sections: sections, needsScreen: Self.needsScreen(item))
    }

    /// Secret requests carry the `secret` label (matron-bridge
    /// `lib/secret-requests.js`); consent asks carry a consent link and
    /// the `consent` label (matron-journal `src/consent-items.js`).
    public static func needsScreen(_ item: TrackerItem) -> Bool {
        item.labels.contains("secret") || item.labels.contains("consent")
            || item.links.contains { ConsentLink.parse($0.url) != nil }
    }
}

/// An ask-user or tool-permission prompt as voice mode reads and answers
/// it. Answered with the `prompt_reply` op: `choice` is an option's
/// `value`, or `text` for a free answer.
public struct VoicePrompt: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let label: String
        public let value: String
        public init(label: String, value: String) { self.label = label; self.value = value }
    }

    /// A tool-permission card's two facts: the tool, and what it would run.
    public struct Permission: Equatable, Sendable {
        public let tool: String
        public let detail: String
        public init(tool: String, detail: String) { self.tool = tool; self.detail = detail }
    }

    public let convoID: String
    /// The prompt's journal seq: `prompt_reply.target_seq`.
    public let seq: Int64
    public let question: String
    public let options: [Option]
    public let allowsFreeText: Bool
    public let permission: Permission?

    public init(convoID: String, seq: Int64, question: String, options: [Option] = [],
                allowsFreeText: Bool = false, permission: Permission? = nil) {
        self.convoID = convoID; self.seq = seq; self.question = question; self.options = options
        self.allowsFreeText = allowsFreeText; self.permission = permission
    }

    public var isPermission: Bool { permission != nil }
    public var labels: [String] { options.map(\.label) }

    /// The option a spoken verdict stands for: the bridge's permission
    /// buttons carry `perm:<request id>:allow|always|deny` as their value.
    public func option(for verdict: ActionLabelMatcher.PermissionVerdict) -> Option? {
        options.first { $0.value.hasSuffix(":\(verdict.rawValue)") }
    }

    /// From a `prompt` journal row, through the decoding the timeline uses
    /// (`JournalTimelineMapper.askUserEvent(fromPrompt:)`).
    public init?(event: JournalEvent) {
        guard event.type == JournalEventType.prompt else { return nil }
        let ask = JournalTimelineMapper.askUserEvent(fromPrompt: event.payload)
        let options: [Option]
        var allowsFreeText = false
        switch ask.kind {
        case .choice(let list, let other), .multiChoice(let list, let other):
            options = list.map { Option(label: $0.label, value: $0.value) }
            allowsFreeText = other
        case .text, .boolean:
            options = []
            allowsFreeText = true
        }
        self.init(convoID: event.convoID, seq: event.seq, question: ask.prompt, options: options,
                  allowsFreeText: allowsFreeText, permission: Self.permission(question: ask.prompt, options: options))
    }

    private static let permissionValue = try! NSRegularExpression(
        pattern: #"^perm:[0-9a-f-]{36}:(allow|always|deny)$"#)
    /// The command a permission card shows is cut here before it is said
    /// (spec §3, "What is spoken").
    public static let permissionDetailLimit = 80

    /// A tool-permission card is a `prompt` whose every button answers
    /// `perm:<uuid>:<verdict>` (matron-bridge `lib/permission-prompt.js`,
    /// `permissionButtons`). Its text is "🔐 Permission: Claude wants to
    /// run <tool>" and, on the lines after, a preview of the input.
    static func permission(question: String, options: [Option]) -> Permission? {
        guard options.count >= 2, options.allSatisfy({ option in
            permissionValue.firstMatch(in: option.value, range: NSRange(option.value.startIndex..., in: option.value)) != nil
        }) else { return nil }
        let lines = question.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let head = lines.first ?? ""
        let tool = head.range(of: "wants to run ").map { String(head[$0.upperBound...]) } ?? "a tool"
        let detail = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return Permission(tool: tool.trimmingCharacters(in: .whitespaces),
                          detail: String(detail.prefix(permissionDetailLimit)))
    }
}

/// What voice mode can read out and take an answer to.
public enum VoiceSubject: Equatable, Sendable {
    case reply(SpokenReply)
    case item(VoiceItem)
    case prompt(VoicePrompt)
}

/// One thing for voice mode to say: a subject, plus where it came from.
/// `id` is stable across rebuilds (`prompt:<seq>`, `item:<id>`,
/// `reply:<convo>:<seq>`), so a thing already said is not said twice.
public struct VoiceEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let convoID: String
    public let convoTitle: String
    public let boxName: String?
    public let subject: VoiceSubject

    public init(id: String, convoID: String, convoTitle: String, boxName: String? = nil, subject: VoiceSubject) {
        self.id = id; self.convoID = convoID; self.convoTitle = convoTitle; self.boxName = boxName; self.subject = subject
    }

    public static func reply(_ reply: SpokenReply, convoTitle: String, boxName: String? = nil) -> VoiceEntry {
        VoiceEntry(id: "reply:\(reply.convoID):\(reply.seq)", convoID: reply.convoID, convoTitle: convoTitle,
                   boxName: boxName, subject: .reply(reply))
    }

    public static func item(_ item: VoiceItem, convoTitle: String, boxName: String? = nil) -> VoiceEntry {
        VoiceEntry(id: "item:\(item.id)", convoID: item.convoID, convoTitle: convoTitle, boxName: boxName, subject: .item(item))
    }

    public static func prompt(_ prompt: VoicePrompt, convoTitle: String, boxName: String? = nil) -> VoiceEntry {
        VoiceEntry(id: "prompt:\(prompt.seq)", convoID: prompt.convoID, convoTitle: convoTitle, boxName: boxName,
                   subject: .prompt(prompt))
    }

    /// The labels on offer, for the screen's buttons and the matcher.
    public var labels: [String] {
        switch subject {
        case .reply: return []
        case .item(let item): return item.needsScreen ? [] : item.labels
        case .prompt(let prompt): return prompt.labels
        }
    }
}
