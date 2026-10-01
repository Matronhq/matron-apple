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
    ///   - style: the reading scale — `.chat` (the timeline, the default)
    ///     or `.item` (the tracker item thread, tracker #2533).
    ///   - defersTextView: for a scroll view that lays out every row up
    ///     front — the item thread (mission 6040). See `defersTextView`.
    public init(_ source: String, itemID: String? = nil, style: MarkdownAttributed.Style = .chat,
                defersTextView: Bool = false) {
        self.source = source
        self.itemID = itemID
        self.rendered = MarkdownAttributed.rendered(for: source, style: style)
        self.defersTextView = defersTextView
    }

    /// Builds the NSTextView only once the body comes within
    /// `realiseMargin` of the scroll view's visible rect, standing in a box
    /// of EXACTLY the size the text view will report until then — so an
    /// eagerly laid-out thread has its final height from the first frame
    /// and nothing moves when a card's text view arrives. A deferred body
    /// also lays out with TextKit 1: TextKit 2 re-runs its viewport layout
    /// on every scroll step, which in the item thread cost more than the
    /// rest of a scroll put together; TextKit 1 lays out once, and is the
    /// stack `MarkdownAttributed` measures with. Off by default: the chat
    /// timeline virtualises its rows itself.
    private let defersTextView: Bool
    /// Set the first time the body comes near the visible rect; never
    /// cleared, so a card read once keeps its text view (and its place in a
    /// drag selection) rather than rebuilding it on every pass.
    @State private var isRealised = false
    /// How far outside the visible rect a deferred body is already built,
    /// so a card scrolled into view at a normal pace never shows its empty
    /// stand-in.
    static let realiseMargin: CGFloat = 400

    public var body: some View {
        if defersTextView, !isRealised, #available(macOS 15.0, *) {
            DeferredTextBox(rendered: rendered) { Color.clear }
                // Until it is built the body is an empty box; carry its words
                // so VoiceOver reads a card still outside the realise margin
                // (Bugbot, PR #298).
                .accessibilityElement()
                .accessibilityLabel(Text(rendered.attributed.string))
                .accessibilityAddTraits(.isStaticText)
                // Not `onScrollVisibilityChange`: in an eager stack it
                // reports every row visible at once. The box's own bounds
                // against the enclosing scroll view's visible rect say
                // whether it is near the screen; outside any scroll view it
                // is built at once.
                .onGeometryChange(for: Bool.self) { proxy in
                    guard let visible = proxy.bounds(of: .scrollView) else { return true }
                    return visible.insetBy(dx: 0, dy: -Self.realiseMargin)
                        .intersects(CGRect(origin: .zero, size: proxy.size))
                } action: { nearScreen in
                    if nearScreen { isRealised = true }
                }
        } else {
            textView
        }
    }

    private var textView: some View {
        SelectableTextViewRepresentable(
            source: source, rendered: rendered,
            itemID: itemID, selectionController: selectionController,
            usesTextKit1: defersTextView)
            .overlay {
                // Copy buttons for fenced code blocks, one per block, pinned
                // to each block's top-right. Geometry comes from the same
                // pure (source, width) measurement stack as `sizeThatFits`,
                // so the rects match what the text view rendered. The
                // GeometryReader itself draws nothing and only the buttons
                // hit-test, so text selection under the overlay is untouched.
                GeometryReader { proxy in
                    let frames = rendered.codeBlockFrames(width: proxy.size.width,
                                                          textKit1: defersTextView ? true : nil)
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

/// The stand-in for a deferred body (`SelectableMessageText.defersTextView`):
/// draws nothing and sizes itself through the same pure measurement as
/// `SelectableTextViewRepresentable.sizeThatFits`, so swapping in the real
/// text view changes no frame. With no proposed width it reports zero, where
/// the representable falls back to the view's own fitting size — a deferred
/// body is only ever asked inside a width-bounded thread.
private struct DeferredTextBox: Layout {
    let rendered: MarkdownAttributed.Rendered

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        #if DEBUG
        SelectableMessageTextProbe.deferredWidths.append(Int(proposal.width ?? -1))
        #endif
        guard let width = proposal.width, width > 0, width.isFinite else { return .zero }
        return rendered.size(width: width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
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

    /// Where `copy(_:)` writes. The app uses the system clipboard; tests
    /// inject a private named pasteboard so a test run never replaces what
    /// the developer has on theirs.
    var pasteboard: NSPasteboard = .general
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
        didSet {
            // A span painted under the OLD id is now unreachable by the
            // controller (it looks its targets up by id), so a later shrink
            // or clear can never remove it — drop it here or the highlight is
            // stranded on screen until the view is destroyed.
            if selectionItemID != oldValue, crossSelectionRange != nil { setCrossSelection(nil) }
            reregister(previousController: selectionController)
        }
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
        characterIndex(atViewPoint: convert(point, from: nil))
    }

    /// `characterIndexForInsertion` with TextKit 2's top-edge quirk removed:
    /// it maps a point ABOVE the first line to the END of the document
    /// (measured: y = -6 → length), the same answer as a point below the last
    /// line. Every pointer→index lookup goes through here — the cross-message
    /// head (resolved by nearest row while the pointer is still in the gap
    /// above that row, where the span then ran the wrong way) and the
    /// within-message drag (a pointer a few points above the first line, inside
    /// the escalation slop, jumped the selection to the rest of the message).
    ///
    /// The same quirk has a second form: a point in the paragraph-spacing gap
    /// BELOW a paragraph maps to that paragraph's START (the first gap in a
    /// message maps to 0). A drag moving down through a gap then snapped the
    /// selection back a whole paragraph and forward again, visible as the
    /// selection jumping back and forth (tracker #2533 follow-up; the item
    /// style's 14 pt gap made it easy to hit). A gap point is pulled up onto
    /// the paragraph's last line, so it resolves to that line at the
    /// pointer's x, as the line itself would.
    ///
    /// "Above the first line" starts at the container origin, not the view's
    /// top: a message that opens with a code block carries a top container
    /// inset (`Rendered.codeEdgeInset`), and a point inside it is still above
    /// the first line — TextKit 2 answered the document end there, so a drag
    /// entering such a message from above jumped to its end.
    func characterIndex(atViewPoint point: NSPoint) -> Int {
        if point.y < textContainerOrigin.y { return 0 }
        return characterIndexForInsertion(at: pointOutOfParagraphGap(point))
    }

    private func pointOutOfParagraphGap(_ point: NSPoint) -> NSPoint {
        let origin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = textLayoutManager?.textLayoutFragment(for: inContainer),
              let lastLine = fragment.textLineFragments.last else { return point }
        let frame = fragment.layoutFragmentFrame
        let textBottom = frame.minY + lastLine.typographicBounds.maxY
        guard inContainer.y >= textBottom else { return point }
        let lineMid = frame.minY + lastLine.typographicBounds.midY
        return NSPoint(x: point.x, y: lineMid + origin.y)
    }

    func setCrossSelection(_ range: NSRange?) {
        setCrossSelection(range, force: false)
    }

    // MARK: - Rendered content

    /// Character ranges of the current content's fenced code blocks, handed
    /// over with the string by `apply(_:)`. Empty for most messages, which
    /// then skip every code-box computation (draw, resize).
    private var codeRanges: [NSRange] = []
    /// `codeBlockBoxes()` memo for one width; cleared by `apply(_:)` and a
    /// width change — the only things that move the boxes.
    private var cachedBoxes: (width: CGFloat, boxes: [NSRect])?

    /// Puts a rendered message into this view: the string, the code-edge
    /// container inset (`Rendered.codeEdgeInset`), and the code-block
    /// ranges the background boxes are drawn from. The one place a host
    /// sets content — `SelectableMessageText` today, and any other host of
    /// this view (the AppKit timeline's message body) must call it too
    /// rather than setting the storage and inset itself, or code-edge
    /// messages get a clipped box and a size that disagrees with
    /// `Rendered.size(width:)`.
    func apply(_ rendered: MarkdownAttributed.Rendered) {
        textStorage?.setAttributedString(rendered.attributed)
        let inset = NSSize(width: 0, height: rendered.codeEdgeInset)
        if textContainerInset != inset { textContainerInset = inset }
        let hadBoxes = !codeRanges.isEmpty
        codeRanges = rendered.codeBlockRanges
        cachedBoxes = nil
        // Repaint when boxes appear, move or must be erased.
        if hadBoxes || !codeRanges.isEmpty { needsDisplay = true }
    }

    // MARK: - Code block boxes

    /// One background box per fenced code block, in view coordinates, from
    /// THIS view's live layout. `MarkdownAttributed` gives code lines no
    /// per-glyph background (that painted each line as its own strip); the
    /// box is drawn here, behind the text, instead.
    ///
    /// Live layout, from the engine that draws the text: TextKit 1 and 2
    /// place a paragraph's `lineSpacing` differently (TK1 after its last
    /// line, TK2 before the next paragraph), so geometry measured on the
    /// other engine sat 4pt off in the item style. Memoised per width.
    func codeBlockBoxes() -> [NSRect] {
        guard !codeRanges.isEmpty, let storage = textStorage else { return [] }
        let width = bounds.width
        if let cachedBoxes, cachedBoxes.width == width { return cachedBoxes.boxes }
        let origin = textContainerOrigin
        let boxes: [NSRect] = codeRanges.compactMap { range in
            guard NSMaxRange(range) <= storage.length, let union = lineUnion(of: range) else { return nil }
            return MarkdownAttributed.codeBlockBox(
                around: union.offsetBy(dx: origin.x, dy: origin.y), width: width)
        }
        cachedBoxes = (width, boxes)
        return boxes
    }

    /// Checks TextKit 2 FIRST: reading `layoutManager` on a TextKit 2 view
    /// switches it to TextKit 1.
    private func lineUnion(of range: NSRange) -> NSRect? {
        if let layoutManager = textLayoutManager {
            return MarkdownAttributed.lineUnion(of: range, in: layoutManager)
        } else if let layoutManager = layoutManager {
            return MarkdownAttributed.lineUnion(of: range, in: layoutManager)
        }
        return nil
    }

    /// The boxes draw in the text view's own layer, which sits BELOW the
    /// text under either engine (TextKit 2 draws text in private subviews;
    /// TextKit 1 draws it after the background in this same pass).
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !codeRanges.isEmpty else { return }
        let boxes = codeBlockBoxes()
        guard !boxes.isEmpty else { return }
        // A label-colour tint, not `controlBackgroundColor`: item cards and
        // bot bubbles are pure white in light mode, where
        // `controlBackgroundColor` is also white (same reason as the table
        // header shade in `MarkdownAttributed`).
        let fill = NSColor.labelColor.withAlphaComponent(0.05)
        let stroke = NSColor.separatorColor
        for box in boxes where box.intersects(rect) {
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.25, dy: 0.25),
                                    xRadius: MarkdownAttributed.codeBlockCornerRadius,
                                    yRadius: MarkdownAttributed.codeBlockCornerRadius)
            fill.setFill()
            path.fill()
            stroke.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    /// The boxes span the view's width, so a width change moves every edge.
    /// Messages without code blocks are left alone.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.size.width
        super.setFrameSize(newSize)
        if widthChanged, !codeRanges.isEmpty {
            cachedBoxes = nil
            needsDisplay = true
        }
    }

    /// - Parameter force: re-applies the highlight even when the clamped
    ///   range is unchanged. Needed exactly once — after a streaming delta
    ///   swaps the storage, where the range still matches but the rendering
    ///   attributes died with the old storage. Every other caller wants the
    ///   early-out: a drag pushes a range to every view in the span on every
    ///   mouse event, and the middles' ranges never change.
    func setCrossSelection(_ range: NSRange?, force: Bool) {
        let length = storageLength
        let clamped: NSRange? = range.map { r in
            let location = min(max(0, r.location), length)
            let end = min(max(location, r.location + r.length), length)
            return NSRange(location: location, length: end - location)
        }
        guard force || clamped != crossSelectionRange else { return }
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
        // The text is not drawn by this view's own layer: TextKit 2's
        // NSTextView renders it two levels down, in private viewport element
        // views under `_NSTextContentView`, and `needsDisplay` on the text
        // view marks only the text view's layer. Rendering attributes change
        // nothing in layout, so nothing else ever re-renders those views — a
        // highlight added, shrunk or removed here stayed on screen as it was
        // until an unrelated redraw (measured on screen: a cleared span kept
        // its blue through `invalidateLayout`, `layoutViewport` and
        // `invalidateRenderingAttributes`; only dirtying every descendant
        // view repainted it). Public API only: no private class is named.
        Self.setNeedsDisplayRecursively(self)
    }

    private static func setNeedsDisplayRecursively(_ view: NSView) {
        view.needsDisplay = true
        for subview in view.subviews { setNeedsDisplayRecursively(subview) }
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
        let index = characterIndex(atViewPoint: point)
        let range = NSRange(location: min(anchor, index), length: abs(index - anchor))
        setSelectedRange(range, affinity: index < anchor ? .upstream : .downstream, stillSelecting: true)
    }

    /// One pointer position, handled the same way whether it arrived as a
    /// drag event or as a parked pointer re-evaluated after an autoscroll.
    /// Shared on purpose: the parked branch used to only ever grow whichever
    /// selection was already running, so a press held at the viewport edge in
    /// a tall message scrolled to the message end and then froze — it never
    /// re-ran the escalation test after the content moved under it.
    ///
    /// - Parameters:
    ///   - point: pointer in THIS view's coordinates (recomputed after any
    ///     autoscroll — the same window point names a different character
    ///     once the content moved).
    ///   - windowPoint: the same position in window coordinates, for the
    ///     controller's cross-timeline hit test.
    ///   - escalated: in/out — `true` while the controller owns the drag.
    private func handleDragPoint(
        _ point: NSPoint, windowPoint: NSPoint, anchorID: String, anchorIndex: Int,
        controller: MessageSelectionController, escalated: inout Bool
    ) {
        if Self.shouldEscalate(pointY: point.y, bounds: bounds, slop: Self.escapeSlop) {
            if !escalated {
                // Hand the within-message selection over to the controller —
                // but only if it accepts the anchor. It refuses when this
                // message has left the row window mid-press; the press then
                // stays an ordinary within-message drag rather than becoming
                // a selection that belongs to nobody.
                let anchor = min(anchorIndex, storageLength)
                escalated = controller.beginCrossMessage(anchorID: anchorID, charIndex: anchor)
                if escalated { setSelectedRange(NSRange(location: anchor, length: 0)) }
            }
            if escalated {
                controller.extend(toWindowPoint: windowPoint, window: window)
                return
            }
        } else if escalated {
            // Back inside the anchor: ordinary text selection again.
            escalated = false
            controller.clear()
        }
        extendSelection(fromAnchor: anchorIndex, toViewPoint: point)
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

        let anchorIndex = characterIndex(atViewPoint: convert(event.locationInWindow, from: nil))
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
                    // Re-derive AFTER the scroll: the same window point now
                    // names a different character — and, in a message taller
                    // than the viewport, can now sit outside (or back inside)
                    // the body's band, so the escalation test must run again.
                    handleDragPoint(
                        convert(lastDrag.locationInWindow, from: nil),
                        windowPoint: lastDrag.locationInWindow,
                        anchorID: anchorID, anchorIndex: anchorIndex,
                        controller: controller, escalated: &escalated)
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
            handleDragPoint(
                convert(next.locationInWindow, from: nil),
                windowPoint: next.locationInWindow,
                anchorID: anchorID, anchorIndex: anchorIndex,
                controller: controller, escalated: &escalated)
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

    /// Copies the transcript the menu item captured when the menu was BUILT.
    /// Deriving it here instead would race the controller's clear-monitor:
    /// clicking the item is a left mouse down, which the monitor sees first
    /// and answers by clearing the selection, leaving nothing to derive.
    /// Senders without a payload (a menu built elsewhere, or a keyboard
    /// route) fall back to the live transcript.
    @objc func copyCrossSelection(_ sender: Any?) {
        if let text = (sender as? NSMenuItem)?.representedObject as? String {
            selectionController?.copyText(text)
            return
        }
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
        // NSTextView's answer for an action it does not know is not
        // contractual — answer for our own item rather than shipping it
        // greyed out on whichever OS version decides to say no.
        if item.action == #selector(copyCrossSelection(_:)) {
            return selectionController?.hasSelection == true
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Two additions to AppKit's menu, in order.
    ///
    /// 1. AppKit builds its own "Open Link" item and that item hands the URL
    ///    straight to the Launch Services opener — it never reaches
    ///    `textView(_:clickedOnLink:at:)`, so it bypasses
    ///    `MatronItemLink.action(for:)`. On `matron://item/65` that means a
    ///    "no application can open this URL" sheet instead of the tracker
    ///    item (item #115, fix round 2). Swap it for one that goes through
    ///    the very same delegate call a left-click does.
    /// 2. The cross-message "Copy N Messages" entry, when a finished
    ///    selection exists.
    override func menu(for event: NSEvent) -> NSMenu? {
        // Exactly what super returned when there is nothing to add — an empty
        // `NSMenu()` substitute would swallow the right-click instead of
        // letting AppKit decline to show a menu at all.
        var base = super.menu(for: event)
        if let menu = base, let (url, charIndex) = link(under: event) {
            base = Self.rewritingLinkItems(in: menu, for: url, charIndex: charIndex, target: self)
        }
        guard let selectionController, selectionController.hasSelection,
              // The FINISHED snapshot, not the live provider: the title and
              // the payload must agree, and neither may change under the
              // click that is about to clear the selection.
              let transcript = selectionController.finishedTranscript,
              transcript.messageCount > 0 else { return base }
        let item = NSMenuItem(
            title: Self.menuTitle(forMessageCount: transcript.messageCount),
            action: #selector(copyCrossSelection(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = transcript.text
        guard let base else {
            let menu = NSMenu()
            menu.addItem(item)
            return menu
        }
        base.insertItem(.separator(), at: 0)
        base.insertItem(item, at: 0)
        return base
    }

    // MARK: - Right-click → "Open Link"

    /// The `.link` attribute under a mouse event, with its character index.
    private func link(under event: NSEvent) -> (URL, Int)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        // Clamp: `characterIndexForInsertion` legitimately returns `length`
        // for a click past the end, which is not a valid attribute index.
        let index = min(characterIndexForInsertion(at: point), storage.length - 1)
        guard index >= 0 else { return nil }
        switch storage.attribute(.link, at: index, effectiveRange: nil) {
        case let value as URL: return (value, index)
        case let value as String: return URL(string: value).map { ($0, index) }
        default: return nil
        }
    }

    /// Pure part of `menu(for:)`, so the policy is testable without a window.
    ///
    /// `.system` URLs (http(s) and anything else we have no opinion on) keep
    /// AppKit's menu verbatim — its "Open Link" is exactly right for those.
    /// Everything else loses that item, and a `matron://item/<n>` or
    /// `matron://convo/<id>` gains an in-app opener in its place.
    static func rewritingLinkItems(in menu: NSMenu, for url: URL, charIndex: Int,
                                   target: MessageCopyTextView?) -> NSMenu {
        let action = MatronItemLink.action(for: url)
        if case .system = action { return menu }
        // Matched by selector NAME: the item AppKit inserts is built from a
        // private selector, and reading its name is inspection, not use. A
        // rename by Apple leaves the (broken) item in place rather than
        // breaking the build or the rest of the menu.
        for item in menu.items where item.action.map({ NSStringFromSelector($0).lowercased().contains("openlink") }) == true {
            menu.removeItem(item)
        }
        let title: String
        switch action {
        case .openTrackerItem(let number): title = "Open Item #\(number)"
        case .openConversation: title = "Open Conversation"
        case .system, .swallow, .openConsent: return menu
        }
        let item = NSMenuItem(title: title,
                              action: #selector(MessageCopyTextView.openLinkInApp(_:)),
                              keyEquivalent: "")
        item.target = target
        item.representedObject = url
        item.tag = charIndex
        menu.insertItem(item, at: 0)
        return menu
    }

    /// Routes the replacement menu item through the delegate — the single
    /// place the link policy lives — so right-click and left-click cannot
    /// disagree, and no `matron://` URL can reach the OS from either.
    @objc func openLinkInApp(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        _ = delegate?.textView?(self, clickedOnLink: url, at: sender.tag)
    }
}

#if DEBUG
/// Test seam (item #1264). Counts row measurements that arrive WITHOUT a
/// usable width: unspecified, zero or infinite. They come from a container
/// probing the transcript's minimum, ideal or maximum size rather than laying
/// it out, and an `HSplitView` pane's hosting view did that for every row on
/// every transcript change. Main-thread only.
public enum SelectableMessageTextProbe {
    nonisolated(unsafe) public static var widthlessMeasurements = 0
    /// Every `sizeThatFits` call, with or without a width.
    nonisolated(unsafe) public static var measurements = 0
    /// The width of every deferred stand-in measurement
    /// (`DeferredTextBox`), rounded — one per card per real width, or
    /// something is measuring the thread at a width it is never shown at.
    nonisolated(unsafe) public static var deferredWidths: [Int] = []
}
#endif

/// `NSViewRepresentable` wrapping the non-editable, selectable `NSTextView`.
/// Internal (not `private`) so the link-click policy on its `Coordinator` is
/// unit-testable without a rendered view.
struct SelectableTextViewRepresentable: NSViewRepresentable {
    let source: String
    let rendered: MarkdownAttributed.Rendered
    /// In-app tracker-item opener (item #115), read from the environment
    /// HERE and handed to the coordinator in `makeNSView`/`updateNSView` —
    /// an AppKit delegate can't read SwiftUI's environment itself, and a
    /// global would break per-window/per-chat routing.
    @Environment(\.openTrackerItem) private var openTrackerItem
    /// In-app conversation opener (decision #2954), handed on the same way.
    @Environment(\.openConversation) private var openConversation
    let itemID: String?
    let selectionController: MessageSelectionController?
    /// Lay out with TextKit 1 from the start (`SelectableMessageText
    /// .defersTextView`), not only when the body holds a table.
    var usesTextKit1 = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        // A bare text view (no enclosing scroll view) laid out at full
        // content height. `drawsBackground = false` lets the message-bubble
        // chrome show through; a zero `textContainerInset` (bar a code edge) keeps our own
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
        // Zero unless the message starts or ends with a code block, whose
        // box needs the room at the edge — set by `apply(_:)` below.
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // Track the container width to the view width so wrapping matches the
        // width SwiftUI proposes (and that `sizeThatFits` measures against).
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.delegate = context.coordinator
        context.coordinator.openTrackerItem = openTrackerItem
        context.coordinator.openConversation = openConversation
        // Links are clickable but the body is not editable.
        textView.isAutomaticLinkDetectionEnabled = false
        textView.displaysLinkToolTips = true
        useTextKit1IfTabled(textView)
        textView.apply(rendered)
        context.coordinator.lastApplied = rendered.attributed
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        (textView as? MessageCopyTextView)?.markdownSource = source
        context.coordinator.openTrackerItem = openTrackerItem
        context.coordinator.openConversation = openConversation
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
            if let view = textView as? MessageCopyTextView {
                view.apply(rendered)
            } else {
                textView.textStorage?.setAttributedString(rendered.attributed)
            }
            context.coordinator.lastApplied = rendered.attributed
            // Streaming replaced the storage: re-clamp and repaint the
            // cross-message span (rendering attributes die with the storage).
            if let view = textView as? MessageCopyTextView, let range = view.crossSelectionRange {
                view.setCrossSelection(range, force: true)
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
    /// Messages without tables keep today's TextKit 2 path untouched, unless
    /// the host asked for TextKit 1 (`usesTextKit1`).
    private func useTextKit1IfTabled(_ textView: NSTextView) {
        guard textView.textLayoutManager != nil, rendered.containsTable || usesTextKit1 else { return }
        _ = textView.layoutManager
    }

    /// Exact size for the proposed width. Measured via `MarkdownAttributed`'s
    /// standalone TextKit stack (a pure function of attributed string + width)
    /// rather than the live text view — the live view's `widthTracksTextView`
    /// container fights a manually-set width and yields clipped heights.
    /// Reports the content's natural width (never the full proposal) so a
    /// short message's bubble hugs its text instead of spanning the pane.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        #if DEBUG
        SelectableMessageTextProbe.measurements += 1
        #endif
        guard let width = proposal.width, width > 0, width.isFinite else {
            #if DEBUG
            SelectableMessageTextProbe.widthlessMeasurements += 1
            #endif
            return nil
        }
        return rendered.size(width: width)
    }

    /// Handles link clicks with the same policy as `MarkdownText` — the
    /// decision itself comes from `MatronItemLink.action(for:)`, which both
    /// renderers share, because `MarkdownText.handle`'s `OpenURLAction.Result`
    /// return type is only meaningful inside SwiftUI's `openURL` environment.
    /// Note that matrix/mxc URLs never carry a `.link` attribute (see
    /// `MarkdownAttributed`), so in practice only item links, http(s) and
    /// unknown schemes ever reach this delegate.
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// Set from the representable's environment on every update.
        var openTrackerItem: ((Int) -> Void)?
        /// Same, for `matron://convo/<id>` (decision #2954).
        var openConversation: ((String) -> Void)?

        /// Seam for the external opener so tests can prove a `matron://`
        /// click never reaches `NSWorkspace`.
        var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }

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
            switch MatronItemLink.action(for: url) {
            case .openTrackerItem(let number):
                // `matron://item/<n>` — opened in-app (item #115), and
                // swallowed when no host installed a handler. The scheme is
                // not registered with the OS, so it must never be handed on.
                openTrackerItem?(number)
            case .openConversation(let convoID):
                // `matron://convo/<id>` — in-app, or swallowed with no host.
                openConversation?(convoID)
            case .swallow, .openConsent:
                // matrix/mxc — swallowed until permalink / content-URI
                // handling lands; mirrors `MarkdownText.handle(url:)`. A
                // consent link belongs on an item, not in prose (#2318).
                break
            case .system(let url):
                openExternally(url)
            }
            // Return `true` either way: we've decided the outcome, so the text
            // view shouldn't also hand the URL to its default opener.
            return true
        }
    }
}
#endif
