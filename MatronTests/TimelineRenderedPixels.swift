import UIKit

/// What a view draws, pixel by pixel, so a test can ask where the drawing
/// is without knowing how it is built. SwiftUI draws a hosted label and its
/// shapes in UIKit subviews in a build against the iOS 18 SDK, and without
/// any in a build against the iOS 26 SDK on iOS 26: the picture is what the
/// two have in common.
@MainActor
struct RenderedPixels {
    private let pixels: [UInt8]
    private let width: Int
    private let height: Int
    private static let scale: CGFloat = 2

    /// `view` has to be in a window on screen.
    init(of view: UIView) {
        let scale = Self.scale
        let width = Int((view.bounds.width * scale).rounded(.up))
        let height = Int((view.bounds.height * scale).rounded(.up))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        var pixels = [UInt8](repeating: 0, count: max(width * height * 4, 0))
        if let cgImage = image.cgImage, width > 0, height > 0 {
            pixels.withUnsafeMutableBytes { buffer in
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        self.pixels = pixels
        self.width = width
        self.height = height
    }

    /// The box around everything drawn inside `rect` (the view's
    /// coordinates) that is not the colour of `rect`'s top left corner.
    /// `.null` when nothing is.
    func ink(in rect: CGRect) -> CGRect {
        let area = pixelArea(rect)
        guard !area.isEmpty else { return .null }
        let corner = offset(x: Int(area.minX), y: Int(area.minY))
        return box(in: area) { offset in differ(pixels, offset, pixels, corner) }
    }

    /// The box around every pixel that is not the same in `other`. `.null`
    /// when the two pictures are the same; the whole picture when they are
    /// not the same size.
    func difference(from other: RenderedPixels) -> CGRect {
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        guard width == other.width, height == other.height else {
            return whole.applying(CGAffineTransform(scaleX: 1 / Self.scale, y: 1 / Self.scale))
        }
        return box(in: whole) { offset in differ(pixels, offset, other.pixels, offset) }
    }

    private func pixelArea(_ rect: CGRect) -> CGRect {
        rect.applying(CGAffineTransform(scaleX: Self.scale, y: Self.scale)).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func offset(x: Int, y: Int) -> Int { (y * width + x) * 4 }

    /// More than rounding apart in any channel.
    private func differ(_ first: [UInt8], _ firstOffset: Int, _ second: [UInt8], _ secondOffset: Int) -> Bool {
        (0..<4).contains { abs(Int(first[firstOffset + $0]) - Int(second[secondOffset + $0])) > 8 }
    }

    private func box(in area: CGRect, where matches: (Int) -> Bool) -> CGRect {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) where matches(offset(x: x, y: y)) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return .null }
        return CGRect(x: CGFloat(minX) / Self.scale, y: CGFloat(minY) / Self.scale,
                      width: CGFloat(maxX - minX + 1) / Self.scale, height: CGFloat(maxY - minY + 1) / Self.scale)
    }
}
