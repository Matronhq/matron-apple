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

    let body = MessageBodyView()

    private let bubble = BubbleChromeView()
    private let timeLabel = NSTextField(labelWithString: "")
    private var avatarHost: NSHostingView<AnyView>?
    private var pillsHost: NSHostingView<AnyView>?
    private var sendStateHost: NSHostingView<AnyView>?
    private var render: MacTextRowRender?
    private weak var selectionController: MessageSelectionController?
    /// Kept for the row's owner: the send-state footer the `sendState`
    /// closure builds carries its own retry action.
    private var onRetry: ((String) -> Void)?

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
                   linkRouting: MacTimelineLinkRouting, onRetry: @escaping (String) -> Void,
                   pills: () -> AnyView?, sendState: () -> AnyView?) {
        self.render = render
        self.selectionController = selectionController
        self.onRetry = onRetry
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
        timeLabel.frame = layout.timestampFrame.offsetBy(dx: origin.x, dy: origin.y)
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
        onRetry = nil
    }

    // MARK: Testing

    var bubbleFrameForTesting: CGRect { bubble.frame }
    var hasFlashForTesting: Bool { TimelineRowFlash.isFlashing(self) }
}

/// The bubble chrome: `MessageBubble`'s fill, 8 pt corners and 1 pt drop
/// shadow. Colours resolve in `updateLayer`, so they follow appearance.
private final class BubbleChromeView: NSView {
    var isOwn = false {
        didSet { if isOwn != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.shadowRadius = 1
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.shadowOpacity = 1
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(isOwn ? Color.matronBubbleMe : Color.matronBubbleBot).cgColor
            layer?.shadowColor = NSColor(Color.matronBubbleShadow).cgColor
        }
    }

    // Chrome only: clicks fall through to the row (context menu).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The jump-landing flash both row kinds share: a tagged accent wash behind
/// the row's content, faded over 0.6 s after 0.4 s, removed on reuse.
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
        row.addSubview(view, positioned: .below, relativeTo: nil)
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
}
