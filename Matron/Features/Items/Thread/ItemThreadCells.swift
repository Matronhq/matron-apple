import UIKit
import SwiftUI
import MatronDesignSystem

/// Builds the SwiftUI pieces the native thread hosts, with the environment
/// a hosted view does not inherit across the UIKit boundary.
@MainActor
struct ItemThreadPieceFactory {
    var detail: ItemDetailView
    var environment: TimelineHostedEnvironment

    var router: TimelineLinkRouter {
        TimelineLinkRouter(openTrackerItem: environment.openTrackerItem,
                           openConversation: environment.openConversation,
                           openPageLink: environment.openPageLink)
    }

    func view(_ piece: ItemHostedPiece, sizeCategory: UIContentSizeCategory) -> AnyView {
        switch piece {
        case .detail(let piece):
            return AnyView(detail.showing(only: piece)
                .timelineHostedEnvironment(environment)
                .timelineDynamicTypeSize(sizeCategory))
        }
    }
}

/// Measures a hosted piece: its height at a width and the width it takes
/// there (a caption or an image hugs its content; a table fills the
/// width). One reused hosting controller; main thread only.
@MainActor
final class ItemPieceSizer {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))

    init() {
        host.sizingOptions = []
        host.view.backgroundColor = .clear
    }

    func size(of view: AnyView, maxWidth: CGFloat) -> CGSize {
        host.rootView = AnyView(view.fixedSize(horizontal: false, vertical: true))
        let size = host.sizeThatFits(in: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: min(ceil(size.width), maxWidth), height: ceil(size.height))
    }
}

/// A card's ground: the rounded rectangle and shadow its pieces sit on. A
/// cell of its own, under the card's pieces, so a card several screens tall
/// is still one cheap layer and its pieces come and go as they scroll.
final class ItemCardGroundCell: UICollectionViewCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        contentView.layer.cornerRadius = 10
        contentView.layer.shadowColor = UIColor.matronBubbleShadow.cgColor
        contentView.layer.shadowOpacity = 1
        contentView.layer.shadowRadius = 2
        contentView.layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(mine: Bool) {
        contentView.backgroundColor = mine ? .matronBubbleMe : .matronBubbleBot
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.layer.shadowPath = UIBezierPath(roundedRect: contentView.bounds, cornerRadius: 10).cgPath
    }
}

/// A run of a card's prose: native, selectable text whose links open in
/// the app.
final class ItemTextCell: UICollectionViewCell, UITextViewDelegate {
    private let textView = TimelineTextViewFactory.make()
    private var applied: NSAttributedString?
    private var router = TimelineLinkRouter()

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.delegate = self
        contentView.addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(text: NSAttributedString, router: TimelineLinkRouter) {
        self.router = router
        if applied !== text {
            textView.attributedText = text
            applied = text
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = contentView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        textView.resignFirstResponder()
        textView.selectedTextRange = nil
        router = TimelineLinkRouter()
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                  defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content, !TimelineLinkRouter.isSystemLink(url) else { return defaultAction }
        let router = router
        return UIAction { _ in router.route(url) }
    }

    var textViewForTesting: UITextView { textView }
}

/// A fenced code block of a card: the chat timeline's own.
final class ItemCodeCell: UICollectionViewCell {
    private let code = CodeBlockSegmentView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(code)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(language: String?, code source: String, style: TimelineTextStyle) {
        code.configure(language: language, code: source, style: style)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        code.frame = contentView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        code.clearSelectionForReuse()
    }
}

/// A table of a card.
final class ItemTableCell: UICollectionViewCell {
    private let table = ItemTableView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(table)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(layout: ItemTableLayout, router: TimelineLinkRouter) {
        table.configure(layout)
        table.onOpenLink = { router.route($0) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        table.frame = contentView.bounds
    }
}
