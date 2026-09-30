#if os(macOS)
import AppKit

/// AppKit twin of `SelectableMessageText`: the message body text view plus its
/// code-block copy buttons, for hosts that lay out manually (the table timeline).
///
/// Everything that decides how a body looks or behaves is shared with the
/// SwiftUI path rather than copied: the text-view configuration
/// (`configureTextView`), the TextKit 1 opt-in for tables
/// (`useTextKit1IfTabled`), the link policy (`MessageLinkRouter`) and the
/// geometry (`MarkdownAttributed.Rendered`). The host sizes this view with
/// `rendered.size(width:)`, exactly as SwiftUI does via `sizeThatFits`.
///
/// Flipped, because `codeBlockFrames` are top-left origin.
public final class MessageBodyView: NSView {
    /// The link policy. The host installs `openTrackerItem` /
    /// `openConversation`; `openExternally` defaults to `NSWorkspace`.
    public let router = MessageLinkRouter()

    /// The timeline item this body shows, or nil after `prepareForReuse`.
    public private(set) var itemID: String?

    /// For hit tests and menus.
    public var textView: NSTextView { bodyTextView }

    private let bodyTextView = MessageCopyTextView()
    private var rendered: MarkdownAttributed.Rendered?
    /// The exact `NSAttributedString` instance last written into the storage:
    /// the same O(1) "content is unchanged" test as the SwiftUI
    /// representable's `Coordinator.lastApplied`.
    private var lastApplied: NSAttributedString?
    private var codeButtons: [CodeCopyButton] = []

    /// Whether code blocks get their copy buttons. A host turns them off for
    /// a body that is still streaming: finding the blocks costs a TextKit 1
    /// layout of the whole body on every commit, and the first button loads
    /// its SF Symbol mid-stream. Turning them back on (a reused view showing
    /// a finished message) brings them back on the next layout.
    public var showsCodeCopyButtons = true {
        didSet { if showsCodeCopyButtons != oldValue { needsLayout = true } }
    }

    /// Whether the host shows a body that is still streaming: each commit
    /// then re-renders a longer version of the same message. While set, a
    /// new render for the same item replaces the storage only from the first
    /// paragraph it changed (`StreamingTextEdit`), so TextKit 2 keeps the
    /// layout fragments (and their layers) of every paragraph before it —
    /// a full `setAttributedString` dropped and rebuilt all of them on every
    /// commit. Off (the default) always replaces the whole storage.
    public var isStreaming = false

    public init() {
        super.init(frame: .zero)
        Self.configureTextView(bodyTextView, router: router)
        addSubview(bodyTextView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    /// Sets content; no-op storage write when `rendered` is the instance
    /// already shown (streaming re-emits). Re-applies a live cross-selection.
    public func configure(source: String, rendered: MarkdownAttributed.Rendered,
                          itemID: String?, selectionController: MessageSelectionController?) {
        bodyTextView.markdownSource = source
        Self.useTextKit1IfTabled(bodyTextView, rendered: rendered)
        // Pointer equality, as in `SelectableTextViewRepresentable.updateNSView`:
        // `Rendered` is memoised per source, so the same instance means the
        // same content and the storage (and any selection in it) is kept.
        let storageChanges = lastApplied !== rendered.attributed
        if storageChanges {
            writeStorage(rendered, itemID: itemID)
            lastApplied = rendered.attributed
        }
        // AFTER the storage: a new id registers with the selection, which
        // sizes a mid-selection span from `storageLength` — a recycled view
        // must report the NEW message's length, not the last one's.
        if bodyTextView.selectionItemID != itemID { bodyTextView.selectionItemID = itemID }
        if bodyTextView.selectionController !== selectionController {
            bodyTextView.selectionController = selectionController
        }
        // After the id too: the controller re-sizes the span under the id
        // it belongs to.
        if storageChanges { bodyTextView.crossSelectionStorageDidChange() }
        self.itemID = itemID
        if self.rendered !== rendered {
            self.rendered = rendered
            needsLayout = true
        }
    }

    /// Writes `rendered` into the storage: incrementally for the next render
    /// of the same streaming item (`isStreaming`), else in full. A table on
    /// either side always goes in full — `NSTextBlock`s compare by identity,
    /// and a TextKit 2 view cannot lay a table out in place.
    private func writeStorage(_ rendered: MarkdownAttributed.Rendered, itemID: String?) {
        guard let storage = bodyTextView.textStorage else { return }
        if isStreaming, let itemID, itemID == self.itemID,
           let previous = self.rendered, previous.attributed === lastApplied,
           !previous.containsTable, !rendered.containsTable {
            StreamingTextEdit.apply(from: previous.attributed, to: rendered.attributed, in: storage)
            bodyTextView.applyCodeGeometry(of: rendered)
        } else {
            bodyTextView.apply(rendered)
        }
    }

    /// Reuse: clears text selection, cancels a code-copy checkmark, drops the id.
    /// (Overrides `NSView`'s, so a table reusing this view calls it too.)
    public override func prepareForReuse() {
        super.prepareForReuse()
        bodyTextView.setSelectedRange(NSRange(location: 0, length: 0))
        for button in codeButtons { button.resetFeedback() }
        // Dropping the id also unregisters the text view from the
        // cross-message selection and clears any span painted in it.
        bodyTextView.selectionItemID = nil
        itemID = nil
        // A host's per-row flags start over at their defaults.
        isStreaming = false
        showsCodeCopyButtons = true
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    public override func layout() {
        super.layout()
        bodyTextView.frame = bounds
        let frames = showsCodeCopyButtons ? rendered?.codeBlockFrames(width: bounds.width) ?? [] : []
        while codeButtons.count > frames.count { codeButtons.removeLast().removeFromSuperview() }
        while codeButtons.count < frames.count {
            let button = CodeCopyButton()
            addSubview(button)
            codeButtons.append(button)
        }
        let side = CodeCopyButton.side
        for (button, frame) in zip(codeButtons, frames) {
            button.code = frame.code
            // The SwiftUI overlay's centre rule: just past the block's
            // top-right corner when the block is narrow; clamped inside the
            // message bounds for full-width blocks.
            let center = CGPoint(x: min(frame.rect.maxX + 12, bounds.width - 12), y: frame.rect.minY + 12)
            button.frame = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        }
    }

    /// Same text-view configuration SelectableMessageText uses — one source.
    ///
    /// A bare text view (no enclosing scroll view) laid out at full content
    /// height. `drawsBackground = false` lets the message-bubble chrome show
    /// through; a zero `textContainerInset` (bar a code edge, which
    /// `MessageCopyTextView.apply(_:)` sets per message) keeps our own
    /// paragraph metrics authoritative. `MessageCopyTextView` layers markdown-preserving copy on
    /// `MouseTrackingRescueTextView` — the rescue base matters because message
    /// bubbles are exactly where the 2026-08-02 tracking-loop wedge hit (see
    /// that class's doc).
    static func configureTextView(_ textView: MessageCopyTextView, router: MessageLinkRouter) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // Track the container width to the view width so wrapping matches the
        // width the host lays the view out at (and that `size(width:)`
        // measures against).
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.delegate = router
        // Links are clickable but the body is not editable.
        textView.isAutomaticLinkDetectionEnabled = false
        textView.displaysLinkToolTips = true
        // No text checking at all: the body is never edited, yet TextKit 2
        // viewport layout still asks the checking controller about every
        // range it lays out, so a recycled view spell-checked and searched
        // text replacements for each new message on the background checking
        // queue (~6% of process CPU while scrolling the table timeline).
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        // Last: each flag above toggles its bit in this mask.
        textView.enabledTextCheckingTypes = 0
    }

    /// Switches a table-bearing text view to TextKit 1 up front. Touching
    /// `layoutManager` is the documented opt-out from TextKit 2, and it must
    /// happen before the view lays out: left to itself AppKit only falls back
    /// once the view is in a window, and the re-size that follows keeps the
    /// view's top edge — shifting its origin off the frame the host gave it
    /// (body drawn above the bubble, first rows clipped). TextKit 2 cannot lay
    /// out `NSTextTable` at all, so a windowless host (snapshot tests) would
    /// otherwise render a table's cells as loose stacked lines.
    /// Messages without tables keep today's TextKit 2 path untouched.
    static func useTextKit1IfTabled(_ textView: NSTextView, rendered: MarkdownAttributed.Rendered) {
        guard textView.textLayoutManager != nil, rendered.containsTable else { return }
        _ = textView.layoutManager
    }
}

/// AppKit twin of `SelectableMessageText`'s `CodeBlockCopyButton`: copies the
/// block's bare code (no fences) to the general pasteboard and flashes a
/// checkmark for 1.2 s. 20×20 — the SwiftUI button's 12 pt glyph frame plus
/// 4 pt padding each side.
private final class CodeCopyButton: NSButton {
    static let side: CGFloat = 20
    private static let feedbackDuration: TimeInterval = 1.2

    var code = ""
    /// Cancelled on re-click so a second copy gets a full 1.2 s of checkmark,
    /// not the tail of the first click's timer; and on reuse.
    private var resetWork: DispatchWorkItem?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        bezelStyle = .accessoryBarAction
        imagePosition = .imageOnly
        title = ""
        toolTip = "Copy code"
        setAccessibilityLabel("Copy code")
        target = self
        action = #selector(copyCode(_:))
        showCopied(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func copyCode(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        showCopied(true)
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showCopied(false) }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.feedbackDuration, execute: work)
    }

    /// Back to the copy glyph now, cancelling a pending checkmark reset.
    func resetFeedback() {
        resetWork?.cancel()
        resetWork = nil
        showCopied(false)
    }

    private func showCopied(_ copied: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        image = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc",
                        accessibilityDescription: "Copy code")?
            .withSymbolConfiguration(config)
        contentTintColor = copied ? .systemGreen : .secondaryLabelColor
    }
}
#endif
