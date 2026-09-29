import XCTest
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MatronDesignSystem
import MatronViewModels
@testable import Matron

/// A tracker item's reply composer on iOS takes attachments the way the chat
/// composer does: a pasted photo, a picked photo or file, and an iPad drop
/// all land in the reply's tray through the chat composer's own staging
/// code, and leave with the reply on Send (Dan, 2026-09-29: images posted
/// on their own the moment they arrived, and couldn't be pasted at all).
@MainActor
final class ItemReplyComposerTests: XCTestCase {
    /// Records what reached the tray instead of copying anything.
    private final class FakeStager: AttachmentStaging {
        var attached: [URL] = []
        var errors: [String] = []
        func attachFiles(_ urls: [URL]) async { attached += urls }
        func reportAttachmentError(_ message: String) { errors.append(message) }
    }

    private func firstTextView(in view: UIView) -> UITextView? {
        if let found = view as? UITextView { return found }
        for sub in view.subviews {
            if let found = firstTextView(in: sub) { return found }
        }
        return nil
    }

    /// The field the host installs carries the chat composer's paste
    /// support: its backing text view gets the paste delegate and the
    /// rich-text switch that makes UIKit OFFER Paste for an image.
    func test_replyField_installsTheChatComposersPasteSupport() async throws {
        let composer = ItemCommentComposer(draft: .constant(""), isBusy: false,
                                           onSubmit: {}, onAttach: {}, onVoiceNote: {})
            .environment(\.itemCommentField, ItemDetailHost.replyField(stagingInto: FakeStager()))
        let hosting = UIHostingController(rootView: composer)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        window.rootViewController = hosting
        window.isHidden = false
        window.layoutIfNeeded()
        hosting.view.layoutIfNeeded()
        // Nothing re-renders the composer here (no typing), so this only
        // passes if the install happens on its own after mounting — the
        // state a user is in when they paste before typing.
        var textView: UITextView?
        for _ in 0..<50 {
            textView = firstTextView(in: hosting.view)
            if textView?.pasteDelegate is ComposerPasteSupport.Coordinator { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let field = try XCTUnwrap(textView, "the reply field is backed by a UIKit text view")
        XCTAssertTrue(field.pasteDelegate is ComposerPasteSupport.Coordinator)
        XCTAssertTrue(field.allowsEditingTextAttributes, "without this UIKit offers no Paste for an image")
        let accepted = field.pasteConfiguration?.acceptableTypeIdentifiers ?? []
        XCTAssertTrue(accepted.contains(UTType.image.identifier))
        window.isHidden = true
    }

    /// A picked photo goes to the tray (the chat composer's photo path), not
    /// out as its own comment.
    func test_pickedPhoto_isStagedInTheTray() async throws {
        let stager = FakeStager()
        let tmp = ComposerView.photoTempURL(ext: "heic")
        await ComposerView.stagePhotoData(Data([1, 2, 3]), to: tmp, viewModel: stager)
        XCTAssertEqual(stager.attached, [tmp])
        XCTAssertEqual(try Data(contentsOf: tmp), Data([1, 2, 3]))
        try? FileManager.default.removeItem(at: tmp)
    }

    /// A picked or dropped file is read (inside its security scope) into a
    /// temp copy and staged — the chat composer's file path.
    func test_pickedOrDroppedFile_isStagedInTheTray() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID()).txt")
        try Data("notes".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let stager = FakeStager()
        await ComposerView.stageAndAttach([source], into: stager)
        XCTAssertEqual(stager.attached.count, 1)
        XCTAssertEqual(stager.attached.first?.lastPathComponent.hasSuffix(source.lastPathComponent), true)
        XCTAssertEqual(try stager.attached.first.map { try Data(contentsOf: $0) }, Data("notes".utf8))
        XCTAssertEqual(stager.errors, [])
    }
}
