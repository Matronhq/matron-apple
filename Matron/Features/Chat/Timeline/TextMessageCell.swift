import UIKit
import SwiftUI
import MatronDesignSystem

/// A text message row: bubble chrome, one view per markdown segment
/// (TextKit 2 text / code block / hosted table), the time in UIKit, the
/// sender avatar, the pill row (hosted) and the own-message send state —
/// all placed at the frames `TextRowRenderer` measured, never self-sized.
final class TextMessageCell: UICollectionViewCell, UITextViewDelegate {
    private enum SegmentKind: Equatable { case text, code, table }

    private let bubble = UIView()
    private let timestampLabel = UILabel()
    private let avatarView = SenderAvatarView()
    private let sendStateView = SendStateView()
    private var segmentViews: [UIView] = []
    private var segmentKinds: [SegmentKind] = []
    /// The exact string instance each text view shows — a reconfigure with
    /// the same (memoised) string skips the TextKit relayout.
    private var appliedTexts: [NSAttributedString?] = []
    /// Parallel to `segmentViews`: the hosting controller behind a `.table`
    /// entry, nil for `.text` / `.code`. `UIHostingConfiguration`'s content
    /// view never installs its SwiftUI child until it is part of a window
    /// (confirmed empirically: zero subviews off-window), so a live-rendered
    /// hosted piece uses a plain `UIHostingController` instead — the same
    /// technique `HostedSizer` and `CodeBlockSegmentView`'s siblings already
    /// use elsewhere in this timeline, and it renders off-window too.
    private var segmentHosts: [UIHostingController<AnyView>?] = []
    private var pillsHost: UIHostingController<AnyView>?
    private(set) var render: TextRowRender?
    private var router = TimelineLinkRouter()

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.layer.cornerRadius = TextBubbleGeometry.cornerRadius
        bubble.layer.shadowColor = UIColor.matronBubbleShadow.cgColor
        bubble.layer.shadowOpacity = 1
        bubble.layer.shadowRadius = 1
        bubble.layer.shadowOffset = CGSize(width: 0, height: 1)
        timestampLabel.textColor = .secondaryLabel
        timestampLabel.lineBreakMode = .byClipping
        timestampLabel.isAccessibilityElement = false
        bubble.addSubview(timestampLabel)
        contentView.addSubview(avatarView)
        contentView.addSubview(bubble)
        contentView.addSubview(sendStateView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(render: TextRowRender, factory: HostedRowFactory, onRetry: @escaping (String) -> Void) {
        self.render = render
        router = factory.router
        let content = render.content
        bubble.backgroundColor = content.isOwn ? .matronBubbleMe : .matronBubbleBot

        let kinds = render.segments.map(Self.kind)
        if kinds != segmentKinds { rebuildSegmentViews(kinds) }
        for (index, segment) in render.segments.enumerated() {
            switch segment {
            case .text(let text):
                guard let textView = segmentViews[index] as? UITextView else { continue }
                if appliedTexts[index] !== text {
                    textView.attributedText = text
                    appliedTexts[index] = text
                }
                textView.accessibilityLabel = content.senderLabel
            case .code(let language, let code):
                (segmentViews[index] as? CodeBlockSegmentView)?.configure(language: language, code: code,
                                                                           style: render.style)
            case .table(let table):
                segmentHosts[index]?.rootView =
                    AnyView(factory.piece(.table(table), sizeCategory: render.style.sizeCategory))
            }
        }

        timestampLabel.font = render.style.timestampFont
        timestampLabel.text = render.timestampText
        // `.opacity(0.7)` on the whole rendered body while sending.
        let alpha: CGFloat = content.sendState == .sending ? 0.7 : 1
        bubble.alpha = alpha
        if let sender = content.avatarSender, !content.isOwn { avatarView.configure(name: sender) }
        sendStateView.configure(state: SendStateGlyph.from(content.sendState), font: render.style.timestampFont) {
            onRetry(content.itemID)
        }

        if content.pills.isEmpty {
            pillsHost?.view.isHidden = true
        } else {
            let host: UIHostingController<AnyView>
            if let pillsHost {
                host = pillsHost
            } else {
                host = UIHostingController(rootView: AnyView(EmptyView()))
                host.view.backgroundColor = .clear
                contentView.addSubview(host.view)
                pillsHost = host
            }
            host.rootView = AnyView(factory.piece(.pills(content), sizeCategory: render.style.sizeCategory))
            host.view.isHidden = false
            host.view.alpha = alpha
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout = render?.layout else { return }
        bubble.frame = layout.bubbleFrame
        bubble.layer.shadowPath = UIBezierPath(roundedRect: bubble.bounds,
                                               cornerRadius: TextBubbleGeometry.cornerRadius).cgPath
        for (view, frame) in zip(segmentViews, layout.segmentFrames) { view.frame = frame }
        timestampLabel.frame = layout.timestampFrame
        avatarView.isHidden = layout.avatarFrame == nil
        if let frame = layout.avatarFrame { avatarView.frame = frame }
        if let frame = layout.pillsFrame { pillsHost?.view.frame = frame }
        if let frame = layout.sendStateFrame { sendStateView.frame = frame }
    }

    private static func kind(_ segment: MarkdownSegment) -> SegmentKind {
        switch segment {
        case .text: return .text
        case .code: return .code
        case .table: return .table
        }
    }

    private func rebuildSegmentViews(_ kinds: [SegmentKind]) {
        segmentViews.forEach { $0.removeFromSuperview() }
        segmentHosts = []
        segmentViews = kinds.map { kind -> UIView in
            switch kind {
            case .text:
                let view = TimelineTextViewFactory.make()
                view.delegate = self
                segmentHosts.append(nil)
                return view
            case .code:
                segmentHosts.append(nil)
                return CodeBlockSegmentView()
            case .table:
                let host = UIHostingController(rootView: AnyView(EmptyView()))
                host.view.backgroundColor = .clear
                segmentHosts.append(host)
                return host.view
            }
        }
        segmentViews.forEach { bubble.addSubview($0) }
        segmentKinds = kinds
        appliedTexts = Array(repeating: nil, count: kinds.count)
    }

    // MARK: Links

    enum LinkDecision: Equatable {
        /// http(s) and other OS-handled schemes: UIKit's default action.
        case system
        /// Item / conversation links (in-app) and swallowed links.
        case inApp
    }

    static func linkDecision(for url: URL) -> LinkDecision {
        TimelineLinkRouter.isSystemLink(url) ? .system : .inApp
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                  defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content else { return defaultAction }
        switch Self.linkDecision(for: url) {
        case .system:
            return defaultAction
        case .inApp:
            let router = router
            return UIAction { _ in router.route(url) }
        }
    }

    // MARK: Test seams

    var segmentViewsForTesting: [UIView] { segmentViews }
    var bubbleForTesting: UIView { bubble }
    var sendStateForTesting: SendStateView { sendStateView }
}
