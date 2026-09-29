import AppKit
import SwiftUI
import MatronChat
import MatronDesignSystem

/// Where a text row's in-app links go: `matron://item/<n>` and
/// `matron://convo/<id>`. Installed on the body's `MessageLinkRouter`.
struct MacTimelineLinkRouting {
    var openTrackerItem: ((Int) -> Void)?
    var openConversation: ((String) -> Void)?
    /// What `ConversationLinkPill` reads to title itself and to be openable
    /// at all — the table's hosting views don't inherit `MacChatView`'s
    /// environment, so it is handed over with the actions.
    var conversationLinkHost: ConversationLinkHost?
}

/// The native text row of the table timeline: bubble chrome, the message body
/// (`MessageBodyView`), the timestamp, and hosted SwiftUI for the optional
/// avatar, conversation-link pills and send-state footer. Every frame comes
/// from the `MacTextRowRender` that also sized the table row, so the two
/// cannot disagree.
///
/// Reuse identifiers: the controller dequeues `tabledIdentifier` when
/// `render.rendered.containsTable`, else `identifier`. A body switched to
/// TextKit 1 for a table can never switch back, so the two kinds must never
/// share a recycled view.
final class MacTextRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("timeline.text")
    static let tabledIdentifier = NSUserInterfaceItemIdentifier("timeline.text.tk1")
    /// `NSTextField`'s text inset from its frame on each side (its field
    /// editor's line fragment padding) — measured 2 pt by the parity test.
    static let timeLabelPadding: CGFloat = 2

    let body = MessageBodyView()

    private let bubble = BubbleChromeView()
    private let timeLabel = NSTextField(labelWithString: "")
    private var avatarHost: NSHostingView<AnyView>?
    private var pillsHost: NSHostingView<AnyView>?
    private var sendStateHost: NSHostingView<AnyView>?
    private var render: MacTextRowRender?
    private weak var selectionController: MessageSelectionController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(bubble)
        // Body and time sit ABOVE the bubble as row-level siblings, framed at
        // bubble origin + their bubble-coordinate frames: the bubble layer
        // carries a shadow, so it cannot clip, and siblings keep the text
        // out of the shadow's compositing group.
        addSubview(body)
        timeLabel.font = NSFont.preferredFont(forTextStyle: .caption2)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.lineBreakMode = .byClipping
        addSubview(timeLabel)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(render: MacTextRowRender, selectionController: MessageSelectionController?,
                   linkRouting: MacTimelineLinkRouting,
                   pills: () -> AnyView?, sendState: () -> AnyView?) {
        // No retry action: the `sendState` footer carries its own.
        self.render = render
        self.selectionController = selectionController
        let content = render.content
        body.configure(source: content.body, rendered: render.rendered, itemID: content.itemID,
                       selectionController: selectionController)
        body.router.openTrackerItem = linkRouting.openTrackerItem
        body.router.openConversation = linkRouting.openConversation
        bubble.isOwn = content.isOwn
        timeLabel.stringValue = render.timestampText

        let layout = render.layout
        avatarHost = Self.install(layout.avatarFrame == nil ? nil : content.avatarSender.map { AnyView(SenderAvatar($0)) },
                                  in: avatarHost, on: self)
        pillsHost = Self.install(layout.pillsFrame == nil ? nil : pills(), in: pillsHost, on: self)
        sendStateHost = Self.install(layout.sendStateFrame == nil ? nil : sendState(), in: sendStateHost, on: self)

        // `MacTimelineItemView` dims the whole rendered body (avatar, bubble,
        // pills) while an own message is sending; the footer stays opaque.
        let alpha: CGFloat = content.isOwn && content.sendState == .sending ? 0.7 : 1
        for view in [bubble, body, timeLabel, avatarHost, pillsHost] as [NSView?] { view?.alphaValue = alpha }

        setAccessibilityLabel("\(content.senderLabel): \(content.body)")
        needsLayout = true
    }

    /// Shows `view` in `host` (created on first use), or hides the host.
    private static func install(_ view: AnyView?, in host: NSHostingView<AnyView>?,
                                on row: NSView) -> NSHostingView<AnyView>? {
        guard let view else {
            host?.isHidden = true
            return host
        }
        if let host {
            host.rootView = view
            host.isHidden = false
            return host
        }
        let created = NSHostingView(rootView: view)
        row.addSubview(created)
        return created
    }

    override func layout() {
        super.layout()
        guard let layout = render?.layout else { return }
        let origin = layout.bubbleFrame.origin
        bubble.frame = layout.bubbleFrame
        body.frame = (layout.segmentFrames.first ?? .zero).offsetBy(dx: origin.x, dy: origin.y)
        // The label draws its text `timeLabelPadding` in from each side:
        // widen its frame by that so the TEXT lands on the layout's frame
        // (else it sat 2 pt right of SwiftUI's and its tail was clipped —
        // the frame-parity test's ink comparison).
        timeLabel.frame = layout.timestampFrame.offsetBy(dx: origin.x, dy: origin.y)
            .insetBy(dx: -Self.timeLabelPadding, dy: 0)
        if let frame = layout.avatarFrame { avatarHost?.frame = frame }
        if let frame = layout.pillsFrame { pillsHost?.frame = frame }
        if let frame = layout.sendStateFrame { sendStateHost?.frame = frame }
    }

    /// Right-clicks outside the body (the text view answers its own): "Copy"
    /// for this message, led by "Copy N Messages" when a finished
    /// cross-message selection exists — as `MessageCopyTextView.menu(for:)`.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let render else { return nil }
        let menu = NSMenu()
        if let selectionController, selectionController.hasSelection,
           let transcript = selectionController.finishedTranscript, transcript.messageCount > 0 {
            let count = transcript.messageCount
            let item = NSMenuItem(title: "Copy \(count) Message\(count == 1 ? "" : "s")",
                                  action: NSSelectorFromString("copyCrossSelection:"), keyEquivalent: "")
            item.target = body.textView
            item.representedObject = transcript.text
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let copy = NSMenuItem(title: "Copy", action: #selector(copyMessage(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = render.content.body
        menu.addItem(copy)
        return menu
    }

    @objc private func copyMessage(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        Pasteboard.copy(text)
    }

    /// The jump-landing highlight: an accent wash that fades out.
    func flash() { TimelineRowFlash.flash(in: self) }

    override func prepareForReuse() {
        super.prepareForReuse()
        TimelineRowFlash.remove(from: self)
        // The table calls this on the recycled cell only, never on its
        // subviews: the body's selection / checkmark reset must be forwarded.
        body.prepareForReuse()
        for host in [avatarHost, pillsHost, sendStateHost] {
            host?.rootView = AnyView(EmptyView())
            host?.isHidden = true
        }
        render = nil
        selectionController = nil
    }

    // MARK: Testing

    var bubbleFrameForTesting: CGRect { bubble.frame }
    var bubbleShadowPathForTesting: CGPath? { bubble.layer?.shadowPath }
    var bubbleShadowOpacityForTesting: Float? { bubble.layer?.shadowOpacity }
    var bubbleShadowColorForTesting: CGColor? { bubble.layer?.shadowColor }
    var bubbleCornerRadiusForTesting: CGFloat? { bubble.layer?.cornerRadius }
    var bubbleShadowRadiusForTesting: CGFloat? { bubble.layer?.shadowRadius }
    var bubbleShadowOffsetForTesting: CGSize? { bubble.layer?.shadowOffset }
    var hasFlashForTesting: Bool { TimelineRowFlash.isFlashing(self) }
    var flashIsTopmostForTesting: Bool { TimelineRowFlash.isTopmost(self) }
}

/// The bubble chrome: `MessageBubble`'s fill, 8 pt corners and 1 pt drop
/// shadow. Colours resolve in `updateLayer`, so they follow appearance.
private final class BubbleChromeView: NSView {
    var isOwn = false {
        didSet { if isOwn != oldValue { needsDisplay = true } }
    }

    /// The shadow colour last handed to `shadow` (it resolves per appearance).
    private var appliedShadowColor: CGColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    /// An explicit shadow path: without one, Core Animation derives the
    /// shadow from the layer's alpha in an offscreen pass per bubble, on
    /// every frame the bubble moves (every scroll frame).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateShadowPath()
    }

    override func layout() {
        super.layout()
        updateShadowPath()
    }

    private func updateShadowPath() {
        guard let layer else { return }
        let rect = CGRect(origin: .zero, size: bounds.size)
        guard rect.width > 0, rect.height > 0 else {
            layer.shadowPath = nil
            return
        }
        if let path = layer.shadowPath, path.boundingBoxOfPath == rect { return }
        // `CGPath(roundedRect:)` traps on a radius over half a side.
        layer.shadowPath = CGPath(roundedRect: rect, cornerWidth: min(layer.cornerRadius, rect.width / 2),
                                  cornerHeight: min(layer.cornerRadius, rect.height / 2), transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The shadow goes through `NSView.shadow`, never the layer's shadow
    /// properties: AppKit owns those on a layer-backed view and resets them
    /// from `shadow` (nil → opacity 0) — the layer-only shadow never drew
    /// (Wave M item 6). AppKit leaves `shadowPath` alone.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(isOwn ? Color.matronBubbleMe : Color.matronBubbleBot).cgColor
            let color = NSColor(Color.matronBubbleShadow)
            if appliedShadowColor != color.cgColor {
                appliedShadowColor = color.cgColor
                let shadow = NSShadow()
                shadow.shadowColor = color
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.shadowBlurRadius = 1
                self.shadow = shadow
            }
        }
        updateShadowPath()
    }

    // Chrome only: clicks fall through to the row (context menu).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The jump-landing flash both row kinds share: a tagged accent wash OVER
/// the row's content (behind it, the opaque bubble would hide it), faded
/// over 0.6 s after 0.4 s, removed on reuse. Clicks pass through it.
enum TimelineRowFlash {
    static let tag = 0x6A_46_4C

    private final class FlashView: NSView {
        override var tag: Int { TimelineRowFlash.tag }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor static func flash(in row: NSView) {
        remove(from: row)
        let view = FlashView(frame: row.bounds)
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        row.addSubview(view, positioned: .above, relativeTo: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak view] in
            guard let view, view.superview != nil else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.6
                view.animator().alphaValue = 0
            }, completionHandler: { [weak view] in
                view?.removeFromSuperview()
            })
        }
    }

    @MainActor static func remove(from row: NSView) {
        for view in row.subviews where view is FlashView { view.removeFromSuperview() }
    }

    @MainActor static func isFlashing(_ row: NSView) -> Bool {
        row.subviews.contains { $0 is FlashView }
    }

    /// The wash is the row's topmost subview (so it tints the bubble).
    @MainActor static func isTopmost(_ row: NSView) -> Bool {
        row.subviews.last is FlashView
    }
}
