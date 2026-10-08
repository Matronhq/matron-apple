import Foundation
import MatronJournal
import MatronModels

/// Voice mode's sends, on the paths the app already uses for the same
/// things by hand:
///
/// - upload: `POST /media`, as `JournalTimelineService.sendMedia` and
///   `ItemDetailViewModel.submitAttachments` do;
/// - a voice note to a conversation: the `file` media send
///   `ComposerViewModel.sendVoiceNote` ends in (`voice-note.m4a`,
///   `audio/mp4`);
/// - a voice note or an action on an item: the item outbox
///   (`ItemsSync.enqueueComment`), which is what
///   `ItemDetailViewModel.sendVoiceNote` and `chooseAction` use, so both
///   survive being offline;
/// - a prompt answer: the `prompt_reply` op.
public struct JournalVoiceSender: VoiceSending {
    public static let filename = "voice-note.m4a"
    public static let mimeType = "audio/mp4"

    let uploadMedia: @Sendable (Data, String) async throws -> String
    let mediaTranscript: @Sendable (String, Int) async throws -> String?
    let sendOp: @Sendable (ClientOp) async throws -> Void
    let enqueueComment: @Sendable (_ itemID: String, _ body: String, _ attachments: [TrackerAttachment], _ action: String?) async -> Void

    init(uploadMedia: @escaping @Sendable (Data, String) async throws -> String,
         mediaTranscript: @escaping @Sendable (String, Int) async throws -> String?,
         sendOp: @escaping @Sendable (ClientOp) async throws -> Void,
         enqueueComment: @escaping @Sendable (String, String, [TrackerAttachment], String?) async -> Void) {
        self.uploadMedia = uploadMedia
        self.mediaTranscript = mediaTranscript
        self.sendOp = sendOp
        self.enqueueComment = enqueueComment
    }

    public init(api: JournalAPI, engine: JournalSyncEngine, items: ItemsSync) {
        self.init(
            uploadMedia: { data, type in try await api.uploadMedia(data, contentType: type) },
            mediaTranscript: { ref, wait in try await api.mediaTranscript(blobRef: ref, waitSeconds: wait) },
            sendOp: { op in try await engine.sendOp(op) },
            enqueueComment: { itemID, body, attachments, action in
                await items.enqueueComment(itemID: itemID, localID: UUID().uuidString, body: body,
                                           attachments: attachments, action: action)
            })
    }

    public func upload(_ audio: Data) async throws -> String {
        try await uploadMedia(audio, Self.mimeType)
    }

    public func transcript(blobRef: String, waitSeconds: Int) async -> String? {
        (try? await mediaTranscript(blobRef, waitSeconds)) ?? nil
    }

    public func sendVoiceNote(blobRef: String, size: Int, to target: VoiceModeEngine.SendTarget) async throws {
        switch target {
        case .conversation(let convoID):
            try await sendOp(.sendMedia(convoID: convoID, type: "file", blobRef: blobRef, name: Self.filename,
                                        contentType: Self.mimeType, size: size, caption: nil, batch: nil,
                                        localID: UUID().uuidString))
        case .item(let itemID):
            let note = TrackerAttachment(blobRef: blobRef, mime: Self.mimeType, name: Self.filename, size: Int64(size))
            await enqueueComment(itemID, "", [note], nil)
        }
    }

    public func sendItemAction(itemID: String, label: String) async {
        await enqueueComment(itemID, label, [], label)
    }

    public func sendPromptReply(convoID: String, seq: Int64, choice: String?, text: String?) async throws {
        try await sendOp(.promptReply(convoID: convoID, targetSeq: seq, choice: choice, text: text))
    }
}
