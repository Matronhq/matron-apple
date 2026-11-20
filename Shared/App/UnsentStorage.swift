import Foundation
import MatronModels
import MatronStorage
import MatronViewModels

/// Where replies that haven't been sent are kept: the staged files, the
/// saved reply boxes (`UnsentReplyStore`) and the voice notes waiting for
/// Retry. In Application Support, not tmp, which the system may empty
/// while the app isn't running. Sign-out wipes all three.
enum UnsentStorage {
    static var root: URL {
        #if os(macOS)
        StoragePaths.appSupport
        #else
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
    }

    static var replies: URL { root.appendingPathComponent("unsent-replies", isDirectory: true) }
    static var stagedAttachments: URL { root.appendingPathComponent("staged-attachments", isDirectory: true) }
    static var failedVoiceNotes: URL { root.appendingPathComponent("failed-voice-notes", isDirectory: true) }

    /// Points staging at Application Support, makes the store, and clears
    /// staged files nothing refers to. Called once, from `AppDependencies.init`.
    @MainActor static func makeStore() -> UnsentReplyStore {
        StagedAttachment.useStagingDirectory(stagedAttachments)
        let store = UnsentReplyStore(directory: replies)
        store.sweepOrphans()
        return store
    }

    /// Deletes the voice notes kept for Retry. Sign-out, on every path:
    /// the session's own `reset()` only runs where the shell is on screen.
    static func removeFailedVoiceNotes() {
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: failedVoiceNotes, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: file)
        }
    }

    /// The app's one voice-note session, keeping failed notes for Retry
    /// across launches once signed in (`restoreSavedFailures`). Cheap: it
    /// reads nothing until then.
    @MainActor static func makeVoiceNoteSession() -> VoiceNoteSession {
        VoiceNoteSession(recorder: VoiceRecorder(), failedNotesDirectory: failedVoiceNotes)
    }
}

@MainActor
extension AppDependencies {
    /// How `VoiceNoteSession` sends a failed note again after a relaunch,
    /// when the closure that started it is gone: to the reply box showing
    /// its item or conversation now, or to one made for the purpose. A
    /// note that fails again goes back into that place's saved reply.
    func voiceNoteDeliverer(for session: UserSession) -> (VoiceNoteSession.Target) -> VoiceNoteSession.Deliver? {
        { [weak self] target in
            guard let self else { return nil }
            switch target.kind {
            case .item(let itemID):
                let vm = (self.unsentReplies.box(for: .item(itemID)) as? ItemDetailViewModel)
                    ?? self.makeItemDetailViewModel(for: session, itemID: itemID, isStandIn: true)
                return { url, _ in await vm.sendVoiceNote(url: url) }
            case .conversation(let roomID):
                let composer = (self.unsentReplies.box(for: .conversation(roomID)) as? ComposerViewModel)
                    ?? ComposerViewModel(roomID: roomID, timeline: self.timelineService(for: session, roomID: roomID),
                                         commands: [], unsentReplies: self.unsentReplies,
                                         // Sends the note alone; a failure goes back to
                                         // the chat's saved message or the composer on screen.
                                         isStandIn: true)
                return { url, duration in await composer.sendVoiceNote(url: url, duration: duration) }
            }
        }
    }
}
