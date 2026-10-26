import AppKit

/// A list cell drawn by hand in `draw(_:)` (the For you and items pane
/// rows, the sidebar's chat rows) whose layer always shows one whole
/// drawing at its current size.
///
/// Left to AppKit, a layer-backed view keeps what it drew and redraws only
/// the parts it marks dirty. A row could then show a patchwork of drawings
/// made at different widths: text wrapped for an older, narrower row on
/// the left, the ends of later, wider drawings beside it, and blank bands
/// where a later drawing had nothing, under buttons placed for the current
/// width. Here every update draws the whole cell into a fresh image that
/// replaces the layer's contents, and any change of size asks for one.
class MacDrawnCellView: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    /// A cell waiting in the table's reuse queue holds no image; it draws
    /// again when it comes back.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            layer?.contents = nil
        }
        needsDisplay = true
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = Self.image(of: self, scale: window?.backingScaleFactor ?? layer.contentsScale)
        layer.contentsScale = window?.backingScaleFactor ?? layer.contentsScale
    }

    /// `view`'s whole `draw(_:)` at its current size, in its appearance.
    static func image(of view: NSView, scale: CGFloat) -> CGImage? {
        let size = view.bounds.size
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // Flipped, in points, as `draw(_:)` expects.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.draw(view.bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
