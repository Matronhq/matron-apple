import CoreGraphics
import Foundation
import MatronModels

/// Steps through an `AnimatedImageSource`'s frames in time and hands each
/// one to `display`. It knows nothing about views: `AnimatedImageView`
/// starts and stops it as the image comes on and goes off screen.
///
/// Each frame is decoded off the main thread while the one before it is
/// showing, at `maxPixel` (the size it is drawn at, not the file's), so a
/// large GIF costs one small bitmap at a time. Frames are kept for the
/// next loop only while the whole animation fits in `memoryBudget`;
/// anything larger is decoded afresh each time round, which bounds memory
/// for a long, big animation at about two frames.
@MainActor
final class AnimatedImagePlayer {
    let source: AnimatedImageSource
    /// Bytes this player may hold in decoded frames between loops.
    let memoryBudget: Int
    /// Puts a frame on screen.
    var display: (CGImage) -> Void = { _ in }

    /// The longest side, in pixels, frames are decoded at. A change of
    /// more than a quarter drops the frames kept so far (they were made
    /// for the old size); smaller wobbles keep them.
    var maxPixel: CGFloat = 0 {
        didSet {
            guard oldValue > 0, maxPixel > 0 else { return }
            if abs(maxPixel - oldValue) / oldValue > 0.25 { cache.removeAll() }
        }
    }

    /// The frame on screen (or the one to resume at).
    private(set) var index = 0
    /// Set once a finite animation has played its last loop; it then
    /// rests on the last frame until `restart()`.
    private(set) var isFinished = false
    var isRunning: Bool { task != nil }

    private var completedLoops = 0
    private var task: Task<Void, Never>?
    private var cache: [Int: CGImage] = [:]

    init(source: AnimatedImageSource, memoryBudget: Int) {
        self.source = source
        self.memoryBudget = memoryBudget
    }

    /// Whether every frame, at the current size, fits in the budget.
    var keepsFrames: Bool {
        let size = AnimatedImageSource.decodedSize(native: source.pixelSize, maxPixel: maxPixel)
        return AnimatedImageSource.frameBytes(size) * source.frameCount <= memoryBudget
    }

    /// Bytes held in kept frames, for tests.
    var cachedBytes: Int {
        cache.values.reduce(0) { $0 + $1.bytesPerRow * $1.height }
    }

    /// Starts (or resumes) playing from the frame last shown. Does nothing
    /// before a size is known or after a finite animation has ended.
    func start() {
        guard task == nil, !isFinished, maxPixel > 0 else { return }
        task = Task { [weak self] in await self?.run() }
    }

    /// Stops on the frame showing. `releasingFrames` drops the frames kept
    /// for the next loop — what an image going off screen does, so only
    /// the animations being watched hold memory.
    func stop(releasingFrames: Bool) {
        task?.cancel()
        task = nil
        if releasingFrames { cache.removeAll() }
    }

    /// Back to the first frame and a fresh loop count.
    func restart() {
        stop(releasingFrames: false)
        index = 0
        completedLoops = 0
        isFinished = false
        start()
    }

    /// Shows the frame at `index` once, without playing — the still a
    /// paused image rests on.
    func showCurrentFrame() async {
        guard maxPixel > 0, let image = await frame(index) else { return }
        display(image)
    }

    private func run() async {
        var shown = index
        var loops = completedLoops
        var image = await frame(shown)
        while !Task.isCancelled {
            guard let current = image else { break }
            display(current)
            index = shown
            completedLoops = loops
            guard let next = source.nextFrame(after: shown, completedLoops: &loops) else {
                isFinished = true
                break
            }
            let shownAt = ContinuousClock.now
            // Decoded while this frame is up, so the wait covers it.
            let nextImage = await frame(next)
            let remaining = Duration.seconds(source.delays[shown]) - (ContinuousClock.now - shownAt)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
            shown = next
            image = nextImage
        }
        if !Task.isCancelled { task = nil }
    }

    private func frame(_ index: Int) async -> CGImage? {
        if let kept = cache[index] { return kept }
        let source = self.source, maxPixel = self.maxPixel
        let image = await Task.detached(priority: .utility) {
            source.frame(at: index, maxPixel: maxPixel)
        }.value
        if let image, keepsFrames, maxPixel == self.maxPixel { cache[index] = image }
        return image
    }
}
