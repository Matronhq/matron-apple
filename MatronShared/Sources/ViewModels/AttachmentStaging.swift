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
    /// Surfaces a failure that happened before `attachFiles` could run (an
    /// unreadable paste, a provider that delivered nothing).
    func reportAttachmentError(_ message: String)
}

extension ComposerViewModel: AttachmentStaging {}
