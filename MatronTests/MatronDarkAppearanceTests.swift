import XCTest
import SwiftUI
import UIKit
@testable import Matron
import MatronDesignSystem

/// Whether the soft dark palette reaches what SwiftUI draws: rendered and
/// sampled, because replacing a colour only matters if `List` reads it.
@MainActor
final class MatronDarkAppearanceTests: XCTestCase {
    private let dark = UITraitCollection(userInterfaceStyle: .dark)
    private let light = UITraitCollection(userInterfaceStyle: .light)

    override func setUp() {
        super.setUp()
        MatronDarkAppearance.install()
    }

    private func components(_ color: UIColor) -> (Double, Double, Double) {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return ((r * 255).rounded(), (g * 255).rounded(), (b * 255).rounded())
    }

    private func assertClose(_ actual: (Double, Double, Double), _ expected: (Double, Double, Double),
                             file: StaticString = #filePath, line: UInt = #line) {
        for (a, e) in [(actual.0, expected.0), (actual.1, expected.1), (actual.2, expected.2)] {
            XCTAssertEqual(a, e, accuracy: 3, "\(actual) is not \(expected)", file: file, line: line)
        }
    }

    func test_darkModeGetsThePalette() {
        assertClose(components(UIColor.systemBackground.resolvedColor(with: dark)), MatronDarkSurface.page)
        assertClose(components(UIColor.secondarySystemGroupedBackground.resolvedColor(with: dark)), MatronDarkSurface.card)
        assertClose(components(UIColor.label.resolvedColor(with: dark)), MatronDarkSurface.label)
    }

    func test_lightModeKeepsTheSystemColours() {
        assertClose(components(UIColor.systemBackground.resolvedColor(with: light)), (255, 255, 255))
        assertClose(components(UIColor.label.resolvedColor(with: light)), (0, 0, 0))
    }

    /// A grouped `List`, drawn for real: its page and its row must both
    /// come out in the palette.
    func test_aRenderedListUsesThePalette() throws {
        let host = UIHostingController(rootView: List {
            Section { Text("Row").frame(maxWidth: .infinity, minHeight: 60) }
        }.listStyle(.insetGrouped))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.isHidden = false
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        window.layoutIfNeeded()

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        // The far left is the page; the row spans the middle of the width.
        let page = try XCTUnwrap(pixel(in: image, x: 4, y: 200))
        assertClose(page, MatronDarkSurface.page)
        let rowY = try XCTUnwrap(firstY(in: image, x: 195, matching: MatronDarkSurface.card))
        XCTAssertGreaterThan(rowY, 0, "no row drawn in the card colour")
    }

    private func pixel(in image: UIImage, x: Int, y: Int) -> (Double, Double, Double)? {
        guard let cg = image.cgImage,
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = Int(image.scale)
        context.draw(cg, in: CGRect(x: -x * scale, y: -(cg.height - 1 - y * scale), width: cg.width, height: cg.height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return (Double(data[0]), Double(data[1]), Double(data[2]))
    }

    private func firstY(in image: UIImage, x: Int, matching target: (Double, Double, Double)) -> Int? {
        for y in stride(from: 20, to: 380, by: 4) {
            guard let p = pixel(in: image, x: x, y: y) else { continue }
            if abs(p.0 - target.0) <= 3, abs(p.1 - target.1) <= 3, abs(p.2 - target.2) <= 3 { return y }
        }
        return nil
    }
}
