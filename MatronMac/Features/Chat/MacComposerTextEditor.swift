import SwiftUI
import AppKit

/// The AppKit text editor backing the Mac composer input.
///
/// This replaces SwiftUI's `TextField(axis: .vertical)`: the field editor
/// AppKit lends a focused SwiftUI text field keeps the text-container width
/// it was created with, so narrowing the window clipped the tail of every
/// line instead of re-wrapping (Dan, 2026-07-16 — pinned by
/// `MacComposerWrapLayoutTests.test_narrowingWidthWhileFocused_reflowsText`).
/// An `NSTextView` whose container tracks its own width re-wraps on live
/// resize by construction, and it owns its key handling, so the composer's
/// Return/arrow behaviour moves from SwiftUI key-press modifiers and a
/// window-wide Shift+Return event monitor into one delegate.
///
/// Behaviour contract, all supplied by the SwiftUI side:
/// - `text` stays two-way synced (history recall, slash-palette completion,
///   draft restore, and post-send clearing all write the binding).
/// - `onHeightChange` reports the laid-out content height (text + insets)
///   whenever the text or the width changes, driving the composer's
///   grow-then-scroll frame.
/// - `onMoveUp` / `onMoveDown` / `onCommit` return `true` to consume the
///   key. Shift+Return never reaches `onCommit` — it inserts a newline at
///   the caret, which is the whole reason the old event monitor existed.
/// - `onPasteAttachments` returns `true` when it claimed the pasteboard
///   (files or images); text pastes fall through to the text view.
struct MacComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onHeightChange: (CGFloat) -> Void
    let onMoveUp: () -> Bool
    let onMoveDown: () -> Bool
    let onCommit: () -> Bool
    let onPasteAttachments: () -> Bool

    /// Matches the `.padding(8)` the SwiftUI field carried, so the swap
    /// doesn't move the text. `MacComposerView.singleLineInputHeight`
    /// derives the accessory-button height from the same value.
    static let textInset: CGFloat = 8

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        // The composer sends commands and code verbatim — auto-substituted
        // smart quotes/dashes or surprise spelling corrections would change
        // what the bridge receives.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        // Grow-with-content vertically; the container tracks the view's
        // width so a live window resize re-wraps the text (the fix).
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: Self.textInset, height: Self.textInset)

        textView.delegate = context.coordinator
        textView.claimPasteboardAttachments = onPasteAttachments

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // The container re-wraps on its own when the width changes; this
        // notification is how the new (taller/shorter) laid-out height gets
        // reported back so the composer frame follows.
        textView.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak textView, coordinator = context.coordinator] _ in
            guard let textView else { return }
            MainActor.assumeIsolated { coordinator.reportHeight(of: textView) }
        }

        textView.string = text
        context.coordinator.reportHeight(of: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ComposerTextView else { return }
        textView.claimPasteboardAttachments = onPasteAttachments
        if textView.string != text {
            textView.string = text
            // External writes (history recall, palette completion) replace
            // the whole text — the caret belongs at the end, ready to type.
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.reportHeight(of: textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacComposerTextEditor
        var frameObserver: (any NSObjectProtocol)?
        private var lastReportedHeight: CGFloat = -1

        init(_ parent: MacComposerTextEditor) {
            self.parent = parent
        }

        deinit {
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            reportHeight(of: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift+Return inserts a newline at the caret (returning
                // false lets the text view do exactly that); plain Return is
                // the commit gesture.
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    return false
                }
                return parent.onCommit()
            case #selector(NSResponder.moveUp(_:)):
                return parent.onMoveUp()
            case #selector(NSResponder.moveDown(_:)):
                return parent.onMoveDown()
            default:
                return false
            }
        }

        /// Reports the height TextKit laid the text into (plus the insets),
        /// deduplicated so the report → frame change → notification cycle
        /// settles instead of looping.
        func reportHeight(of textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let height = ceil(layoutManager.usedRect(for: container).height)
                + textView.textContainerInset.height * 2
            guard height != lastReportedHeight else { return }
            lastReportedHeight = height
            let report = parent.onHeightChange
            // Async: the first report happens during SwiftUI's view-update
            // pass, where writing @State is undefined behaviour.
            DispatchQueue.main.async { report(height) }
        }
    }
}

/// `NSTextView` that offers ⌘V pastes carrying files or images to the
/// composer's attachment flow before falling back to a text paste —
/// mirroring what `.onPasteCommand(of: [.image, .fileURL])` did for the
/// SwiftUI field.
final class ComposerTextView: NSTextView {
    var claimPasteboardAttachments: (() -> Bool)?

    override func paste(_ sender: Any?) {
        if claimPasteboardAttachments?() == true { return }
        super.paste(sender)
    }
}
