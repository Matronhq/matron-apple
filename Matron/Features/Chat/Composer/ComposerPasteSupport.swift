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
            allowImagePasteMenu(on: target)
        }

        /// Makes UIKit *offer* Paste when the pasteboard holds an image.
        ///
        /// This is the load-bearing line, and it is not what you'd guess.
        /// `pasteConfiguration` has nothing to do with the edit menu: measured
        /// on a hosted `TextField`, with the configuration widened AND the
        /// delegate installed, `canPerformAction(paste:)` was still `false` for
        /// an image-bearing pasteboard — which is exactly the "no Paste option
        /// appears" Dan hit (2026-07-16). A `UITextView` gates the Paste item on
        /// `hasStrings || (allowsEditingTextAttributes && hasImages)`, so
        /// rich-text mode is the only switch that reveals it. Flipping it took
        /// the same measurement from `false` to `true`.
        ///
        /// File URLs never needed this (`hasURLs` already satisfies the gate),
        /// which is why pasting a file worked while pasting a photo did nothing.
        ///
        /// Rich-text mode alone would let pasted text keep the source's font and
        /// colour; `combineItemAttributedStrings` below strips that back to
        /// plain so the composer looks exactly as it did before.
        private func allowImagePasteMenu(on target: UIView & UITextPasteConfigurationSupporting) {
            (target as? UITextView)?.allowsEditingTextAttributes = true
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

        /// Strips formatting off pasted text.
        ///
        /// `allowImagePasteMenu` has to put the field in rich-text mode to make
        /// the Paste item appear for images at all, and the side effect would be
        /// that text pasted from a web page or a document arrives carrying its
        /// source font, size, and colour — a visible regression to a far more
        /// common action than the one being fixed. The composer sends a plain
        /// `String`, so flattening to the field's own typing attributes here
        /// keeps text paste looking exactly as it did before rich text was on.
        func textPasteConfigurationSupporting(
            _ textPasteConfigurationSupporting: UITextPasteConfigurationSupporting,
            combineItemAttributedStrings itemStrings: [NSAttributedString],
            for textRange: UITextRange
        ) -> NSAttributedString {
            let plain = itemStrings.map(\.string).joined()
            let attributes = (textPasteConfigurationSupporting as? UITextView)?.typingAttributes
            return NSAttributedString(string: plain, attributes: attributes)
        }
    }
}
