import Foundation
import MatronChat
import MatronJournal
import MatronModels

/// One thing that needs the user, before it is turned into speech: what
/// the queue orders, the app shell counts, and Siri names.
public struct NeedsYouEntry: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case permission(VoicePrompt)
        case prompt(VoicePrompt)
        case item(TrackerItem)
        /// A conversation whose last turn ended with a reply not yet seen.
        case unseenReply
    }

    public let kind: Kind
    public let convoID: String
    /// The conversation's title without its session short.
    public let convoTitle: String
    public let boxName: String?
    /// One line naming the thing: Siri's "the first is …".
    public let title: String

    public var id: String {
        switch kind {
        case .permission(let prompt), .prompt(let prompt): return "prompt:\(prompt.seq)"
        case .item(let item): return "item:\(item.id)"
        case .unseenReply: return "convo:\(convoID)"
        }
    }
}

/// A conversation as the queue sees it: the columns of `ConversationRecord`
/// that decide whether its last reply is waiting to be heard.
public struct QueueConversation: Equatable, Sendable {
    public let id: String
    public let title: String
    public let boxName: String?
    public let unreadCount: Int
    public let sessionState: String
    public let lastActivity: Date?
    public let muted: Bool

    public init(id: String, title: String, boxName: String? = nil, unreadCount: Int, sessionState: String,
                lastActivity: Date? = nil, muted: Bool = false) {
        self.id = id; self.title = title; self.boxName = boxName; self.unreadCount = unreadCount
        self.sessionState = sessionState; self.lastActivity = lastActivity; self.muted = muted
    }
}

/// "What needs you" (spec 2026-10-03 §5), built on the device from what it
/// already syncs:
///
/// 1. tool-permission prompts (they are denied after five minutes),
/// 2. ask-user prompts,
/// 3. tracker items awaiting the user, in tracker order,
/// 4. conversations whose last turn ended with a reply not yet seen.
public enum NeedsYouQueue {
    /// The bridge denies an unanswered permission card after this long
    /// (matron-bridge `DEFAULT_PERMISSION_TIMEOUT_MS`).
    public static let permissionTTL: TimeInterval = 300
    /// An ask-user prompt older than this is history, not a question.
    public static let promptMaxAge: TimeInterval = 24 * 60 * 60

    public static func build(prompts: [UnansweredPromptRow], items: [TrackerItem],
                             conversations: [QueueConversation], now: Date) -> [NeedsYouEntry] {
        var permissions: [NeedsYouEntry] = []
        var asks: [NeedsYouEntry] = []
        var promptConvos: Set<String> = []
        for row in prompts.sorted(by: { $0.event.seq < $1.event.seq }) {
            guard let prompt = VoicePrompt(event: row.event) else { continue }
            let age = now.timeIntervalSince(row.event.ts)
            let title = cleanTitle(row.convoTitle)
            if let permission = prompt.permission {
                guard age < permissionTTL else { continue }
                let what = permission.tool == "Bash" ? "run a command" : "use \(permission.tool)"
                permissions.append(NeedsYouEntry(kind: .permission(prompt), convoID: row.event.convoID, convoTitle: title,
                                                 boxName: row.agentName,
                                                 title: "\(row.agentName ?? "An agent") wants to \(what)"))
            } else {
                guard age < promptMaxAge else { continue }
                asks.append(NeedsYouEntry(kind: .prompt(prompt), convoID: row.event.convoID, convoTitle: title,
                                          boxName: row.agentName, title: firstLine(prompt.question)))
            }
            promptConvos.insert(row.event.convoID)
        }

        let titles = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let awaiting = items.filter(\.needsUser).sorted { ($0.rank, $0.num) < ($1.rank, $1.num) }.map { item in
            NeedsYouEntry(kind: .item(item), convoID: item.originConvoID,
                          convoTitle: cleanTitle(titles[item.originConvoID]?.title ?? ""),
                          boxName: titles[item.originConvoID]?.boxName, title: item.title)
        }

        let unseen = conversations
            .filter { $0.unreadCount > 0 && $0.sessionState != "running" && !$0.muted && !promptConvos.contains($0.id) }
            .sorted { ($0.lastActivity ?? .distantPast, $1.id) > ($1.lastActivity ?? .distantPast, $0.id) }
            .map { convo -> NeedsYouEntry in
                let title = cleanTitle(convo.title)
                return NeedsYouEntry(kind: .unseenReply, convoID: convo.id, convoTitle: title, boxName: convo.boxName,
                                     title: title.isEmpty ? "A reply" : title)
            }

        return permissions + asks + awaiting + unseen
    }

    /// What Siri says for "what needs me" (spec §10): the count and the
    /// first thing's title.
    public static func summary(_ entries: [NeedsYouEntry]) -> String {
        guard let first = entries.first else { return VoicePhrases.needsYou(0) }
        let lead = VoicePhrases.needsYou(entries.count)
        return entries.count == 1 ? "\(lead) \(VoicePhrases.ended(first.title))"
            : "\(lead) The first: \(VoicePhrases.ended(first.title))"
    }

    /// A stored title without the bridge's `[ab] ` session short.
    static func cleanTitle(_ raw: String) -> String {
        SessionTag.splitTitle(raw).title
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return String(line.prefix(80))
    }
}

extension JournalStore {
    /// The queue's inputs, read from this store in one go.
    public func needsYouEntries(now: Date = Date()) throws -> [NeedsYouEntry] {
        let prompts = try unansweredPrompts(since: now.addingTimeInterval(-NeedsYouQueue.promptMaxAge))
        let names = try agentNames()
        let conversations = try conversations(now: now).map { record in
            QueueConversation(id: record.id, title: record.title,
                              boxName: record.agentDeviceID.flatMap { names[$0] },
                              unreadCount: record.unreadCount, sessionState: record.sessionState,
                              lastActivity: record.lastActivityTS.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                              muted: record.muted)
        }
        return NeedsYouQueue.build(prompts: prompts, items: try items(scope: .all),
                                   conversations: conversations, now: now)
    }
}
