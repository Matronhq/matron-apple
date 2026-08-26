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
    private let source: String
    private let rendered: MarkdownAttributed.Rendered

    /// - Parameter source: raw markdown message body. Kept alongside the
    ///   render products because copy needs the verbatim source, and because
    ///   the memo they live in is keyed on the SOURCE — `**hi**` and `hi`
    ///   render identical plain text with different fonts, so the rendered
    ///   text can't identify a size (bugbot, PR #37).
    public init(_ source: String) {
        self.source = source
        self.rendered = MarkdownAttributed.rendered(for: source)
    }

    public var body: some View {
        SelectableTextViewRepresentable(source: source, rendered: rendered)
            .overlay {
                // Copy buttons for fenced code blocks, one per block, pinned
                // to each block's top-right. Geometry comes from the same
                // pure (source, width) measurement stack as `sizeThatFits`,
                // so the rects match what the text view rendered. The
                // GeometryReader itself draws nothing and only the buttons
                // hit-test, so text selection under the overlay is untouched.
                GeometryReader { proxy in
                    let frames = rendered.codeBlockFrames(width: proxy.size.width)
                    ForEach(frames.indices, id: \.self) { index in
                        let frame = frames[index]
                        CodeBlockCopyButton(code: frame.code)
                            // Just past the block's top-right corner when the
                            // block is narrow; clamped inside the message
                            // bounds for full-width blocks.
                            .position(
                                x: min(frame.rect.maxX + 12, proxy.size.width - 12),
                                y: frame.rect.minY + 12
                            )
                    }
                }
            }
    }
}

/// Small copy button overlaid on one rendered code block. Copies the block's
/// bare code (no fences) and flashes a checkmark as feedback.
private struct CodeBlockCopyButton: View {
    let code: String
    @State private var copied = false
    /// Cancelled on re-tap so a second copy gets a full 1.2s of checkmark,
    /// not the tail of the first tap's timer.
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(code, forType: .string)
            copied = true
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: 12, height: 12)
                .padding(4)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Copy code")
        .accessibilityLabel("Copy code")
    }
}

/// The message-body text view: `MouseTrackingRescueTextView`'s tracking-loop
/// protections plus markdown-preserving copy. `copy(_:)` is the single seam —
/// ⌘C, the Edit menu, and the context menu all route through it for a
/// non-editable text view.
final class MessageCopyTextView: MouseTrackingRescueTextView {
    /// Raw markdown source of the rendered message. A selection covering the
    /// whole storage copies this verbatim (perfect fidelity, matching the
    /// message context menu's Copy); partial selections reconstruct via
    /// `MarkdownReconstruction`.
    var markdownSource: String = ""

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        // Deterministic no-op on empty selection — `super.copy` with no
        // selection has unspecified behavior and must not clear the
        // pasteboard.
        guard range.length > 0, let storage = textStorage else { return }

        let markdown: String
        if let code = MarkdownReconstruction.soleCodeBlockText(from: storage, in: range) {
            // Selection entirely inside one code block: bare code beats both
            // paths below — the user sees only code and expects to paste it
            // runnable, not wrapped in ``` fences (Dan, 2026-08-26).
            markdown = code
        } else if range == NSRange(location: 0, length: storage.length), !markdownSource.isEmpty {
            markdown = markdownSource
        } else {
            markdown = MarkdownReconstruction.markdown(from: storage, in: range)
        }

        // Plain text carries the markdown; RTF carries the rendered look so
        // rich-text targets keep formatting.
        let selected = storage.attributedSubstring(from: range)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.rtf, .string], owner: nil)
        if let rtf = selected.rtf(
            from: NSRange(location: 0, length: selected.length),
            documentAttributes: [:]
        ) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        pasteboard.setString(markdown, forType: .string)
    }
}

/// `NSViewRepresentable` wrapping the non-editable, selectable `NSTextView`.
private struct SelectableTextViewRepresentable: NSViewRepresentable {
    let source: String
    let rendered: MarkdownAttributed.Rendered

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        // A bare text view (no enclosing scroll view) laid out at full
        // content height. `drawsBackground = false` lets the message-bubble
        // chrome show through; `textContainerInset = .zero` keeps our own
        // paragraph metrics authoritative. `MessageCopyTextView` layers
        // markdown-preserving copy on `MouseTrackingRescueTextView` — the
        // rescue base matters because message bubbles are exactly where the
        // 2026-08-02 tracking-loop wedge hit (see that class's doc).
        let textView = MessageCopyTextView()
        textView.markdownSource = source
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
        useTextKit1IfTabled(textView)
        textView.textStorage?.setAttributedString(rendered.attributed)
        context.coordinator.lastApplied = rendered.attributed
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        (textView as? MessageCopyTextView)?.markdownSource = source
        useTextKit1IfTabled(textView)
        // Only touch the storage when the content actually changed (streaming
        // deltas re-emit the same view). Streaming re-emits the same view with
        // the same cached `Rendered`, so pointer equality is the cheap
        // "unchanged" test — the old string + `isEqual(to:)` pair walked the
        // whole content on every update. A cache-evicted-and-rebuilt source
        // reapplies identical content once: harmless.
        if context.coordinator.lastApplied !== rendered.attributed {
            textView.textStorage?.setAttributedString(rendered.attributed)
            context.coordinator.lastApplied = rendered.attributed
        }
    }

    /// Switches a table-bearing text view to TextKit 1 up front. Touching
    /// `layoutManager` is the documented opt-out from TextKit 2, and it must
    /// happen before the view lays out: left to itself AppKit only falls back
    /// once the view is in a window, and the re-size that follows keeps the
    /// view's top edge — shifting its origin off the frame SwiftUI gave it
    /// (body drawn above the bubble, first rows clipped). TextKit 2 cannot lay
    /// out `NSTextTable` at all, so a windowless host (snapshot tests) would
    /// otherwise render a table's cells as loose stacked lines.
    /// Messages without tables keep today's TextKit 2 path untouched.
    private func useTextKit1IfTabled(_ textView: NSTextView) {
        guard textView.textLayoutManager != nil, rendered.containsTable else { return }
        _ = textView.layoutManager
    }

    /// Exact size for the proposed width. Measured via `MarkdownAttributed`'s
    /// standalone TextKit stack (a pure function of attributed string + width)
    /// rather than the live text view — the live view's `widthTracksTextView`
    /// container fights a manually-set width and yields clipped heights.
    /// Reports the content's natural width (never the full proposal) so a
    /// short message's bubble hugs its text instead of spanning the pane.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else {
            return nil
        }
        return rendered.size(width: width)
    }

    /// Handles link clicks with the same scheme policy as `MarkdownText`
    /// (http(s) → system handler, matrix/mxc → swallowed). `MarkdownText.handle`
    /// is the source of truth for that policy but its `OpenURLAction.Result`
    /// return type is only meaningful inside SwiftUI's `openURL` environment, so
    /// the decision is mirrored here directly. Note that matrix/mxc URLs never
    /// carry a `.link` attribute (see `MarkdownAttributed`), so in practice only
    /// http(s)/unknown schemes ever reach this delegate.
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// The exact `NSAttributedString` instance last written into the text
        /// view's storage. `MarkdownAttributed.Rendered` is memoised per
        /// source, so identity here is a valid — and O(1) — "content is
        /// unchanged" test (see `updateNSView`).
        var lastApplied: NSAttributedString?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            // Tell the press-rescue layer the link WAS dispatched, whichever
            // internal AppKit route got here — this is what keeps the
            // swallowed-click fallback from ever double-opening.
            (textView as? MouseTrackingRescueTextView)?.noteLinkClickHandled()
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
