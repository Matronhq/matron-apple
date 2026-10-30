#if os(macOS)
import XCTest
import AppKit
@testable import MatronMac

/// A pass nobody can see waits longer: once a list's window has gone from
/// on screen to hidden (the screen locked), a second of updates folds into
/// one pass instead of one every 50 ms.
@MainActor
final class MacFrameCoalescerTests: XCTestCase {
    private var visible = false
    private var asleep = false
    private var realVisibility: ((NSWindow?) -> Bool)!
    private var realAsleep: (() -> Bool)!

    override func setUp() async throws {
        realVisibility = MacFrameCoalescer.isWindowVisible
        MacFrameCoalescer.isWindowVisible = { [unowned self] _ in visible }
        realAsleep = MacScreenState.isAsleep
        MacScreenState.isAsleep = { [unowned self] in asleep }
    }

    override func tearDown() async throws {
        MacFrameCoalescer.isWindowVisible = realVisibility
        MacScreenState.isAsleep = realAsleep
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    func test_aHiddenWindowThatWasOnScreen_waitsASecond() {
        let window = window()
        defer { window.close() }
        let coalescer = MacFrameCoalescer(view: window.contentView!) {}
        defer { coalescer.invalidate() }
        visible = true
        XCTAssertEqual(coalescer.currentFallbackDelay(), MacFrameCoalescer.fallbackDelay)
        visible = false
        XCTAssertEqual(coalescer.currentFallbackDelay(), MacFrameCoalescer.hiddenFallbackDelay)
        visible = true
        XCTAssertEqual(coalescer.currentFallbackDelay(), MacFrameCoalescer.fallbackDelay)
    }

    /// Shown and hidden again with no pass in between still counts.
    func test_aWindowShownBetweenRequests_countsAsSeen() {
        let window = window()
        defer { window.close() }
        let coalescer = MacFrameCoalescer(view: window.contentView!) {}
        defer { coalescer.invalidate() }
        coalescer.watch(window)
        visible = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        visible = false
        XCTAssertEqual(coalescer.currentFallbackDelay(), MacFrameCoalescer.hiddenFallbackDelay)
    }

    func test_aWindowNeverOnScreen_keepsTheShortFallback() {
        let first = window(), second = window()
        defer { first.close(); second.close() }
        let view = NSView()
        first.contentView?.addSubview(view)
        let coalescer = MacFrameCoalescer(view: view) {}
        defer { coalescer.invalidate() }
        visible = true
        _ = coalescer.currentFallbackDelay()
        // Moved to another window, never seen on screen.
        visible = false
        second.contentView?.addSubview(view)
        XCTAssertEqual(coalescer.currentFallbackDelay(), MacFrameCoalescer.fallbackDelay)
    }

    /// Launched with the display off: never seen, but nobody can see it.
    func test_aWindowNeverOnScreen_waitsWhileTheScreenIsAsleep() {
        let window = window()
        defer { window.close() }
        let coalescer = MacFrameCoalescer(view: window.contentView!) {}
        defer { coalescer.invalidate() }
        asleep = true
        XCTAssertEqual(coalescer.currentFallbackDelay(), MacFrameCoalescer.hiddenFallbackDelay)
        asleep = false
        XCTAssertEqual(coalescer.currentFallbackDelay(), MacFrameCoalescer.fallbackDelay)
    }

    func test_aRequestInAWindowNeverOnScreen_runsPromptly() {
        let window = window()
        defer { window.close() }
        let ran = expectation(description: "the pass ran")
        let coalescer = MacFrameCoalescer(view: window.contentView!) { ran.fulfill() }
        defer { coalescer.invalidate() }
        coalescer.request()
        wait(for: [ran], timeout: 0.5)
    }
}
#endif
