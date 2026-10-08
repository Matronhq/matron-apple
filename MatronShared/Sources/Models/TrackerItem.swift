import Foundation

/// `notice` is an FYI the user should read but need not decide: filed
/// awaiting the user with a single "Seen" action, and closed by the
/// journal when that is tapped. The journal only sends `notice` to clients
/// that ask for it (`JournalAPI.itemKindsHeader`); older ones get `task`.
public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case task, question, decision, notice

    /// The kinds a person can file from the create sheets. A notice is
    /// something an agent files for the user to read, never the other way
    /// round.
    public static let creatable: [ItemKind] = [.task, .question, .decision]
}
public enum ItemState: String, Codable, Sendable { case open, closed }
public enum ItemResolution: String, Codable, Sendable, CaseIterable { case done, answered, decided, reversed, cancelled }
public enum ItemAwaiting: String, Codable, Sendable { case user, agent }
public enum ItemAuthor: String, Codable, Sendable { case user, agent }

/// Which items a list/query covers: one origin conversation, or every
/// conversation. Lives in Models (not Journal, where it originated) so
/// DesignSystem views like `ItemsListView` can take a `Binding<ItemsScope>`
/// without importing MatronJournal — DesignSystem may depend on
/// Models/Events/Search but never on Journal or ViewModels.
public enum ItemsScope: Equatable, Hashable, Sendable { case convo(String), all }

public struct TrackerAttachment: Equatable, Hashable, Sendable, Codable {
    public let blobRef: String
    public let mime: String
    public let name: String
    public let size: Int64
    public var transcript: String?
    /// The journal's own transcription job for this voice note: `"pending"`
    /// while it runs, then `"done"` or `"failed"`. `nil` when the journal
    /// never took the job (the origin bridge transcribes instead) — which,
    /// like `"pending"`, still reads as "Transcribing…" until words arrive.
    public var transcriptStatus: String?
    /// An image's displayed pixel size, read by the journal from the blob's
    /// own header (EXIF/irot orientation applied) and stamped on the
    /// attachment — `nil` for non-images, older journals, and images the
    /// journal couldn't size. Lets the thread reserve the image's real box
    /// before its bytes load, so nothing below it moves when it arrives.
    public var width: Int?
    public var height: Int?
    public init(blobRef: String, mime: String, name: String, size: Int64, transcript: String? = nil, transcriptStatus: String? = nil,
                width: Int? = nil, height: Int? = nil) {
        self.blobRef = blobRef; self.mime = mime; self.name = name; self.size = size; self.transcript = transcript
        self.transcriptStatus = transcriptStatus
        self.width = width; self.height = height
    }
    /// `width × height` when both are known and positive.
    public var pixelSize: CGSize? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }
    /// Nobody produced words and nobody is still trying: the journal's job
    /// failed. (A bridge that then transcribes it itself flips this back to
    /// `"done"` server-side, and the next refresh shows the words.)
    public var transcriptionFailed: Bool { isAudio && (transcript ?? "").isEmpty && transcriptStatus == "failed" }
    public init?(json: [String: Any]) {
        guard let blobRef = json["blob_ref"] as? String, let mime = json["mime"] as? String else { return nil }
        self.init(blobRef: blobRef, mime: mime, name: json["name"] as? String ?? "",
                  size: (json["size"] as? NSNumber)?.int64Value ?? 0, transcript: json["transcript"] as? String,
                  transcriptStatus: json["transcript_status"] as? String,
                  width: (json["width"] as? NSNumber)?.intValue, height: (json["height"] as? NSNumber)?.intValue)
    }
    public var isImage: Bool { mime.hasPrefix("image/") }
    public var isAudio: Bool { mime.hasPrefix("audio/") }
    public var json: [String: Any] {
        var o: [String: Any] = ["blob_ref": blobRef, "mime": mime, "name": name, "size": size]
        if let transcript { o["transcript"] = transcript }
        if let transcriptStatus { o["transcript_status"] = transcriptStatus }
        if let width { o["width"] = width }
        if let height { o["height"] = height }
        return o
    }
}

public struct TrackerLink: Equatable, Hashable, Sendable, Codable {
    public let url: String
    public let title: String?
    public init(url: String, title: String? = nil) { self.url = url; self.title = title }
    public init?(json: [String: Any]) {
        guard let url = json["url"] as? String else { return nil }
        self.init(url: url, title: json["title"] as? String)
    }
}

public struct TrackerItem: Identifiable, Equatable, Hashable, Sendable {
    public struct StatusSnapshot: Equatable, Hashable, Sendable {
        public let state: ItemState?
        public let resolution: ItemResolution?
        public let awaiting: ItemAwaiting?
        public init(state: ItemState?, resolution: ItemResolution?, awaiting: ItemAwaiting?) {
            self.state = state; self.resolution = resolution; self.awaiting = awaiting
        }
        init?(json: [String: Any]?) {
            guard let json else { return nil }
            self.init(state: (json["state"] as? String).flatMap(ItemState.init(rawValue:)),
                      resolution: (json["resolution"] as? String).flatMap(ItemResolution.init(rawValue:)),
                      awaiting: (json["awaiting"] as? String).flatMap(ItemAwaiting.init(rawValue:)))
        }
    }

    public let id: String
    public let num: Int
    public let kind: ItemKind
    public let state: ItemState
    public let resolution: ItemResolution?
    public let awaiting: ItemAwaiting?
    public let rank: Double
    public let title: String
    public let body: String
    public let labels: [String]
    public let links: [TrackerLink]
    public let attachments: [TrackerAttachment]
    public let supersedes: String?
    public let originConvoID: String
    public let createdBy: ItemAuthor
    public let createdAt: Date
    public let updatedAt: Date
    public let closedAt: Date?
    public let commentCount: Int
    public let lastCommentAt: Date?
    public let hasImage: Bool
    /// The mission this item belongs to, defaulted by the journal from the
    /// origin conversation and repointable by an agent (`item_move`). The
    /// apps only ever DISPLAY it. Both are `nil` for an item filed in a
    /// conversation with no mission — and `missionID` can be present while
    /// the mission itself is invisible to this caller (protocol, "Accepted
    /// exception"), so never assume a local `mission` row exists for it.
    public let missionID: String?
    public let missionNum: Int?
    /// The origin conversation's title as the journal has it (at most 200
    /// characters), so the item detail can name where the item came from
    /// when this device has no row for that conversation. `nil` when the
    /// conversation is untitled or gone, for a granted item (whose
    /// `originConvoID` is `""`), and from a journal that predates it.
    public let originConvoTitle: String?
    /// One-tap answers an agent attached to the item (item action buttons,
    /// contract 2026-09-24) — tapping one posts it as the user's reply.
    /// `[]` from a journal that predates the field.
    public let actions: [String]
    /// The label of the most recent action the user tapped, as the journal
    /// records it; `nil` when none has been, or `actions` changed since.
    public let chosenAction: String?
    /// When the user last acted on the item, as the journal derives it:
    /// their latest comment, action tap, close or reopen, else the filing
    /// time of an item they filed. `nil` when only agents have touched
    /// it, and from a journal that predates the field.
    public let lastUserInputAt: Date?

    public init(id: String, num: Int, kind: ItemKind, state: ItemState = .open, resolution: ItemResolution? = nil,
                awaiting: ItemAwaiting? = nil, rank: Double = 1024, title: String, body: String = "",
                labels: [String] = [], links: [TrackerLink] = [], attachments: [TrackerAttachment] = [],
                supersedes: String? = nil, originConvoID: String, createdBy: ItemAuthor = .agent,
                createdAt: Date = Date(), updatedAt: Date = Date(), closedAt: Date? = nil,
                commentCount: Int = 0, lastCommentAt: Date? = nil, hasImage: Bool = false,
                missionID: String? = nil, missionNum: Int? = nil, actions: [String] = [], chosenAction: String? = nil,
                originConvoTitle: String? = nil, lastUserInputAt: Date? = nil) {
        self.id = id; self.num = num; self.kind = kind; self.state = state; self.resolution = resolution
        self.awaiting = awaiting; self.rank = rank; self.title = title; self.body = body; self.labels = labels
        self.links = links; self.attachments = attachments; self.supersedes = supersedes
        self.originConvoID = originConvoID; self.createdBy = createdBy; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.closedAt = closedAt; self.commentCount = commentCount
        self.lastCommentAt = lastCommentAt; self.hasImage = hasImage
        self.missionID = missionID; self.missionNum = missionNum
        self.actions = actions; self.chosenAction = chosenAction
        self.originConvoTitle = originConvoTitle
        self.lastUserInputAt = lastUserInputAt
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let num = (json["num"] as? NSNumber)?.intValue,
              let kind = (json["kind"] as? String).flatMap(ItemKind.init(rawValue:)),
              let state = (json["state"] as? String).flatMap(ItemState.init(rawValue:)),
              let title = json["title"] as? String, let origin = json["origin_convo_id"] as? String,
              let createdAt = msDate(json["created_at"]), let updatedAt = msDate(json["updated_at"])
        else { return nil }
        let hasImageRaw = json["has_image"]
        self.init(
            id: id, num: num, kind: kind, state: state,
            resolution: (json["resolution"] as? String).flatMap(ItemResolution.init(rawValue:)),
            awaiting: (json["awaiting"] as? String).flatMap(ItemAwaiting.init(rawValue:)),
            rank: (json["rank"] as? NSNumber)?.doubleValue ?? 0, title: title, body: json["body"] as? String ?? "",
            labels: json["labels"] as? [String] ?? [],
            links: (json["links"] as? [[String: Any]] ?? []).compactMap(TrackerLink.init(json:)),
            attachments: (json["attachments"] as? [[String: Any]] ?? []).compactMap(TrackerAttachment.init(json:)),
            supersedes: json["supersedes"] as? String, originConvoID: origin,
            createdBy: (json["created_by"] as? String).flatMap(ItemAuthor.init(rawValue:)) ?? .agent,
            createdAt: createdAt, updatedAt: updatedAt, closedAt: msDate(json["closed_at"]),
            commentCount: (json["comment_count"] as? NSNumber)?.intValue ?? 0,
            lastCommentAt: msDate(json["last_comment_at"]),
            hasImage: (hasImageRaw as? Bool) ?? (((hasImageRaw as? NSNumber)?.intValue ?? 0) != 0),
            missionID: json["mission_id"] as? String,
            missionNum: (json["mission_num"] as? NSNumber)?.intValue,
            actions: json["actions"] as? [String] ?? [],
            chosenAction: json["chosen_action"] as? String,
            originConvoTitle: (json["origin_convo_title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            lastUserInputAt: msDate(json["last_user_input_at"]))
    }

    /// Where a closed item sorts in the For you list's Closed tab, and the
    /// time its row shows: the user's own last input when the journal
    /// reports one, else when it was closed. An agent often closes an item
    /// long after the user answered it, so the close time alone buries a
    /// decision the user has just made.
    public var closedSortDate: Date { lastUserInputAt ?? closedAt ?? updatedAt }

    public var needsUser: Bool { state == .open && awaiting == .user }

    /// The label of a notice's one action. Tapping it posts the ordinary
    /// action reply, and the journal closes the notice as done.
    public static let seenAction = "Seen"

    /// Whether this is an open notice that still offers its "Seen" button
    /// — the For you row's one-tap button and swipe action.
    public var offersSeen: Bool { kind == .notice && offeredActions.contains(Self.seenAction) }

    /// The action buttons the detail view offers: all of them while the
    /// item is open, none once it is closed (the contract hides them — a
    /// closed item takes a reply, not a button press).
    public var offeredActions: [String] { state == .open ? actions : [] }
}

public struct TrackerComment: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case comment, status }
    public let id: String
    public let itemID: String
    public let author: ItemAuthor
    public let deviceID: Int64
    public let kind: Kind
    public let body: String
    public let attachments: [TrackerAttachment]
    public let statusFrom: TrackerItem.StatusSnapshot?
    public let statusTo: TrackerItem.StatusSnapshot?
    public let createdAt: Date
    /// The action this reply was a tap on (its `body` is the same label),
    /// or `nil` for a typed reply and on journals that predate action
    /// buttons. With `replyTo` it answered that comment's buttons; without,
    /// the item's own.
    public let action: String?
    /// One-tap answers an agent attached to this comment (comment action
    /// buttons, contract 2026-10-04) — a follow-up question in the thread.
    /// `[]` on every other comment and from a journal that predates them.
    public let actions: [String]
    /// The label of the most recent tap on `actions`, as the journal
    /// records it; `nil` when none has been tapped.
    public let chosenAction: String?
    /// The comment whose buttons this tap answered; `nil` for a tap on the
    /// item's own buttons and for every reply that is not a tap.
    public let replyTo: String?

    public init(id: String, itemID: String, author: ItemAuthor, deviceID: Int64 = 0, kind: Kind = .comment,
                body: String, attachments: [TrackerAttachment] = [], statusFrom: TrackerItem.StatusSnapshot? = nil,
                statusTo: TrackerItem.StatusSnapshot? = nil, createdAt: Date = Date(), action: String? = nil,
                actions: [String] = [], chosenAction: String? = nil, replyTo: String? = nil) {
        self.id = id; self.itemID = itemID; self.author = author; self.deviceID = deviceID; self.kind = kind
        self.body = body; self.attachments = attachments; self.statusFrom = statusFrom; self.statusTo = statusTo
        self.createdAt = createdAt; self.action = action
        self.actions = actions; self.chosenAction = chosenAction; self.replyTo = replyTo
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let itemID = json["item_id"] as? String,
              let author = (json["author"] as? String).flatMap(ItemAuthor.init(rawValue:)),
              let kind = (json["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let createdAt = msDate(json["created_at"]) else { return nil }
        let meta = json["meta"] as? [String: Any]
        self.init(id: id, itemID: itemID, author: author, deviceID: (json["device_id"] as? NSNumber)?.int64Value ?? 0,
                  kind: kind, body: json["body"] as? String ?? "",
                  attachments: (json["attachments"] as? [[String: Any]] ?? []).compactMap(TrackerAttachment.init(json:)),
                  statusFrom: TrackerItem.StatusSnapshot(json: meta?["from"] as? [String: Any]),
                  statusTo: TrackerItem.StatusSnapshot(json: meta?["to"] as? [String: Any]), createdAt: createdAt,
                  action: json["action"] as? String ?? meta?["action"] as? String,
                  actions: json["actions"] as? [String] ?? [],
                  chosenAction: json["chosen_action"] as? String,
                  replyTo: json["reply_to"] as? String ?? meta?["reply_to"] as? String)
    }

    /// The action buttons the thread offers under this comment: its
    /// actions while the item is open, none once it is closed — the rule
    /// the item's own buttons follow (`TrackerItem.offeredActions`).
    public func offeredActions(itemIsOpen: Bool) -> [String] { itemIsOpen ? actions : [] }

    /// This comment with `label` recorded as the tap on its buttons — what
    /// the journal's `chosen_action` will say once the thread is refetched.
    public func choosing(_ label: String) -> TrackerComment {
        TrackerComment(id: id, itemID: itemID, author: author, deviceID: deviceID, kind: kind, body: body,
                       attachments: attachments, statusFrom: statusFrom, statusTo: statusTo, createdAt: createdAt,
                       action: action, actions: actions, chosenAction: label, replyTo: replyTo)
    }
}
