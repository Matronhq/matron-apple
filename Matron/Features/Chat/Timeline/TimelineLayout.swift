import UIKit

@MainActor
protocol TimelineLayoutSource: AnyObject {
    var scrollModel: TimelineScrollModel { get }
}

/// A read-only projection of `TimelineScrollModel`: exact frames, exact
/// content size, no estimates, no self-sizing. The activity footer is a
/// section-footer supplementary outside the row space.
final class TimelineLayout: UICollectionViewLayout {
    static let footerKind = UICollectionView.elementKindSectionFooter
    static let footerIndexPath = IndexPath(item: 0, section: 0)

    weak var source: TimelineLayoutSource?

    private var cellAttributes: [UICollectionViewLayoutAttributes] = []
    private var footerAttributes: UICollectionViewLayoutAttributes?
    private var contentSize: CGSize = .zero

    override func prepare() {
        super.prepare()
        guard let collectionView, let model = source?.scrollModel else {
            cellAttributes = []
            footerAttributes = nil
            contentSize = .zero
            return
        }
        let width = collectionView.bounds.width
        cellAttributes = model.rows.indices.map { index in
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attributes.frame = CGRect(x: 0, y: model.rowMinY(at: index), width: width, height: model.rows[index].height)
            return attributes
        }
        if model.footerHeight > 0 {
            let footer = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.footerKind,
                                                          with: Self.footerIndexPath)
            footer.frame = CGRect(x: 0, y: model.footerMinY, width: width, height: model.footerHeight)
            footerAttributes = footer
        } else {
            footerAttributes = nil
        }
        contentSize = CGSize(width: width, height: model.contentHeight)
    }

    override var collectionViewContentSize: CGSize { contentSize }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var result = cellAttributes.filter { $0.frame.intersects(rect) }
        if let footerAttributes, footerAttributes.frame.intersects(rect) { result.append(footerAttributes) }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        cellAttributes.indices.contains(indexPath.item) ? cellAttributes[indexPath.item] : nil
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: String,
                                                       at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        elementKind == Self.footerKind ? footerAttributes : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }

    /// UIKit asks this after batch updates; the answer is the model's.
    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        guard let model = source?.scrollModel else { return proposedContentOffset }
        return CGPoint(x: 0, y: model.contentOffsetY)
    }
}
