import CoreGraphics
import Foundation
import ImageIO

/// The frames of an animated GIF, APNG or animated WebP, decoded on demand.
///
/// `UIImage(data:)`, `NSImage(data:)` and ImageIO thumbnails all hand back
/// the first frame only, and a SwiftUI `Image` cannot animate, so an
/// animated file showed as a still everywhere it appeared. This keeps the
/// file's bytes and its frame timing next to that still, and decodes one
/// frame at a time, at the size it is drawn, for a player
/// (`AnimatedImageView` in the design system) to put on screen.
///
/// ImageIO composites each frame onto the ones before it (a GIF frame is
/// usually a small changed rectangle), so `frame(at:maxPixel:)` always
/// returns the whole picture as it should look at that frame.
///
/// One source can feed several players at once (a chat row and the
/// full-screen viewer over it). Each player reads through its own
/// `FrameReader`: building a GIF frame starts from the frames before it,
/// and two players at different frames sharing one reader would make it
/// start again every time.
public final class AnimatedImageSource: @unchecked Sendable {
    /// Number of frames; always at least 2.
    public let frameCount: Int
    /// The canvas size in pixels.
    public let pixelSize: CGSize
    /// How many times the animation plays; 0 means forever.
    public let loopCount: Int
    /// How long each frame stays on screen, in seconds.
    public let delays: [TimeInterval]
    /// The file's bytes, kept so a copy or a share can use the original.
    public let data: Data

    /// Reads frames for whoever only needs one (tests, a still).
    private let sharedReader: FrameReader

    /// The shortest time a frame stays up. Browsers draw a GIF frame that
    /// asks for 10 ms or less for 100 ms instead (old encoders wrote 0 to
    /// mean "as fast as possible"), and ImageIO's clamped delay already
    /// does the same; this floor only stops a 0.011 s frame from asking for
    /// more redraws than a screen shows.
    public static let minimumDelay: TimeInterval = 0.02
    /// What a frame with no delay recorded at all is shown for.
    public static let defaultDelay: TimeInterval = 0.1

    /// The formats that can carry an animation. A HEIC can hold several
    /// images too (a burst, a depth map), but those are not frames to play.
    private static let animatedTypes: Set<String> = [
        "com.compuserve.gif", "public.png", "org.webmproject.webp",
    ]

    /// `nil` unless `data` is an animated GIF, APNG or WebP with at least
    /// two frames — a still image keeps its ordinary decode path.
    public init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              Self.animatedTypes.contains(type) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (first[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (first[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard width > 0, height > 0 else { return nil }
        self.sharedReader = FrameReader(source: source)
        self.data = data
        self.frameCount = count
        self.pixelSize = CGSize(width: width, height: height)
        self.loopCount = Self.loopCount(in: properties)
        self.delays = (0..<count).map { index in
            let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            return Self.delay(in: frame)
        }
    }

    /// Frame `index`, composited, no larger than `maxPixel` on its longer
    /// side (`nil`: full size) and never enlarged. The bitmap is fully
    /// decoded before it is returned, so putting it on screen costs the
    /// main thread nothing.
    public func frame(at index: Int, maxPixel: CGFloat?) -> CGImage? {
        sharedReader.frame(at: index, maxPixel: maxPixel ?? max(pixelSize.width, pixelSize.height))
    }

    /// A reader of its own, for one player.
    public func makeReader() -> FrameReader? {
        CGImageSourceCreateWithData(data as CFData, nil).map(FrameReader.init)
    }

    /// Decodes frames from one `CGImageSource`. Its calls are serialised:
    /// an image source is not documented as safe to read from two threads.
    public final class FrameReader: @unchecked Sendable {
        private let source: CGImageSource
        private let lock = NSLock()

        init(source: CGImageSource) { self.source = source }

        /// Frame `index` decoded straight at no more than `maxPixel` on its
        /// longer side — ImageIO scales while it decodes, so a large GIF
        /// never costs a full-size bitmap.
        public func frame(at index: Int, maxPixel: CGFloat) -> CGImage? {
            guard index >= 0, index < CGImageSourceGetCount(source), maxPixel > 0 else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            lock.lock()
            defer { lock.unlock() }
            return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
        }
    }

    /// The size a frame decodes at: `native`, scaled down to fit
    /// `maxPixel` on its longer side, at least 1 × 1.
    public static func decodedSize(native: CGSize, maxPixel: CGFloat?) -> CGSize {
        let longest = max(native.width, native.height)
        guard let maxPixel, maxPixel > 0, longest > maxPixel else { return native }
        let scale = maxPixel / longest
        return CGSize(width: max(1, (native.width * scale).rounded()),
                      height: max(1, (native.height * scale).rounded()))
    }

    /// Bytes one frame takes once decoded at `size` (4 bytes a pixel).
    public static func frameBytes(_ size: CGSize) -> Int {
        Int(size.width) * Int(size.height) * 4
    }

    /// The frame shown after `index`, or `nil` when the animation has
    /// finished. `completedLoops` is how many times it has already reached
    /// the last frame; it counts up as the animation wraps.
    public func nextFrame(after index: Int, completedLoops: inout Int) -> Int? {
        if index + 1 < frameCount { return index + 1 }
        completedLoops += 1
        if loopCount > 0 && completedLoops >= loopCount { return nil }
        return 0
    }

    private static func loopCount(in properties: [CFString: Any]) -> Int {
        let keys: [(CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount),
        ]
        for (dictionary, key) in keys {
            if let container = properties[dictionary] as? [CFString: Any],
               let count = container[key] as? NSNumber {
                return max(0, count.intValue)
            }
        }
        // No loop count recorded: a GIF without the NETSCAPE block plays
        // once in the spec, but every browser loops it, and so do we.
        return 0
    }

    private static func delay(in frame: [CFString: Any]) -> TimeInterval {
        let keys: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGUnclampedDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPDelayTime, kCGImagePropertyWebPUnclampedDelayTime),
        ]
        for (dictionary, clamped, unclamped) in keys {
            guard let container = frame[dictionary] as? [CFString: Any] else { continue }
            // The clamped value is ImageIO's browser-compatible reading (a
            // 0 or 10 ms delay becomes 100 ms); the unclamped one is only a
            // fallback for a file that carries nothing else.
            let seconds = (container[clamped] as? NSNumber)?.doubleValue
                ?? (container[unclamped] as? NSNumber)?.doubleValue
            if let seconds, seconds > 0 { return max(minimumDelay, seconds) }
            return defaultDelay
        }
        return defaultDelay
    }
}
