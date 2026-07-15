import XCTest
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MatronChat
import MatronViewModels
@testable import Matron

/// Pins the two assumptions `ComposerPasteSupport` rests on. Both are about
/// UIKit's behaviour rather than our own logic, which is exactly why they're
/// worth a test: if a future SDK changes either, pasted photos would silently
/// stop attaching with nothing else failing.
final class ComposerPasteSupportTests: XCTestCase {
    /// Assumption 1: SwiftUI's `TextField` is backed by a UIKit text view that
    /// accepts a paste delegate, and a sibling helper view can find it by
    /// walking up-then-down. The whole approach depends on this — without a
    /// reachable backing view there is nowhere to hang paste support.
    @MainActor
    func test_pasteTarget_findsTheTextViewBackingASwiftUITextField() {
        let hosting = UIHostingController(
            rootView: TextField("Message…", text: .constant(""), axis: .vertical)
                .padding()
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        window.rootViewController = hosting
        window.isHidden = false
        window.layoutIfNeeded()
        hosting.view.layoutIfNeeded()

        // Stands in for `InstallerView`: a sibling inside the field's subtree.
        let probe = UIView()
        hosting.view.addSubview(probe)

        XCTAssertNotNil(
            ComposerPasteSupport.pasteTarget(near: probe),
            "SwiftUI's TextField must be backed by a UIKit text view we can install a paste delegate on"
        )
    }

    /// The walk finds the nearest text view rather than any text view: a
    /// probe inside one composer must not reach across to a sibling's field.
    @MainActor
    func test_pasteTarget_prefersTheNearestTextView() {
        let root = UIView()
        let near = UIView()
        let far = UIView()
        root.addSubview(near)
        root.addSubview(far)

        let nearField = UITextView()
        near.addSubview(nearField)
        far.addSubview(UITextView())

        let probe = UIView()
        near.addSubview(probe)

        XCTAssertTrue(ComposerPasteSupport.pasteTarget(near: probe) === nearField)
    }

    /// Assumption 2: widening the field's paste configuration adds image and
    /// file support WITHOUT dropping the text types the field registered for
    /// itself — replacing the configuration outright would break ordinary
    /// text paste, which is a far worse bug than the one being fixed.
    @MainActor
    func test_install_addsAttachmentTypes_withoutDroppingTheFieldsOwn() {
        let coordinator = ComposerPasteSupport.Coordinator(viewModel: makeViewModel())
        let textView = UITextView()
        let inherited = textView.pasteConfiguration?.acceptableTypeIdentifiers ?? []

        coordinator.install(on: textView)

        let accepted = textView.pasteConfiguration?.acceptableTypeIdentifiers ?? []
        XCTAssertTrue(accepted.contains(UTType.image.identifier))
        XCTAssertTrue(accepted.contains(UTType.fileURL.identifier))
        for identifier in inherited {
            XCTAssertTrue(accepted.contains(identifier), "dropped inherited type \(identifier)")
        }
        XCTAssertTrue(textView.pasteDelegate === coordinator)
    }

    /// `updateUIView` runs on every keystroke, so an installed-and-live target
    /// must not re-trigger the hierarchy walk.
    @MainActor
    func test_needsInstall_isFalseWhileTheTargetIsLive() {
        let coordinator = ComposerPasteSupport.Coordinator(viewModel: makeViewModel())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let textView = UITextView()
        window.addSubview(textView)

        XCTAssertTrue(coordinator.needsInstall)
        coordinator.install(on: textView)
        XCTAssertFalse(coordinator.needsInstall)

        // A field SwiftUI has torn out from under us clamps nothing — the
        // coordinator has to notice and reinstall on the replacement.
        textView.removeFromSuperview()
        XCTAssertTrue(coordinator.needsInstall)
    }

    @MainActor
    private func makeViewModel() -> ComposerViewModel {
        ComposerViewModel(roomID: "!test:s", timeline: FakeTimelineForComposer(), commands: [])
    }
}
