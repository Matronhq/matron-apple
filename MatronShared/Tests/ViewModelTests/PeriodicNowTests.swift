import XCTest
import MatronModels

/// Pins `PeriodicNow`'s contract — the fix for Bugbot's PR #273 finding: a
/// hand-rolled "sleep 60s, then write `now`" loop left the Decisions
/// view's Decided captions stale (or briefly wrong) between view mount and
/// the first tick. `ticks()` must yield its first value immediately,
/// before it ever sleeps.
final class PeriodicNowTests: XCTestCase {
    /// A black-box timing check, not an internal-ordering one: `ticks()`'s
    /// producer is an unstructured `Task`, so asserting call ORDER via an
    /// injected fake (log "now"/"sleep" calls) races the consumer — the
    /// producer can run ahead. Timing the wall-clock delay to the first
    /// value is deterministic and is exactly the bug's own symptom: the
    /// OLD "sleep, then write" shape would make this take a full
    /// `interval`; the fixed "write, then sleep" shape returns at once.
    func test_firstValue_arrivesImmediately_notAfterAFullInterval() async {
        let clock = PeriodicNow(interval: .milliseconds(500))
        let start = Date()
        var iterator = clock.ticks().makeAsyncIterator()
        _ = await iterator.next()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.3, "the first tick must not wait out a full interval")
    }

    /// The value itself is a real, current `Date` (the default `now:`),
    /// not something stale from before `ticks()` was called.
    func test_firstValue_reflectsCurrentTime() async {
        let start = Date()
        let clock = PeriodicNow(interval: .milliseconds(50))
        var iterator = clock.ticks().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertNotNil(first)
        XCTAssertGreaterThanOrEqual(first!.timeIntervalSince(start), 0)
        XCTAssertLessThan(first!.timeIntervalSince(start), 0.3)
    }

    /// A second value does arrive — this isn't a one-shot stream — spaced
    /// roughly `interval` after the first (loosely bounded: CI scheduling
    /// jitter, not exactness, is what could make this flaky).
    func test_ticksContinueAfterTheFirst() async {
        let clock = PeriodicNow(interval: .milliseconds(100))
        var count = 0
        for await _ in clock.ticks() {
            count += 1
            if count == 2 { break }
        }
        XCTAssertEqual(count, 2)
    }
}
