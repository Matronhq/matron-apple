import SwiftUI
import UIKit

/// The production `TimelineRowMeasuring`: text rows through `TextRowRenderer`
/// (off-main when they hold no hosted piece), hosted rows / pieces / the
/// activity footer through `HostedSizer` with the SAME views the cells host.
final class TimelineMeasurer: TimelineRowMeasuring, @unchecked Sendable {
    @MainActor var factory: HostedRowFactory
    @MainActor private let sizer: HostedSizer

    @MainActor
    init(factory: HostedRowFactory) {
        self.factory = factory
        self.sizer = HostedSizer()
    }

    func backgroundTextRender(_ content: TextRowContent, width: CGFloat, style: TimelineTextStyle) -> TextRowRender? {
        TextRowRenderer.backgroundRender(content, width: width, style: style)
    }

    @MainActor
    func measure(_ content: TimelineRowContent, width: CGFloat, style: TimelineTextStyle) -> TimelineMeasurement {
        switch content {
        case .text(let text):
            return .text(TextRowRenderer.render(text, width: width, style: style) { piece, pieceWidth in
                self.sizer.height(of: self.factory.piece(piece), width: pieceWidth, sizeCategory: style.sizeCategory)
            })
        case .hosted(let hosted):
            return .hosted(sizer.height(of: factory.row(hosted), width: width, sizeCategory: style.sizeCategory))
        }
    }

    @MainActor
    func footerHeight(label: String, width: CGFloat, style: TimelineTextStyle) -> CGFloat {
        sizer.height(of: factory.footer(label: label), width: width, sizeCategory: style.sizeCategory)
    }
}
