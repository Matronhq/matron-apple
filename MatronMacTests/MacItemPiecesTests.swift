#if os(macOS)
import XCTest
import SwiftUI
import MatronDesignSystem
import MatronModels
@testable import MatronMac

@MainActor
final class MacItemPiecesTests: XCTestCase {
    func test_sizer_measuresAFixedViewExactly() {
        let size = MacItemPieceSizer().size(of: AnyView(Color.red.frame(width: 200, height: 37)), maxWidth: 400)
        XCTAssertEqual(size.width, 200, accuracy: 0.5)
        XCTAssertEqual(size.height, 37, accuracy: 0.5)
    }

    func test_sizer_wrapsTextToTheWidth() {
        let sizer = MacItemPieceSizer()
        let text = AnyView(Text(String(repeating: "word ", count: 80)))
        let narrow = sizer.size(of: text, maxWidth: 200)
        let wide = sizer.size(of: text, maxWidth: 600)
        XCTAssertLessThanOrEqual(narrow.width, 200)
        XCTAssertGreaterThan(narrow.height, wide.height)
    }

    func test_captionPiece_isALineHuggingItsText() {
        let factory = MacItemPieceFactory(detail: Self.detail(MacItemThreadFixtures.model(comments: 1)),
                                          environment: MacItemThreadEnvironment(),
                                          selection: MessageSelectionController())
        let size = MacItemPieceSizer().size(of: factory.view(.caption(.comment("c0"))), maxWidth: 400)
        XCTAssertGreaterThanOrEqual(size.height, 14)
        XCTAssertLessThan(size.height, 40)
        XCTAssertLessThan(size.width, 400)
    }

    static func detail(_ model: ItemDetailView.Model) -> ItemDetailView {
        ItemDetailView(model: model, draft: ItemReplyDraft(get: { "" }, set: { _ in }), image: { _ in nil },
                       onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                       onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {})
    }
}
#endif
