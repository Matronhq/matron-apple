import Foundation
import MatronJournal
import MatronModels

/// Where a share goes: a conversation that exists, or a new one started
/// for it on a box.
public enum ShareDestination: Equatable, Sendable {
    case conversation(String)
    case newConversation(boxID: Int64)
}

/// One share: the files and the message, bound for one destination.
public struct ShareRequest: Equatable, Sendable {
    public let destination: ShareDestination
    public let message: String
    public let files: [SharedFile]

    public init(convoID: String, message: String, files: [SharedFile]) {
        self.init(destination: .conversation(convoID), message: message, files: files)
    }

    public init(destination: ShareDestination, message: String, files: [SharedFile]) {
        self.destination = destination
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.files = files
    }

    public var isEmpty: Bool { files.isEmpty && message.isEmpty }
}

/// Where a send has got to, for the progress bar.
public struct ShareProgress: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case uploading
        /// Asking a box to start the new conversation.
        case starting
        /// The box was asleep and is being woken before it can start one.
        case waking
        case posting
    }

    public let step: Step
    /// The file being uploaded, 1-based, or nil once every upload is done
    /// and the message is being posted.
    public let fileIndex: Int?
    public let fileCount: Int
    public let filename: String?
    /// 0…1 across the whole send.
    public let fraction: Double

    public init(fileIndex: Int?, fileCount: Int, filename: String?, fraction: Double, step: Step? = nil) {
        self.step = step ?? (fileIndex == nil ? .posting : .uploading)
        self.fileIndex = fileIndex
        self.fileCount = fileCount
        self.filename = filename
        self.fraction = fraction
    }
}

public enum ShareSendError: LocalizedError, Equatable {
    case tooLarge(name: String)
    case signedOut
    case rejected(String)
    /// Everything was sent but the server never confirmed it.
    case unconfirmed
    case failed(String)
    /// The box was asked to start a conversation and never answered. It
    /// may have started one all the same.
    case startUnanswered

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let name):
            return "\(name) is too large to send."
        case .signedOut:
            return "This device is signed out. Open Matron and sign in again."
        case .rejected(let detail):
            return "The server refused the message: \(detail)"
        case .unconfirmed:
            return "Couldn't confirm the message arrived. Check the conversation in Matron before sending again."
        case .failed(let detail):
            return detail
        case .startUnanswered:
            return "The box didn't answer. A new conversation may still have started: check Matron, then send to it or to another conversation."
        }
    }
}

/// The network half of a share, behind a seam so the sequencing can be
/// tested without a server.
public protocol ShareTransport: Sendable {
    /// Uploads a file and returns the reference to send it under.
    func upload(_ file: SharedFile, progress: @escaping @Sendable (Double) -> Void) async throws -> String
    /// Posts the operations into the journal and returns once the server
    /// has taken them all.
    func deliver(_ ops: [ClientOp]) async throws
    /// Starts a new conversation on a box, with the box's own defaults, and
    /// returns its id. `waking` is called each time the box turns out to be
    /// asleep and is asked again.
    func startConversation(onBox boxID: Int64, waking: @escaping @Sendable () -> Void) async throws -> String
}

/// Sends a share: uploads each file, then posts them with the message as
/// one turn.
///
/// Uploads are kept across a retry. A send that failed after two of three
/// files had uploaded does not upload those two again. A retry of the very
/// same request also repeats each operation under the identifier it was
/// first given, so the server treats a repeat of something that did arrive
/// as the same message rather than a second. Once the user changes anything
/// (the message, the conversation, the files) it is a new message and gets
/// new identifiers: under the old ones the server would take it for the
/// first attempt and drop the change.
///
/// A new conversation is started only once every file is up, so a failed
/// upload leaves no empty conversation behind, and it is started once: a
/// retry, or a send after an edit, goes into the one already made.
public actor ShareSender {
    private let transport: any ShareTransport
    private var uploaded: [UUID: String] = [:]
    private var localIDs: [String: String] = [:]
    private var batchID: String?
    private var lastRequest: ShareRequest?
    private var started: [Int64: String] = [:]
    /// Boxes asked to start a conversation that never answered. One may
    /// have been started all the same, so they are not asked again.
    private var unanswered: Set<Int64> = []

    public init(transport: any ShareTransport) {
        self.transport = transport
    }

    public func send(
        _ request: ShareRequest, progress: @escaping @Sendable (ShareProgress) -> Void
    ) async throws {
        guard !request.isEmpty else { return }
        if request != lastRequest {
            localIDs = [:]
            batchID = nil
            lastRequest = request
        }
        let files = request.files
        let total = max(1, files.reduce(0) { $0 + $1.sizeBytes })
        var done = 0
        for (index, file) in files.enumerated() {
            let before = done
            let report: @Sendable (Double) -> Void = { fraction in
                // Uploads are 95% of the bar: the last step is the post.
                let bytes = Double(before) + fraction * Double(file.sizeBytes)
                progress(ShareProgress(fileIndex: index + 1, fileCount: files.count,
                                       filename: file.filename,
                                       fraction: 0.95 * min(1, bytes / Double(total))))
            }
            report(0)
            if uploaded[file.id] == nil {
                uploaded[file.id] = try await transport.upload(file, progress: report)
            }
            done += file.sizeBytes
            report(1)
        }
        let convoID: String
        switch request.destination {
        case .conversation(let id):
            convoID = id
        case .newConversation(let boxID):
            if let existing = started[boxID] {
                convoID = existing
            } else if unanswered.contains(boxID) {
                throw ShareSendError.startUnanswered
            } else {
                let count = files.count
                progress(ShareProgress(fileIndex: nil, fileCount: count, filename: nil,
                                       fraction: 0.95, step: .starting))
                do {
                    convoID = try await transport.startConversation(onBox: boxID) {
                        progress(ShareProgress(fileIndex: nil, fileCount: count, filename: nil,
                                               fraction: 0.95, step: .waking))
                    }
                } catch ShareSendError.startUnanswered {
                    unanswered.insert(boxID)
                    throw ShareSendError.startUnanswered
                }
                started[boxID] = convoID
            }
        }
        progress(ShareProgress(fileIndex: nil, fileCount: files.count, filename: nil, fraction: 0.95))
        try await transport.deliver(operations(for: request, in: convoID))
        progress(ShareProgress(fileIndex: nil, fileCount: files.count, filename: nil, fraction: 1))
    }

    /// The journal operations that put `request` into `convoID`, once its
    /// files are uploaded.
    ///
    /// The message rides as the first file's caption, and several files
    /// share a batch tag, so the agent receives the lot as one prompt: the
    /// same shape the composer sends. With no files the message is a plain
    /// text send.
    func operations(for request: ShareRequest, in convoID: String) -> [ClientOp] {
        guard !request.files.isEmpty else {
            return [.send(convoID: convoID, body: request.message, localID: localID(for: "text"))]
        }
        let batch: String? = request.files.count > 1 ? (batchID ?? UUID().uuidString) : nil
        batchID = batch
        return request.files.enumerated().compactMap { index, file in
            guard let blobRef = uploaded[file.id] else { return nil }
            return .sendMedia(
                convoID: convoID, type: file.isImage ? "image" : "file", blobRef: blobRef,
                name: file.filename, contentType: file.mimeType, size: file.sizeBytes,
                caption: index == 0 && !request.message.isEmpty ? request.message : nil,
                batch: batch.map { AttachmentBatchTag(id: $0, index: index + 1, total: request.files.count) },
                localID: localID(for: file.id.uuidString))
        }
    }

    private func localID(for key: String) -> String {
        if let existing = localIDs[key] { return existing }
        let id = UUID().uuidString
        localIDs[key] = id
        return id
    }
}
