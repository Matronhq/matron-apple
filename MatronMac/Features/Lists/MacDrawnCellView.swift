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
///
/// The image is drawn in the window's colour space. An sRGB image on a P3
/// display was converted again on every commit (`CGContextDrawImage` under
/// the layer's `prepare_contents`), for every cell drawn: a large share of
/// the main thread in the sidebar's update bursts.
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

    /// A move to a screen with another scale or colour space draws again,
    /// in the new one.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = Self.image(of: self, scale: window?.backingScaleFactor ?? layer.contentsScale,
                                    colorSpace: Self.colorSpace(of: window))
        layer.contentsScale = window?.backingScaleFactor ?? layer.contentsScale
    }

    /// The colour space `window` is shown in: its screen's, unless set.
    static func colorSpace(of window: NSWindow?) -> CGColorSpace {
        window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// `view`'s whole `draw(_:)` at its current size, in its appearance.
    static func image(of view: NSView, scale: CGFloat, colorSpace: CGColorSpace) -> CGImage? {
        let size = view.bounds.size
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
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
