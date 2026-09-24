#if os(macOS)
import XCTest
import SwiftUI
import AppKit

/// Guards the Mac snapshot harness itself (tracker #2840). Every Mac
/// reference used to be recorded from a window-less `NSHostingView`, which
/// (a) never populated `List` rows — the NSTableView only loads them once
/// it is in a window and the run loop has turned — and (b) never applied
/// `preferredColorScheme(.dark)`, so every light/dark pair was
/// byte-identical and asserted nothing about dark mode.
@MainActor
final class SnapshotHarnessTests: XCTestCase {
    /// A `List` row's content must reach the captured pixels.
    func testListRowsRender() throws {
        let view = List { Color.red.frame(height: 40) }
            .listStyle(.plain)
            .frame(width: 200, height: 200)
        let rep = try XCTUnwrap(macSnapshotImage(of: view, appearance: .aqua))
        XCTAssertGreaterThan(pixelCount(in: rep) { $0.redComponent > 0.8 && $0.greenComponent < 0.45 && $0.blueComponent < 0.45 },
                             100, "List rows are missing from the Mac snapshot")
    }

    /// The dark variant must actually render dark: `Color.primary` is near
    /// black in light and near white in dark.
    func testDarkAppearanceReachesTheView() throws {
        let view = Color.primary.frame(width: 20, height: 20)
        let light = try XCTUnwrap(macSnapshotImage(of: view, appearance: .aqua))
        let dark = try XCTUnwrap(macSnapshotImage(of: view, appearance: .darkAqua))
        let lightCentre = try XCTUnwrap(light.colorAt(x: light.pixelsWide / 2, y: light.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        let darkCentre = try XCTUnwrap(dark.colorAt(x: dark.pixelsWide / 2, y: dark.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(lightCentre.brightnessComponent, 0.3, "light: \(lightCentre)")
        XCTAssertGreaterThan(darkCentre.brightnessComponent, 0.7, "dark: \(darkCentre)")
    }

    private func pixelCount(in rep: NSBitmapImageRep, where match: (NSColor) -> Bool) -> Int {
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9, match(c) { count += 1 }
            }
        }
        return count
    }
}
#endif
