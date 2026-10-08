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
/// code, and leave with the reply on Send (images posted
/// on their own the moment they arrived, and couldn't be pasted at all).
@MainActor
final class ItemReplyComposerTests: XCTestCase {
    /// Records what reached the tray instead of copying anything.
    private final class FakeStager: AttachmentStaging {
        /// Files the caller keeps (a Finder file, a picked original).
        var attached: [URL] = []
        /// Temp files the caller wrote and handed over.
        var temporaries: [URL] = []
        var errors: [String] = []
        func attachFiles(_ urls: [URL]) async { attached += urls }
        func attachTemporaryFiles(_ urls: [URL]) async { temporaries += urls }
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

    /// Review, PR #274: an item opened over a chat is pushed while the chat
    /// composer's field is still in the window. The item field's paste
    /// install must not take the chat field's delegate — after popping
    /// back, chat's image paste would otherwise be dead (the delegate is
    /// weak, and the item's coordinator is gone).
    func test_openingAnItemOverAChat_leavesTheChatFieldsPasteAlone() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        let chat = UIHostingController(rootView: TextField("Message…", text: .constant(""), axis: .vertical)
            .background(ComposerPasteSupport(viewModel: FakeStager())))
        window.rootViewController = chat
        window.isHidden = false
        window.layoutIfNeeded()
        var chatField: UITextView?
        for _ in 0..<50 {
            chatField = firstTextView(in: chat.view)
            if chatField?.pasteDelegate != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let field = try XCTUnwrap(chatField)
        let chatCoordinator = try XCTUnwrap(field.pasteDelegate as? ComposerPasteSupport.Coordinator)

        // The push: the item's composer mounts in the same window, above the chat.
        var item: UIHostingController<AnyView>? = UIHostingController(rootView: AnyView(
            ItemCommentComposer(draft: .constant(""), isBusy: false, onSubmit: {}, onAttach: {}, onVoiceNote: {})
                .environment(\.itemCommentField, ItemDetailHost.replyField(stagingInto: FakeStager()))))
        item!.view.frame = CGRect(x: 0, y: 200, width: 390, height: 200)
        chat.view.addSubview(item!.view)
        item!.view.layoutIfNeeded()
        var itemField: UITextView?
        for _ in 0..<50 {
            itemField = firstTextView(in: item!.view)
            if itemField?.pasteDelegate != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(field.pasteDelegate === chatCoordinator, "the chat field keeps its own delegate during the push")
        XCTAssertTrue(itemField?.pasteDelegate is ComposerPasteSupport.Coordinator, "the item field gets its own")
        XCTAssertFalse(itemField?.pasteDelegate === chatCoordinator)

        // The pop.
        item!.view.removeFromSuperview()
        item = nil
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(field.pasteDelegate === chatCoordinator, "chat image paste still works after popping back")
        window.isHidden = true
    }

    /// A picked photo goes to the tray (the chat composer's photo path), not
    /// out as its own comment.
    func test_pickedPhoto_isStagedInTheTray() async throws {
        let stager = FakeStager()
        let tmp = ComposerView.photoTempURL(ext: "heic")
        await ComposerView.stagePhotoData(Data([1, 2, 3]), to: tmp, viewModel: stager)
        XCTAssertEqual(stager.temporaries, [tmp], "the photo's temp file is handed over")
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
        await ItemDetailHost.stagePicked([source], into: stager)
        XCTAssertEqual(stager.temporaries.count, 1)
        XCTAssertEqual(stager.temporaries.first?.lastPathComponent.hasSuffix(source.lastPathComponent), true)
        XCTAssertEqual(try stager.temporaries.first.map { try Data(contentsOf: $0) }, Data("notes".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the user's original is never handed over")
        XCTAssertEqual(stager.errors, [])
    }

    /// Review, PR #274: an oversized pick is refused inside its security
    /// scope before any read — no temp copy, nothing staged.
    func test_oversizedPick_isRefusedBeforeItIsRead() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("huge-\(UUID()).mov")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: source) }
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(ItemDetailViewModel.maxAttachmentBytes + 1))
        try handle.close()
        let stager = FakeStager()
        await ItemDetailHost.stagePicked([source], into: stager)
        XCTAssertEqual(stager.temporaries, [])
        XCTAssertEqual(stager.attached, [])
        XCTAssertEqual(stager.errors, [ItemDetailViewModel.oversizeMessage(filename: source.lastPathComponent)])
    }
}
