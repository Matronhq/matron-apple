#if os(macOS)
import AppKit
import Darwin

/// One window's on-screen pixels, as the window server shows them, or nil
/// where capture is unavailable (a headless runner, or no screen-recording
/// permission).
///
/// `CGWindowListCreateImage` is marked unavailable from the macOS 15 SDK
/// on, but it is still there at run time and is the only synchronous way
/// to read a window back. The on-screen tests look it up by name so they
/// keep capturing exactly as before.
@MainActor
func captureWindowImage(_ window: NSWindow) -> CGImage? {
    typealias Capture = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
    let capture = unsafeBitCast(symbol, to: Capture.self)
    return capture(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                   [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue()
}
#endif
