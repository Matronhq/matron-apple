import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MatronViewModels

/// Teaches the composer's text field to accept pasted photos and files.
///
/// SwiftUI's `TextField` exposes no paste hook, and UIKit only offers Paste in
/// the edit menu for content the field's `pasteConfiguration` accepts — with a
/// photo on the pasteboard a stock text field doesn't advertise Paste at all.
/// So we reach the backing text view (the same walk-the-native-hierarchy idiom
/// as `captureNativeScrollView`), widen its paste configuration, and claim the
/// non-text items via `UITextPasteDelegate`.
///
/// Attach as a `.background` of the `TextField`. If the backing view can't be
/// found the composer degrades to today's behaviour — text pastes, photos
/// don't — rather than breaking.
struct ComposerPasteSupport: UIViewRepresentable {
    let viewModel: ComposerViewModel

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {
        uiView.coordinator = context.coordinator
        uiView.installIfNeeded()
    }

    /// Zero-size helper view whose only job is to be a sibling of the text
    /// field so we can find it.
    final class InstallerView: UIView {
        var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            installIfNeeded()
        }

        /// `updateUIView` runs on every keystroke (the composer body reads
        /// `viewModel.input`), so the hierarchy search is gated on the
        /// coordinator having lost its target — otherwise every character
        /// typed would walk the view tree.
        func installIfNeeded() {
            guard window != nil, let coordinator, coordinator.needsInstall,
                  let target = ComposerPasteSupport.pasteTarget(near: self) else { return }
            coordinator.install(on: target)
        }
    }

    /// Finds the text view backing the sibling SwiftUI `TextField`: walk up
    /// the ancestors, searching each one's subtree, so the nearest text view —
    /// this composer's own — is the one found.
    static func pasteTarget(near view: UIView) -> (UIView & UITextPasteConfigurationSupporting)? {
        var ancestor = view.superview
        while let current = ancestor {
            if let target = firstPasteTarget(in: current) { return target }
            ancestor = current.superview
        }
        return nil
    }

    private static func firstPasteTarget(
        in view: UIView
    ) -> (UIView & UITextPasteConfigurationSupporting)? {
        if let target = view as? (UIView & UITextPasteConfigurationSupporting) { return target }
        for subview in view.subviews {
            if let target = firstPasteTarget(in: subview) { return target }
        }
        return nil
    }

    /// Owns the paste delegation. Held by SwiftUI as the representable's
    /// coordinator, which matters: `pasteDelegate` is a weak reference.
    @MainActor
    final class Coordinator: NSObject, UITextPasteDelegate {
        private let viewModel: ComposerViewModel
        private weak var target: (UIView & UITextPasteConfigurationSupporting)?

        init(viewModel: ComposerViewModel) {
            self.viewModel = viewModel
            super.init()
        }

        /// True until we're installed on a text view that's still in a window.
        /// SwiftUI can rebuild the field underneath us, and a delegate left on
        /// a dead view accepts nothing — the same trap the horizontal-overflow
        /// lock hit in PR #53.
        var needsInstall: Bool {
            guard let target else { return true }
            return target.window == nil
        }

        func install(on target: UIView & UITextPasteConfigurationSupporting) {
            guard self.target !== target else { return }
            self.target = target
            // Add to the field's own configuration rather than replacing it:
            // a fresh `UIPasteConfiguration` would drop the text types the
            // field set up for itself, breaking ordinary text paste.
            let configuration = target.pasteConfiguration ?? UIPasteConfiguration()
            configuration.addAcceptableTypeIdentifiers([
                UTType.image.identifier,
                UTType.fileURL.identifier,
                UTType.data.identifier,
            ])
            target.pasteConfiguration = configuration
            target.pasteDelegate = self
        }

        func textPasteConfigurationSupporting(
            _ textPasteConfigurationSupporting: UITextPasteConfigurationSupporting,
            transform item: UITextPasteItem
        ) {
            let provider = item.itemProvider
            guard PastedAttachment.classify(provider) != .text else {
                item.setDefaultResult()
                return
            }
            // Nothing lands in the text field: a pasted attachment uploads and
            // sends immediately, exactly like a PhotosPicker selection.
            item.setNoResult()
            Task { @MainActor in
                do {
                    let url = try await PastedAttachment.stage(provider)
                    await viewModel.attachFiles([url])
                } catch {
                    viewModel.reportAttachmentError(error.localizedDescription)
                }
            }
        }
    }
}
