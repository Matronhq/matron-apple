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
}
