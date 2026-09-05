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
    private let itemID: String?
    private let rendered: MarkdownAttributed.Rendered
    /// The owning timeline's cross-message selection, when hosted in one.
    /// Optional environment: previews, tests and non-timeline hosts have
    /// none, and the body then behaves exactly as before.
    @Environment(MessageSelectionController.self) private var selectionController: MessageSelectionController?

    /// - Parameters:
    ///   - source: raw markdown message body. Kept alongside the
    ///     render products because copy needs the verbatim source, and because
    ///     the memo they live in is keyed on the SOURCE — `**hi**` and `hi`
    ///     render identical plain text with different fonts, so the rendered
    ///     text can't identify a size (bugbot, PR #37).
    ///   - itemID: the timeline item this body belongs to; enables the
    ///     cross-message selection. `nil` opts out.
    public init(_ source: String, itemID: String? = nil) {
        self.source = source
        self.itemID = itemID
        self.rendered = MarkdownAttributed.rendered(for: source)
    }

    public var body: some View {
        SelectableTextViewRepresentable(
            source: source, rendered: rendered,
            itemID: itemID, selectionController: selectionController)
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
/// protections plus markdown-preserving copy, plus the view's side of the
/// cross-message selection (`CrossSelectionTarget`). `copy(_:)` is the
/// single seam — ⌘C, the Edit menu, and the context menu all route through
/// it for a non-editable text view.
final class MessageCopyTextView: MouseTrackingRescueTextView, CrossSelectionTarget {
    /// Raw markdown source of the rendered message. A selection covering the
    /// whole storage copies this verbatim (perfect fidelity, matching the
    /// message context menu's Copy); partial selections reconstruct via
    /// `MarkdownReconstruction`.
    var markdownSource: String = ""

    /// The timeline item this body belongs to. `nil` (previews, tests, the
    /// composer palette) keeps the view out of any cross-message selection.
    var selectionItemID: String? {
        // `unregister` keys its lookup off `target.selectionItemID` read at
        // call time, so it must run in `willSet` — while the OLD id is still
        // current — or an id change no-ops the unregister (it looks itself
        // up under the NEW id, finds nothing, and the stale entry under the
        // old id survives, keeping this view reachable under a message it no
        // longer represents).
        willSet { selectionController?.unregister(self) }
        didSet { reregister(previousController: selectionController) }
    }

    /// The owning timeline's controller. Registration follows the window:
    /// attached views are candidates, detached ones are dropped.
    var selectionController: MessageSelectionController? {
        didSet { reregister(previousController: oldValue) }
    }

    /// The span of THIS message inside the cross-message selection, or nil.
    /// Drawn through TextKit rendering attributes (TK2) / temporary
    /// attributes (TK1) rather than `selectedRange`, so every span in the
    /// selection paints in the same colour — `selectedRange` would draw
    /// unemphasized grey in every view that is not first responder, and
    /// only one can be.
    private(set) var crossSelectionRange: NSRange?

    // MARK: Registration

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reregister(previousController: selectionController)
    }

    private func reregister(previousController: MessageSelectionController?) {
        previousController?.unregister(self)
        if window != nil, selectionItemID != nil {
            selectionController?.register(self)
        } else {
            // Leaving the window (or losing our id) also drops any highlight.
            if crossSelectionRange != nil { setCrossSelection(nil) }
        }
    }

    // MARK: CrossSelectionTarget

    var storageLength: Int { textStorage?.length ?? 0 }

    var frameInWindow: NSRect {
        convert(bounds, to: nil)
    }

    func characterIndex(atWindowPoint point: NSPoint) -> Int {
        characterIndexForInsertion(at: convert(point, from: nil))
    }

    func setCrossSelection(_ range: NSRange?) {
        let length = storageLength
        let clamped: NSRange? = range.map { r in
            let location = min(max(0, r.location), length)
            let end = min(max(location, r.location + r.length), length)
            return NSRange(location: location, length: end - location)
        }
        crossSelectionRange = clamped
        applyHighlight(clamped)
    }

    func crossSelectionMarkdown() -> String {
        guard let storage = textStorage, let range = crossSelectionRange, range.length > 0 else { return "" }
        let clamped = NSRange(location: min(range.location, storage.length),
                              length: min(range.length, storage.length - min(range.location, storage.length)))
        guard clamped.length > 0 else { return "" }
        if clamped == NSRange(location: 0, length: storage.length), !markdownSource.isEmpty {
            return markdownSource
        }
        return MarkdownReconstruction.markdown(from: storage, in: clamped)
    }

    private func applyHighlight(_ range: NSRange?) {
        let full = NSRange(location: 0, length: storageLength)
        if let layoutManager = textLayoutManager, let content = layoutManager.textContentManager {
            // TextKit 2: rendering attributes are draw-only — never enter the
            // storage, never affect `MarkdownReconstruction`.
            layoutManager.removeRenderingAttribute(.backgroundColor, for: layoutManager.documentRange)
            if let range, range.length > 0, let textRange = Self.textRange(range, in: content) {
                layoutManager.addRenderingAttribute(
                    .backgroundColor, value: NSColor.selectedTextBackgroundColor, for: textRange)
            }
        } else if let layoutManager = layoutManager {
            // TextKit 1 (tabled messages, see `useTextKit1IfTabled`).
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            if let range, range.length > 0 {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor, value: NSColor.selectedTextBackgroundColor, forCharacterRange: range)
            }
        }
        needsDisplay = true
    }

    private static func textRange(_ range: NSRange, in content: NSTextContentManager) -> NSTextRange? {
        guard let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    // MARK: Press takeover

    /// Vertical slack, in points, before a drag leaving the body counts as
    /// leaving the message (guards against jitter on the first/last line).
    static let escapeSlop: CGFloat = 4
    /// How long the loop waits for the next event before re-checking the
    /// physical button — the lost-`mouseUp` guard for this path (see
    /// `MouseTrackingRescueTextView` for why a press can outlive its up).
    static let pressPollInterval: TimeInterval = 0.25

    /// `true` when the pointer's y (view coordinates) is outside the body's
    /// vertical band including `slop`. Horizontal overshoot never escalates
    /// — dragging past a line's end must still select to the line end.
    static func shouldEscalate(pointY: CGFloat, bounds: NSRect, slop: CGFloat) -> Bool {
        pointY < bounds.minY - slop || pointY > bounds.maxY + slop
    }

    /// Plain single left-clicks only. Multi-clicks (word/paragraph
    /// selection) and shift/⌘/⌥/ctrl presses keep AppKit's own handling.
    static func takesOverPress(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 1 else { return false }
        return event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
    }

    /// Grows the in-progress text selection from the press anchor to `point`
    /// (view coordinates). `anchorIndex` is re-clamped on every use: a
    /// streaming delta can replace the storage mid-press and shrink it below
    /// the index the press started on. Always `stillSelecting: true` — the
    /// tail of `mouseDown` closes the sequence exactly once.
    private func extendSelection(fromAnchor anchorIndex: Int, toViewPoint point: NSPoint) {
        let anchor = min(anchorIndex, storageLength)
        let index = characterIndexForInsertion(at: point)
        let range = NSRange(location: min(anchor, index), length: abs(index - anchor))
        setSelectedRange(range, affinity: index < anchor ? .upstream : .downstream, stillSelecting: true)
    }

    override func mouseDown(with event: NSEvent) {
        // `anchorID` is captured HERE, not read inside the loop: the loop
        // pumps the main run loop in `.eventTracking` (a common mode), so
        // SwiftUI's `updateNSView` can run mid-drag and reassign
        // `selectionItemID` — to nil, or to a different message when a body
        // view is recycled. Reading it later would crash on nil or pair a
        // new id with this press's anchor index.
        guard let controller = selectionController, let anchorID = selectionItemID,
              isSelectable, !isEditable, Self.takesOverPress(event) else {
            super.mouseDown(with: event)
            return
        }
        // Any press ends the previous cross-message selection.
        controller.clear()
        armLinkPress(for: event)
        window?.makeFirstResponder(self)

        let anchorIndex = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        setSelectedRange(NSRange(location: anchorIndex, length: 0))

        var escalated = false
        var lastDrag: NSEvent?
        loop: while true {
            guard let window, superview != nil else { break }
            let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date(timeIntervalSinceNow: Self.pressPollInterval),
                inMode: .eventTracking, dequeue: true)
            guard let next else {
                // Timed out: is the press still real?
                if !leftButtonIsDown() { break loop }
                // Pointer parked (usually against a viewport edge) with the
                // button still held. Autoscroll regardless of escalation —
                // a message taller than the viewport scrolls WITHIN itself,
                // and the selection has to keep growing as content moves
                // under the stationary pointer.
                if let lastDrag {
                    autoscroll(with: lastDrag)
                    if escalated {
                        controller.extend(toWindowPoint: lastDrag.locationInWindow, window: window)
                    } else {
                        // Re-derive AFTER the scroll: the same window point
                        // now names a different character.
                        extendSelection(fromAnchor: anchorIndex,
                                        toViewPoint: convert(lastDrag.locationInWindow, from: nil))
                    }
                }
                continue
            }
            if next.type == .leftMouseUp { break loop }
            lastDrag = next
            // Unconditional, and BEFORE the window→view conversion. AppKit's
            // own tracking loop autoscrolled for free; this path replaces it,
            // and `shouldEscalate` compares against the view's own `bounds`,
            // which for a long message extends well past the visible clip
            // rect — so a drag at the viewport edge inside a tall message
            // neither escalates nor scrolls unless we scroll here. It no-ops
            // when the point is inside the clip view.
            autoscroll(with: next)
            let point = convert(next.locationInWindow, from: nil)
            if Self.shouldEscalate(pointY: point.y, bounds: bounds, slop: Self.escapeSlop) {
                if !escalated {
                    escalated = true
                    // Hand the within-message selection over to the controller.
                    let anchor = min(anchorIndex, storageLength)
                    setSelectedRange(NSRange(location: anchor, length: 0))
                    controller.beginCrossMessage(anchorID: anchorID, charIndex: anchor)
                }
                controller.extend(toWindowPoint: next.locationInWindow, window: window)
            } else {
                if escalated {
                    // Back inside the anchor: ordinary text selection again.
                    escalated = false
                    controller.clear()
                }
                extendSelection(fromAnchor: anchorIndex, toViewPoint: point)
            }
        }

        if escalated {
            controller.finish()
        } else {
            let range = selectedRange()
            setSelectedRange(range, affinity: .downstream, stillSelecting: false)
            // We ran the loop, so AppKit never saw the click — a clean press
            // on a link is dispatched here as the normal route.
            resolveLinkPressIfNeeded(expected: true)
        }
    }

    // MARK: Copy entry points

    static func menuTitle(forMessageCount count: Int) -> String {
        "Copy \(count) Message\(count == 1 ? "" : "s")"
    }

    @objc func copyCrossSelection(_ sender: Any?) {
        selectionController?.copyTranscript()
    }

    override func copy(_ sender: Any?) {
        if let selectionController, selectionController.hasSelection {
            selectionController.copyTranscript()
            return
        }
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

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        // The anchor's own text selection is empty during a cross-message
        // selection, which would grey out Edit ▸ Copy.
        if item.action == #selector(NSTextView.copy(_:)), selectionController?.hasSelection == true {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let selectionController, selectionController.hasSelection,
              let count = selectionController.transcriptProvider?().messageCount, count > 0 else { return menu }
        let item = NSMenuItem(
            title: Self.menuTitle(forMessageCount: count),
            action: #selector(copyCrossSelection(_:)), keyEquivalent: "")
        item.target = self
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(item, at: 0)
        return menu
    }
}

/// `NSViewRepresentable` wrapping the non-editable, selectable `NSTextView`.
private struct SelectableTextViewRepresentable: NSViewRepresentable {
    let source: String
    let rendered: MarkdownAttributed.Rendered
    let itemID: String?
    let selectionController: MessageSelectionController?

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
        textView.selectionItemID = itemID
        textView.selectionController = selectionController
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
        if let view = textView as? MessageCopyTextView {
            if view.selectionItemID != itemID { view.selectionItemID = itemID }
            if view.selectionController !== selectionController { view.selectionController = selectionController }
        }
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
            // Streaming replaced the storage: re-clamp and repaint the
            // cross-message span (rendering attributes die with the storage).
            if let view = textView as? MessageCopyTextView, let range = view.crossSelectionRange {
                view.setCrossSelection(range)
            }
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
