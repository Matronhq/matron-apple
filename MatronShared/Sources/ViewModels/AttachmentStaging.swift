import Foundation

/// Anything that holds attachments in a tray until the user sends — the chat
/// composer (`ComposerViewModel`) and a tracker item's reply composer
/// (`ItemDetailViewModel`).
///
/// The platform plumbing that turns a paste or a drop into files — iOS
/// `ComposerPasteSupport`, Mac `PasteboardAttachmentBridge` and
/// `ComposerDropDelegate` — speaks to this rather than to either view model,
/// so both composers take a pasted screenshot or a dropped file through the
/// SAME probe-verified code instead of each growing its own copy.
@MainActor
public protocol AttachmentStaging: AnyObject {
    /// Copies each file into the staging area and adds it to the tray. The
    /// URLs must be readable for the duration of the call; the staged copy is
    /// what gets sent later.
    func attachFiles(_ urls: [URL]) async
    /// Like `attachFiles`, for temporary files the app itself wrote (a
    /// paste, a picked photo, a file read out of its security scope): the
    /// stager takes ownership and the files are gone from their original
    /// location afterwards, so no temp copy is left behind once the bytes
    /// are staged.
    func attachTemporaryFiles(_ urls: [URL]) async
    /// Surfaces a failure that happened before `attachFiles` could run (an
    /// unreadable paste, a provider that delivered nothing).
    func reportAttachmentError(_ message: String)
}

extension ComposerViewModel: AttachmentStaging {
    /// Chat stages by copying (`attachFiles`); the temp source is ours, so
    /// it is deleted once the copy exists. Before this, every pasted or
    /// picked file stayed behind in tmp as a second copy.
    public func attachTemporaryFiles(_ urls: [URL]) async {
        await attachFiles(urls)
        for url in urls { PastedAttachment.removeStagingFile(url) }
    }
}
