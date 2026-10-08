import XCTest
import UIKit
@testable import Matron

@MainActor
final class TimelineLayoutTests: XCTestCase {
    final class Source: NSObject, TimelineLayoutSource, UICollectionViewDataSource {
        var scrollModel = TimelineScrollModel()
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            scrollModel.rows.count
        }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        }
        func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                            at indexPath: IndexPath) -> UICollectionReusableView {
            collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "footer", for: indexPath)
        }
    }

    private func make(rows: [TimelineScrollModel.Row], footer: CGFloat = 0, viewport: CGFloat = 300)
        -> (UICollectionView, TimelineLayout, Source) {
        let source = Source()
        source.scrollModel.setViewportHeight(viewport)
        source.scrollModel.replaceRows(rows, footerHeight: footer)
        let layout = TimelineLayout()
        layout.source = source
        let view = UICollectionView(frame: CGRect(x: 0, y: 0, width: 393, height: viewport), collectionViewLayout: layout)
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        view.register(UICollectionReusableView.self, forSupplementaryViewOfKind: TimelineLayout.footerKind,
                      withReuseIdentifier: "footer")
        view.dataSource = source
        view.layoutIfNeeded()
        return (view, layout, source)
    }

    func test_cellFrames_comeFromTheModel() {
        let (_, layout, source) = make(rows: [.init(id: "a", height: 100), .init(id: "b", height: 50)])
        XCTAssertEqual(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame,
                       CGRect(x: 0, y: source.scrollModel.rowMinY(at: 0), width: 393, height: 100))
        XCTAssertEqual(layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame,
                       CGRect(x: 0, y: source.scrollModel.rowMinY(at: 1), width: 393, height: 50))
    }

    func test_contentSize_isTheModelsContentHeight() {
        let (view, _, source) = make(rows: (0..<10).map { .init(id: "r\($0)", height: 100) })
        XCTAssertEqual(view.contentSize, CGSize(width: 393, height: source.scrollModel.contentHeight))
    }

    func test_footer_isASupplementaryBelowTheRows() {
        let (_, layout, source) = make(rows: [.init(id: "a", height: 100)], footer: 40)
        let footer = layout.layoutAttributesForSupplementaryView(ofKind: TimelineLayout.footerKind,
                                                                 at: TimelineLayout.footerIndexPath)
        XCTAssertEqual(footer?.frame, CGRect(x: 0, y: source.scrollModel.footerMinY, width: 393, height: 40))
    }

    func test_targetContentOffset_isTheModelsDecision() {
        let (_, layout, source) = make(rows: (0..<10).map { .init(id: "r\($0)", height: 100) })
        XCTAssertEqual(layout.targetContentOffset(forProposedContentOffset: CGPoint(x: 0, y: 3)),
                       CGPoint(x: 0, y: source.scrollModel.contentOffsetY))
    }

    func test_elementsInRect_filtersByIntersection() {
        let (_, layout, _) = make(rows: (0..<10).map { .init(id: "r\($0)", height: 100) })
        let items = layout.layoutAttributesForElements(in: CGRect(x: 0, y: 0, width: 393, height: 200)) ?? []
        XCTAssertEqual(items.map(\.indexPath.item), [0, 1])
    }

    // MARK: - Fix round 1: model/data-source desync

    final class DesyncSource: NSObject, TimelineLayoutSource, UICollectionViewDataSource {
        var scrollModel = TimelineScrollModel()
        var itemCountOverride: Int?
        var sectionCountOverride: Int = 1

        func numberOfSections(in collectionView: UICollectionView) -> Int { sectionCountOverride }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            itemCountOverride ?? scrollModel.rows.count
        }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        }
        func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                            at indexPath: IndexPath) -> UICollectionReusableView {
            collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "footer", for: indexPath)
        }
    }

    private func makeDesync(rows: [TimelineScrollModel.Row], itemCount: Int?, sections: Int = 1,
                             footer: CGFloat = 0, viewport: CGFloat = 300)
        -> (UICollectionView, TimelineLayout, DesyncSource) {
        let source = DesyncSource()
        source.scrollModel.setViewportHeight(viewport)
        source.scrollModel.replaceRows(rows, footerHeight: footer)
        source.itemCountOverride = itemCount
        source.sectionCountOverride = sections
        let layout = TimelineLayout()
        layout.source = source
        let view = UICollectionView(frame: CGRect(x: 0, y: 0, width: 393, height: viewport), collectionViewLayout: layout)
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        view.register(UICollectionReusableView.self, forSupplementaryViewOfKind: TimelineLayout.footerKind,
                      withReuseIdentifier: "footer")
        view.dataSource = source
        view.layoutIfNeeded()
        return (view, layout, source)
    }

    func test_prepare_clampsToDataSourceItemCount_whenModelHasMoreRowsThanTheSnapshot() {
        let (_, layout, _) = makeDesync(rows: (0..<5).map { .init(id: "r\($0)", height: 100) }, itemCount: 2)
        XCTAssertNotNil(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        XCTAssertNotNil(layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)))
        XCTAssertNil(layout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0)))
    }

    /// Final review minor 8: a desync leaves one breadcrumb per distinct
    /// mismatch (counted here), not one per `prepare()`.
    func test_desync_isCountedOncePerDistinctMismatch() {
        let (view, layout, _) = makeDesync(rows: (0..<5).map { .init(id: "r\($0)", height: 100) }, itemCount: 2)
        XCTAssertEqual(layout.desyncCount, 1)
        layout.invalidateLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(layout.desyncCount, 1, "same mismatch again: no new breadcrumb")
    }

    func test_inSync_countsNoDesync() {
        let (_, layout, _) = makeDesync(rows: (0..<5).map { .init(id: "r\($0)", height: 100) }, itemCount: nil)
        XCTAssertEqual(layout.desyncCount, 0)
    }

    func test_footer_isNil_whenCollectionViewHasZeroSections() {
        let (_, layout, _) = makeDesync(rows: [.init(id: "a", height: 100)], itemCount: nil, sections: 0, footer: 40)
        XCTAssertNil(layout.layoutAttributesForSupplementaryView(ofKind: TimelineLayout.footerKind,
                                                                 at: TimelineLayout.footerIndexPath))
    }

    // MARK: - Fix round 1: invalidate on width change only

    func test_shouldInvalidateLayout_falseForScrollOnlyChange() {
        let (view, layout, _) = make(rows: (0..<10).map { .init(id: "r\($0)", height: 100) })
        var bounds = view.bounds
        bounds.origin.y += 50
        XCTAssertFalse(layout.shouldInvalidateLayout(forBoundsChange: bounds))
    }

    func test_shouldInvalidateLayout_falseForHeightOnlyChange() {
        let (view, layout, _) = make(rows: (0..<10).map { .init(id: "r\($0)", height: 100) })
        var bounds = view.bounds
        bounds.size.height += 100
        XCTAssertFalse(layout.shouldInvalidateLayout(forBoundsChange: bounds))
    }

    func test_shouldInvalidateLayout_trueForWidthChange() {
        let (view, layout, _) = make(rows: (0..<10).map { .init(id: "r\($0)", height: 100) })
        var bounds = view.bounds
        bounds.size.width += 50
        XCTAssertTrue(layout.shouldInvalidateLayout(forBoundsChange: bounds))
    }

    // MARK: - Fix round 1: optional coverage

    func test_elementsInRect_isEmpty_outsideContent() {
        let (_, layout, _) = make(rows: (0..<10).map { .init(id: "r\($0)", height: 100) })
        let items = layout.layoutAttributesForElements(in: CGRect(x: 0, y: 5000, width: 393, height: 100)) ?? []
        XCTAssertTrue(items.isEmpty)
    }

    func test_layoutAttributesForItem_isNil_outOfRange() {
        let (_, layout, _) = make(rows: [.init(id: "a", height: 100)])
        XCTAssertNil(layout.layoutAttributesForItem(at: IndexPath(item: 5, section: 0)))
    }
}
