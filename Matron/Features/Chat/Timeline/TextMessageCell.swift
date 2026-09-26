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
    /// The table each `.table` segment last configured — skips re-diffing
    /// `Grid` on every frame while a row above an unrelated streaming
    /// placeholder keeps reconfiguring. `MarkdownTable` is a plain
    /// `Equatable` value, not identity-based like `appliedTexts`.
    private var appliedTables: [MarkdownTable?] = []
    /// Hosted through `UIHostingConfiguration`, not a bare
    /// `UIHostingController`: a placeholder content view created with
    /// `UIHostingConfiguration { EmptyView() }` and later reconfigured with
    /// a DIFFERENT root `Content` type (e.g. `AnyView`) traps — the
    /// placeholder below matches the type used at real-content time. Safe
    /// area was a real worry (a pills row spans the full row width along
    /// the row's bottom edge, i.e. exactly where a home indicator or
    /// landscape notch inset lives) but is a non-issue in practice:
    /// `UIHostingConfiguration`'s content view reports the ambient
    /// `safeAreaInsets` it inherits (confirmed with a 200pt bottom inset in
    /// `TextMessageCellTests`) yet never lets it shift or clip the rendered
    /// SwiftUI content — unlike a bare `UIHostingController.view`, which
    /// does need `safeAreaRegions = []` (see `HostedSizer`).
    private var pillsView: (UIView & UIContentView)?
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
                guard appliedTables[index] != table else { continue }
                (segmentViews[index] as? (UIView & UIContentView))?.configuration =
                    UIHostingConfiguration { factory.piece(.table(table), sizeCategory: render.style.sizeCategory) }
                        .margins(.all, 0)
                appliedTables[index] = table
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
            pillsView?.isHidden = true
            pillsView?.configuration = UIHostingConfiguration { AnyView(EmptyView()) }.margins(.all, 0)
        } else {
            let configuration = UIHostingConfiguration {
                factory.piece(.pills(content), sizeCategory: render.style.sizeCategory)
            }.margins(.all, 0)
            if let pillsView {
                pillsView.configuration = configuration
            } else {
                let view = configuration.makeContentView()
                contentView.addSubview(view)
                pillsView = view
            }
            pillsView?.isHidden = false
            pillsView?.alpha = alpha
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
        if let frame = layout.pillsFrame { pillsView?.frame = frame }
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
        segmentViews = kinds.map { kind -> UIView in
            switch kind {
            case .text:
                let view = TimelineTextViewFactory.make()
                view.delegate = self
                return view
            case .code:
                return CodeBlockSegmentView()
            case .table:
                return UIHostingConfiguration { AnyView(EmptyView()) }.margins(.all, 0).makeContentView()
            }
        }
        segmentViews.forEach { bubble.addSubview($0) }
        segmentKinds = kinds
        appliedTexts = Array(repeating: nil, count: kinds.count)
        appliedTables = Array(repeating: nil, count: kinds.count)
    }

    /// A recycled cell must not leak the previous row's identity: dismiss
    /// any in-progress text selection, drop the closures a stale `onRetry`
    /// / `router` would otherwise still capture, and empty every hosted
    /// piece's content (which itself holds the previous `HostedRowFactory`,
    /// and through it the `ChatViewModel`) rather than leaving it configured
    /// but hidden until the next `configure(render:factory:onRetry:)`.
    override func prepareForReuse() {
        super.prepareForReuse()
        for view in segmentViews {
            guard let textView = view as? UITextView else { continue }
            textView.resignFirstResponder()
            textView.selectedTextRange = nil
        }
        render = nil
        router = TimelineLinkRouter()
        sendStateView.configure(state: .sent, font: .preferredFont(forTextStyle: .caption2), onRetry: {})
        let emptyConfiguration = UIHostingConfiguration { AnyView(EmptyView()) }.margins(.all, 0)
        for (view, kind) in zip(segmentViews, segmentKinds) where kind == .table {
            (view as? (UIView & UIContentView))?.configuration = emptyConfiguration
        }
        pillsView?.configuration = emptyConfiguration
        appliedTexts = Array(repeating: nil, count: appliedTexts.count)
        appliedTables = Array(repeating: nil, count: appliedTables.count)
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
