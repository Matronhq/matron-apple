#if os(macOS)
import AppKit
import SwiftUI

/// Mac-only selectable message body. Renders a markdown message as a single,
/// non-editable `NSTextView` so a mouse drag can select across the whole
/// message — spanning paragraphs, lists, and code — which `MarkdownText`'s
/// per-block SwiftUI `Text`s can't do (`.textSelection(.enabled)` stops at a
/// block boundary).
///
/// The markdown → `NSAttributedString` conversion lives in `MarkdownAttributed`
/// (cached, pure). This view is the SwiftUI ↔ AppKit seam: it hosts the text
/// view at full content height (no scroll view) and reports an exact height for
/// the proposed width via `sizeThatFits`, so the timeline lays it out like any
/// other fixed-height row.
///
/// Height reporting is a pure function of (attributed string, width): the text
/// view is laid out into a container of the proposed width and the used rect is
/// measured and rounded up. There is no async invalidation or
/// observation-driven resize — this repo has scar tissue from text-height churn
/// destabilising the timeline, so heights must never move for a fixed input.
public struct SelectableMessageText: View {
    private let attributed: NSAttributedString

    /// - Parameter source: raw markdown message body.
    public init(_ source: String) {
        self.attributed = MarkdownAttributed.attributedString(for: source)
    }

    public var body: some View {
        SelectableTextViewRepresentable(attributed: attributed)
    }
}

/// `NSViewRepresentable` wrapping the non-editable, selectable `NSTextView`.
private struct SelectableTextViewRepresentable: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        // A bare `NSTextView` (no enclosing scroll view) laid out at full
        // content height. `drawsBackground = false` lets the message-bubble
        // chrome show through; `textContainerInset = .zero` keeps our own
        // paragraph metrics authoritative.
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // Track the container width to the view width so wrapping matches the
        // width SwiftUI proposes (and that `sizeThatFits` measures against).
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.delegate = context.coordinator
        // Links are clickable but the body is not editable.
        textView.isAutomaticLinkDetectionEnabled = false
        textView.displaysLinkToolTips = true
        textView.textStorage?.setAttributedString(attributed)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        // Only touch the storage when the content actually changed (streaming
        // deltas re-emit the same view). Avoids needless relayout churn.
        if textView.textStorage?.string != attributed.string
            || !(textView.textStorage?.isEqual(to: attributed) ?? false) {
            textView.textStorage?.setAttributedString(attributed)
        }
    }

    /// Exact height for the proposed width. Measured via `MarkdownAttributed`'s
    /// standalone TextKit stack (a pure function of attributed string + width)
    /// rather than the live text view — the live view's `widthTracksTextView`
    /// container fights a manually-set width and yields clipped heights.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else {
            return nil
        }
        let height = MarkdownAttributed.height(for: attributed, width: width)
        return CGSize(width: width, height: height)
    }

    /// Handles link clicks with the same scheme policy as `MarkdownText`
    /// (http(s) → system handler, matrix/mxc → swallowed). `MarkdownText.handle`
    /// is the source of truth for that policy but its `OpenURLAction.Result`
    /// return type is only meaningful inside SwiftUI's `openURL` environment, so
    /// the decision is mirrored here directly. Note that matrix/mxc URLs never
    /// carry a `.link` attribute (see `MarkdownAttributed`), so in practice only
    /// http(s)/unknown schemes ever reach this delegate.
    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            switch link {
            case let value as URL: url = value
            case let value as String: url = URL(string: value)
            default: url = nil
            }
            guard let url else { return false }
            switch url.scheme?.lowercased() {
            case "matrix", "mxc":
                // Swallowed until permalink / content-URI handling lands —
                // mirrors `MarkdownText.handle(url:)`.
                break
            default:
                NSWorkspace.shared.open(url)
            }
            // Return `true` either way: we've decided the outcome, so the text
            // view shouldn't also hand the URL to its default opener.
            return true
        }
    }
}
#endif
