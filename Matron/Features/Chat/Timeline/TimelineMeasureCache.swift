import Foundation
import CoreGraphics
import MatronDesignSystem

struct TimelineMeasureKey: Hashable, Sendable {
    let roomID: String
    let rowID: String
    let width: CGFloat
    /// `UIContentSizeCategory.rawValue` — Dynamic Type is part of the key.
    let sizeCategory: String
}

enum TimelineMeasurement: Sendable {
    /// A text row: its full render (segments + frames), laid out once.
    case text(TextRowRender)
    /// A hosted row or a self-reported override: the height only.
    case hosted(CGFloat)

    var height: CGFloat {
        switch self {
        case .text(let render): return render.layout.rowHeight
        case .hosted(let height): return height
        }
    }
}

/// Process-wide measurement memo (reopening a room is a cache walk, not a
/// re-layout). An entry hits only when its stored content `==` the row's
/// current content. `NSCache` is thread-safe; precompute writes from a
/// background task.
final class TimelineMeasureCache: @unchecked Sendable {
    static let shared = TimelineMeasureCache(countLimit: 4000)

    private final class KeyBox: NSObject {
        let key: TimelineMeasureKey
        init(_ key: TimelineMeasureKey) { self.key = key }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? KeyBox)?.key == key }
    }

    private final class EntryBox: NSObject {
        let content: TimelineRowContent
        let measurement: TimelineMeasurement
        init(content: TimelineRowContent, measurement: TimelineMeasurement) {
            self.content = content
            self.measurement = measurement
        }
    }

    private let storage = NSCache<KeyBox, EntryBox>()

    init(countLimit: Int) {
        storage.countLimit = countLimit
    }

    func measurement(for key: TimelineMeasureKey, content: TimelineRowContent) -> TimelineMeasurement? {
        guard let entry = storage.object(forKey: KeyBox(key)), entry.content == content else { return nil }
        return entry.measurement
    }

    func store(_ measurement: TimelineMeasurement, content: TimelineRowContent, key: TimelineMeasureKey) {
        storage.setObject(EntryBox(content: content, measurement: measurement), forKey: KeyBox(key))
    }

    func removeAll() {
        storage.removeAllObjects()
    }
}

/// How rows get measured. `backgroundTextRender` runs on any thread and
/// returns nil when the row needs the main thread (pills, tables — hosted
/// SwiftUI pieces); everything else happens on the main actor.
protocol TimelineRowMeasuring: AnyObject, Sendable {
    func backgroundTextRender(_ content: TextRowContent, width: CGFloat, style: TimelineTextStyle) -> TextRowRender?
    /// `backgroundTextRender`, exposed as a plain `@Sendable` function value
    /// with no reference to `self`. `TimelineHeightProvider.precompute`
    /// captures ONLY this into its `Task.detached` closure — never the
    /// measurer itself, whose production implementation
    /// (`TimelineMeasurer`) owns a `UIHostingController` (and, through its
    /// factory, a `ChatViewModel`). A detached task can outlive its caller
    /// and release its captures on a background thread; UIKit objects must
    /// never be deinited off-main. The default forwards to
    /// `backgroundTextRender` (weakly capturing `self`) — fine for test
    /// doubles with no such lifetime hazard. `TimelineMeasurer` overrides
    /// it with a genuinely `self`-free implementation.
    var backgroundRenderer: @Sendable (TextRowContent, CGFloat, TimelineTextStyle) -> TextRowRender? { get }
    @MainActor func measure(_ content: TimelineRowContent, width: CGFloat, style: TimelineTextStyle) -> TimelineMeasurement
    @MainActor func footerHeight(label: String, width: CGFloat, style: TimelineTextStyle) -> CGFloat
}

extension TimelineRowMeasuring {
    var backgroundRenderer: @Sendable (TextRowContent, CGFloat, TimelineTextStyle) -> TextRowRender? {
        { [weak self] content, width, style in self?.backgroundTextRender(content, width: width, style: style) ?? nil }
    }
}

/// The controller's measuring front: cache first, measure synchronously on
/// a miss (spec), precompute batches off the main thread.
@MainActor
final class TimelineHeightProvider {
    let roomID: String
    let measurer: TimelineRowMeasuring
    private let cache: TimelineMeasureCache

    init(roomID: String, cache: TimelineMeasureCache, measurer: TimelineRowMeasuring) {
        self.roomID = roomID
        self.cache = cache
        self.measurer = measurer
    }

    private func key(_ content: TimelineRowContent, width: CGFloat, style: TimelineTextStyle) -> TimelineMeasureKey {
        TimelineMeasureKey(roomID: roomID, rowID: content.anchorID, width: width,
                           sizeCategory: style.sizeCategory.rawValue)
    }

    func cached(_ content: TimelineRowContent, width: CGFloat, style: TimelineTextStyle) -> TimelineMeasurement? {
        cache.measurement(for: key(content, width: width, style: style), content: content)
    }

    func measurement(_ content: TimelineRowContent, width: CGFloat, style: TimelineTextStyle) -> TimelineMeasurement {
        if let hit = cached(content, width: width, style: style) { return hit }
        let measured = measurer.measure(content, width: width, style: style)
        cache.store(measured, content: content, key: key(content, width: width, style: style))
        return measured
    }

    /// A hosted cell reported a new height (ask card answered, image landed).
    func storeHostedHeight(_ height: CGFloat, for content: TimelineRowContent, width: CGFloat, style: TimelineTextStyle) {
        cache.store(.hosted(height), content: content, key: key(content, width: width, style: style))
    }

    /// Text rows with no cache entry, minus those known to need the main
    /// thread (`excluding`) and those with pills (always main-thread).
    func missingText(in contents: [TimelineRowContent], width: CGFloat, style: TimelineTextStyle,
                     excluding mainThreadOnly: Set<String>) -> [TextRowContent] {
        contents.compactMap { content in
            guard case .text(let text) = content, text.pills.isEmpty,
                  !mainThreadOnly.contains(text.itemID),
                  cached(content, width: width, style: style) == nil else { return nil }
            return text
        }
    }

    /// Renders `texts` on a background task and stores them. Returns the
    /// ids that turned out to need the main thread (tables).
    func precompute(_ texts: [TextRowContent], width: CGFloat, style: TimelineTextStyle) async -> Set<String> {
        // Captures the Sendable render FUNCTION, never `measurer` itself —
        // see `TimelineRowMeasuring.backgroundRenderer`.
        let renderer = measurer.backgroundRenderer, cache = cache, roomID = roomID
        return await Task.detached(priority: .userInitiated) {
            var needsMain = Set<String>()
            for text in texts {
                guard let render = renderer(text, width, style) else {
                    needsMain.insert(text.itemID)
                    continue
                }
                let content = TimelineRowContent.text(text)
                cache.store(.text(render), content: content,
                            key: TimelineMeasureKey(roomID: roomID, rowID: text.itemID, width: width,
                                                    sizeCategory: style.sizeCategory.rawValue))
            }
            return needsMain
        }.value
    }
}
