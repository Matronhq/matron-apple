import XCTest
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MatronChat
import MatronViewModels
@testable import Matron

/// End-to-end paste coverage against a REAL hosted SwiftUI `TextField`.
///
/// These exist because the original paste tests all passed while the feature
/// did nothing: they proved the finder found a view and that `install` widened
/// the paste configuration, but never that UIKit would *offer* Paste — which is
/// the only thing the user experiences. Dan copied a photo, held the composer,
/// and got no Paste option (2026-07-16). Every assertion below is on observable
/// behaviour: does the menu offer Paste, and does pasting actually attach.
final class PasteMenuDiagnosticTests: XCTestCase {
    private var window: UIWindow!

    override func tearDown() {
        // NOTE: deliberately NOT clearing `UIPasteboard.general` here.
        // Clearing it and immediately re-populating it in the next test
        // invalidates the new item's data promise — the provider then fails
        // with "Cannot load representation of type public.png" and the paste
        // test fails while passing in isolation. That churn is a test-harness
        // artifact of hammering the shared pasteboard in one process; a user
        // copies once and pastes once. Each test sets what it needs instead.
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        super.tearDown()
    }

    /// THE regression test for Dan's report. `pasteConfiguration` does not gate
    /// the edit menu — measured, with the config widened and the delegate
    /// installed, this was still false until the field went rich-text.
    @MainActor
    func test_pasteIsOffered_forAnImage_theBugDanHit() {
        let harness = makeHarness()
        UIPasteboard.general.image = redPixel()

        XCTAssertTrue(
            harness.target.canPerformAction(#selector(UIResponder.paste(_:)), withSender: nil),
            "no Paste item for an image-bearing pasteboard — this is exactly the bug"
        )
    }

    /// The half that already worked: a file URL satisfies UIKit's gate via
    /// `hasURLs`, which is why pasting a file behaved while photos didn't.
    @MainActor
    func test_pasteIsOffered_forAFileURL() {
        let harness = makeHarness()
        UIPasteboard.general.setValue(
            URL(fileURLWithPath: "/tmp/report.pdf"), forPasteboardType: UTType.fileURL.identifier
        )

        XCTAssertTrue(
            harness.target.canPerformAction(#selector(UIResponder.paste(_:)), withSender: nil)
        )
    }

    /// Rich-text mode must not cost us ordinary text paste.
    @MainActor
    func test_pasteIsStillOffered_forPlainText() {
        let harness = makeHarness()
        UIPasteboard.general.string = "hello"

        XCTAssertTrue(
            harness.target.canPerformAction(#selector(UIResponder.paste(_:)), withSender: nil)
        )
    }

    /// Drives a real paste and checks the outcome the user cares about: the
    /// photo is sent as an attachment, and no text is dumped into the field.
    @MainActor
    func test_pastingAnImage_attachesIt_andLeavesTheFieldEmpty() async throws {
        let harness = makeHarness()
        UIPasteboard.general.image = redPixel()
        // Let pasteboardd actually materialise the item before pasting it.
        // Writing the pasteboard is cross-process and asynchronous; pasting
        // immediately after an earlier test wrote it leaves the new item's
        // data promise unfulfilled ("Cannot load representation of type
        // public.png"). A user copies in Photos and pastes seconds later.
        try? await Task.sleep(nanoseconds: 500_000_000)

        harness.target.paste(nil)

        try await waitUntil("an attachment is sent") { !harness.fake.sentAttachments.isEmpty }
        let sent = try XCTUnwrap(harness.fake.sentAttachments.first)
        XCTAssertTrue(sent.mimeType.hasPrefix("image/"), "sent as \(sent.mimeType)")
        XCTAssertEqual(
            (harness.target as? UITextView)?.text, "",
            "a pasted photo must not also dump text into the composer"
        )
    }

    /// Text pasted from a web page or document must arrive plain — rich-text
    /// mode would otherwise carry the source's font and colour into the
    /// composer, a regression to a much more common action than image paste.
    @MainActor
    func test_pastingStyledText_arrivesPlain() async throws {
        let harness = makeHarness()
        let styled = NSAttributedString(
            string: "styled",
            attributes: [.font: UIFont.systemFont(ofSize: 42), .foregroundColor: UIColor.red]
        )
        let rtf = try styled.data(
            from: NSRange(location: 0, length: styled.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        UIPasteboard.general.setData(rtf, forPasteboardType: UTType.rtf.identifier)

        harness.target.paste(nil)

        // `paste(_:)` runs the item through the provider asynchronously — an
        // immediate assertion here reads the field before the text lands.
        let textView = try XCTUnwrap(harness.target as? UITextView)
        try await waitUntil("the text is inserted") { !(textView.text ?? "").isEmpty }
        XCTAssertEqual(textView.text, "styled")
        guard textView.attributedText.length > 0 else { return }
        let font = textView.attributedText.attribute(
            .font, at: 0, effectiveRange: nil
        ) as? UIFont
        XCTAssertNotEqual(font?.pointSize, 42, "pasted text kept the source's font size")
    }

    // MARK: - Harness

    private struct Harness {
        let target: UIView & UITextPasteConfigurationSupporting
        let coordinator: ComposerPasteSupport.Coordinator
        let fake: FakeTimelineForComposer
        let viewModel: ComposerViewModel
    }

    /// Hosts a real SwiftUI TextField, installs paste support the way
    /// `ComposerView` does, and focuses the field — the same conditions as a
    /// user holding down the composer.
    @MainActor
    private func makeHarness(
        file: StaticString = #filePath, line: UInt = #line
    ) -> Harness {
        let hosting = UIHostingController(
            rootView: TextField("Message…", text: .constant(""), axis: .vertical).padding()
        )
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        hosting.view.layoutIfNeeded()

        let probe = UIView()
        hosting.view.addSubview(probe)
        guard let target = ComposerPasteSupport.pasteTarget(near: probe) else {
            XCTFail("no paste target found", file: file, line: line)
            fatalError("unreachable")
        }

        let fake = FakeTimelineForComposer()
        let viewModel = ComposerViewModel(roomID: "!test:s", timeline: fake, commands: [])
        let coordinator = ComposerPasteSupport.Coordinator(viewModel: viewModel)
        coordinator.install(on: target)
        // Assert rather than assume: an unfocused field silently swallows
        // `paste(_:)`, which would look exactly like the bug under test.
        XCTAssertTrue(
            target.becomeFirstResponder(), "field never focused", file: file, line: line
        )
        return Harness(target: target, coordinator: coordinator, fake: fake, viewModel: viewModel)
    }

    private func redPixel() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    /// Polls rather than sleeping: the paste pipeline hops through the item
    /// provider and an upload Task, and a fixed sleep would be either flaky or
    /// slow. Mirrors the repo's condition-based waiting elsewhere.
    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for: \(what)", file: file, line: line)
    }
}
