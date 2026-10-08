import Foundation
import MatronJournal
import MatronModels

/// One share: the files and the message, bound for one conversation.
public struct ShareRequest: Equatable, Sendable {
    public let convoID: String
    public let message: String
    public let files: [SharedFile]

    public init(convoID: String, message: String, files: [SharedFile]) {
        self.convoID = convoID
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.files = files
    }

    public var isEmpty: Bool { files.isEmpty && message.isEmpty }
}

/// Where a send has got to, for the progress bar.
public struct ShareProgress: Equatable, Sendable {
    /// The file being uploaded, 1-based, or nil once every upload is done
    /// and the message is being posted.
    public let fileIndex: Int?
    public let fileCount: Int
    public let filename: String?
    /// 0…1 across the whole send.
    public let fraction: Double

    public init(fileIndex: Int?, fileCount: Int, filename: String?, fraction: Double) {
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
}

/// Sends a share: uploads each file, then posts them with the message as
/// one turn.
///
/// Uploads are kept across a retry. A send that failed after two of three
/// files had uploaded does not upload those two again, and every operation
/// keeps the identifier it was first given, so the server treats a repeat
/// of something that did arrive as the same message rather than a second.
public actor ShareSender {
    private let transport: any ShareTransport
    private var uploaded: [UUID: String] = [:]
    private var localIDs: [String: String] = [:]
    private var batchID: String?

    public init(transport: any ShareTransport) {
        self.transport = transport
    }

    public func send(
        _ request: ShareRequest, progress: @escaping @Sendable (ShareProgress) -> Void
    ) async throws {
        guard !request.isEmpty else { return }
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
        progress(ShareProgress(fileIndex: nil, fileCount: files.count, filename: nil, fraction: 0.95))
        try await transport.deliver(operations(for: request))
        progress(ShareProgress(fileIndex: nil, fileCount: files.count, filename: nil, fraction: 1))
    }

    /// The journal operations for `request`, once its files are uploaded.
    ///
    /// The message rides as the first file's caption, and several files
    /// share a batch tag, so the agent receives the lot as one prompt: the
    /// same shape the composer sends. With no files the message is a plain
    /// text send.
    func operations(for request: ShareRequest) -> [ClientOp] {
        guard !request.files.isEmpty else {
            return [.send(convoID: request.convoID, body: request.message, localID: localID(for: "text"))]
        }
        let batch: String? = request.files.count > 1 ? (batchID ?? UUID().uuidString) : nil
        batchID = batch
        return request.files.enumerated().compactMap { index, file in
            guard let blobRef = uploaded[file.id] else { return nil }
            return .sendMedia(
                convoID: request.convoID, type: file.isImage ? "image" : "file", blobRef: blobRef,
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
