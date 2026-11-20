import Foundation
import MatronModels

/// What a reply box holds but hasn't sent: the typed text and the staged
/// attachments (voice notes included).
public struct UnsentReply: Equatable, Sendable {
    public var text: String
    public var attachments: [StagedAttachment]

    public init(text: String = "", attachments: [StagedAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }
}

/// A reply box on screen that can take back a reply its sender could not
/// deliver (`UnsentReplyStore.giveBack`).
@MainActor
public protocol UnsentReplyBox: AnyObject {
    func takeBack(_ reply: UnsentReply)
}

/// Keeps every reply box's unsent contents on disk, one file per item or
/// conversation, so a reply survives leaving its page, the page's view
/// model going away, and the app restarting. Only Send, or the user
/// clearing the box, removes it. The files the reply holds stay where they
/// were staged (`StagedAttachment.stagingDirectory`); this saves which of
/// them belong to which box.
///
/// A box also records the replies it is sending (`beginSend`/`endSend`)
/// until each is queued or comes back. If the app dies in between, the
/// next launch puts those back in the box rather than losing them.
///
/// Sign-out wipes it all (`wipeAll()`), like the outbox.
@MainActor
public final class UnsentReplyStore {
    public enum Place: Hashable, Sendable {
        case item(String)
        case conversation(String)

        /// The file's name: the kind, then the id with anything that isn't
        /// safe in a file name percent-escaped.
        var fileName: String {
            let (kind, id): (String, String)
            switch self {
            case .item(let i): (kind, id) = ("item", i)
            case .conversation(let c): (kind, id) = ("conversation", c)
            }
            let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            let escaped = id.addingPercentEncoding(withAllowedCharacters: safe) ?? id
            return "\(kind)-\(escaped).json"
        }
    }

    private struct Record: Equatable {
        var box = UnsentReply()
        /// Replies between Send and queued, by their local id.
        var sending: [String: UnsentReply] = [:]
        var isEmpty: Bool { box.isEmpty && sending.isEmpty }
    }

    public let directory: URL
    private var cache: [Place: Record] = [:]
    private var boxes: [Place: WeakBox] = [:]
    /// Bumped by `wipeAll()`. A view model reads it when it is made and
    /// passes it back with every write, so a send that finishes after
    /// sign-out never saves the old account's reply again.
    public private(set) var epoch = 0

    private final class WeakBox {
        weak var box: UnsentReplyBox?
        init(_ box: UnsentReplyBox) { self.box = box }
    }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)
    }

    // MARK: Reading and saving a box

    /// What `place`'s box holds. The first read in a process also puts
    /// back any reply that was still sending when the app last stopped.
    public func reply(for place: Place) -> UnsentReply {
        record(for: place).box
    }

    /// Replaces `place`'s box. An empty box with nothing sending deletes
    /// the file.
    public func save(_ reply: UnsentReply, for place: Place, epoch: Int) {
        guard epoch == self.epoch else { return }
        var record = record(for: place)
        record.box = reply
        write(record, for: place)
    }

    // MARK: Sends in flight

    public func beginSend(_ id: String, _ reply: UnsentReply, for place: Place, epoch: Int) {
        guard epoch == self.epoch, !reply.isEmpty else { return }
        var record = record(for: place)
        record.sending[id] = reply
        write(record, for: place)
    }

    /// The send `id` was queued, or has been put back in a box.
    public func endSend(_ id: String, for place: Place, epoch: Int) {
        guard epoch == self.epoch else { return }
        var record = record(for: place)
        guard record.sending.removeValue(forKey: id) != nil else { return }
        write(record, for: place)
    }

    // MARK: Boxes on screen

    /// `box` is the one showing `place` now; a later registration for the
    /// same place replaces it.
    public func register(_ box: UnsentReplyBox, for place: Place) {
        boxes[place] = WeakBox(box)
    }

    public func unregister(_ box: UnsentReplyBox, for place: Place) {
        if boxes[place]?.box === box { boxes[place] = nil }
    }

    /// The box showing `place`, if one is.
    public func box(for place: Place) -> UnsentReplyBox? {
        boxes[place]?.box
    }

    /// A reply whose sender has gone (its page closed while it was
    /// uploading): handed to the box showing `place` if there is one, or
    /// put at the front of the saved box, its text after anything typed
    /// there.
    public func giveBack(_ reply: UnsentReply, to place: Place, epoch: Int) {
        guard epoch == self.epoch else {
            // From an account that has signed out: its files go too.
            reply.attachments.forEach { $0.deleteStagedCopy() }
            return
        }
        guard !reply.isEmpty else { return }
        if let box = box(for: place) {
            box.takeBack(reply)
            return
        }
        var record = record(for: place)
        record.box = Self.merge(reply, into: record.box)
        write(record, for: place)
    }

    /// `reply` ahead of `box`: its attachments first, its text after
    /// whatever `box` already says. An attachment already there isn't
    /// added twice.
    static func merge(_ reply: UnsentReply, into box: UnsentReply) -> UnsentReply {
        let known = Set(box.attachments.map(\.id))
        let attachments = reply.attachments.filter { !known.contains($0.id) } + box.attachments
        let typed = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let back = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if back.isEmpty || typed == back { text = box.text }
        else if typed.isEmpty { text = reply.text }
        else { text = typed + "\n\n" + back }
        return UnsentReply(text: text, attachments: attachments)
    }

    // MARK: Housekeeping

    /// Sign-out: every saved box and every staged file goes.
    public func wipeAll() {
        epoch &+= 1
        cache = [:]
        boxes = [:]
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: file)
        }
        StagedAttachment.removeAllStagedCopies()
    }

    /// Deletes staged files no saved box or send refers to — copies left
    /// by a crash between staging and saving. Call at launch, before any
    /// reply box exists.
    public func sweepOrphans() {
        let fm = FileManager.default
        // Nothing is deleted unless every saved box could be read: a box
        // that can't be (protected data before the first unlock, a read
        // error) may name any of the files.
        guard let saved = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        var kept = Set<String>()
        for file in saved where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(SavedRecord.self, from: data) else { return }
            for entry in record.box.attachments + record.sending.values.flatMap(\.attachments) {
                kept.insert(String(entry.path.split(separator: "/").first ?? ""))
            }
        }
        let staging = StagedAttachment.stagingDirectory
        for entry in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        where !kept.contains(entry.lastPathComponent) {
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: Disk

    private func record(for place: Place) -> Record {
        if let cached = cache[place] { return cached }
        var record = load(place)
        // Sends this process never started: the app stopped before they
        // were queued. They go back in the box.
        if !record.sending.isEmpty {
            for (_, reply) in record.sending.sorted(by: { $0.key < $1.key }) {
                record.box = Self.merge(reply, into: record.box)
            }
            record.sending = [:]
            write(record, for: place)
        }
        cache[place] = record
        return record
    }

    private func url(for place: Place) -> URL {
        directory.appendingPathComponent(place.fileName)
    }

    private func load(_ place: Place) -> Record {
        guard let data = try? Data(contentsOf: url(for: place)),
              let saved = try? JSONDecoder().decode(SavedRecord.self, from: data) else { return Record() }
        // A send whose files have all gone was queued (the files are
        // deleted once it is) just before the app stopped: not put back.
        let sending = saved.sending.compactMapValues { send -> UnsentReply? in
            let reply = send.reply
            return !send.attachments.isEmpty && reply.attachments.isEmpty ? nil : reply
        }
        return Record(box: saved.box.reply, sending: sending)
    }

    private func write(_ record: Record, for place: Place) {
        cache[place] = record
        let file = url(for: place)
        if record.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let saved = SavedRecord(box: SavedReply(record.box), sending: record.sending.mapValues(SavedReply.init))
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private struct SavedRecord: Codable {
        var box: SavedReply
        var sending: [String: SavedReply]
    }

    private struct SavedReply: Codable {
        var text: String
        var attachments: [SavedAttachment]

        init(_ reply: UnsentReply) {
            text = reply.text
            attachments = reply.attachments.map(SavedAttachment.init)
        }

        /// The reply, without any attachment whose file has gone.
        var reply: UnsentReply {
            UnsentReply(text: text, attachments: attachments.compactMap(\.attachment))
        }
    }

    private struct SavedAttachment: Codable {
        var id: UUID
        var path: String
        var filename: String
        var mimeType: String
        var sizeBytes: Int
        var batchID: String?
        var batchIndex: Int?
        var batchTotal: Int?

        init(_ a: StagedAttachment) {
            id = a.id; path = a.stagedPath; filename = a.filename
            mimeType = a.mimeType; sizeBytes = a.sizeBytes
            batchID = a.batchTag?.id; batchIndex = a.batchTag?.index; batchTotal = a.batchTag?.total
        }

        var attachment: StagedAttachment? {
            let url = StagedAttachment.stagingDirectory.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            var tag: AttachmentBatchTag?
            if let batchID, let batchIndex, let batchTotal {
                tag = AttachmentBatchTag(id: batchID, index: batchIndex, total: batchTotal)
            }
            return StagedAttachment(id: id, url: url, filename: filename, mimeType: mimeType,
                                    sizeBytes: sizeBytes, batchTag: tag)
        }
    }
}
