#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac

@MainActor @Observable
private final class ShowBox {
    var shows = true
}

/// Whatever the composer's closures hold (an item's or a chat's view
/// model) goes when the composer does. Its frame observer used to hold
/// its coordinator strongly, so the coordinator, its `parent` and every
/// closure in it lived for the life of the app.
@MainActor
final class MacComposerTextEditorLifetimeTests: XCTestCase {
    private final class Owner {}

    private struct Host: View {
        let box: ShowBox
        let owner: Owner
        @State private var text = "draft"

        var body: some View {
            if box.shows {
                MacComposerTextEditor(text: $text, onHeightChange: { _ in },
                                      onMoveUp: { false }, onMoveDown: { false },
                                      onCommit: { [owner] in _ = owner; return true },
                                      onPasteAttachments: { false }, onAttachablePasteboardTypes: { [] })
                    .frame(width: 300, height: 60)
            } else {
                Text("gone")
            }
        }
    }

    func test_removingTheComposer_releasesWhatItsClosuresHold() async throws {
        let box = ShowBox()
        weak var released: Owner?
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        do {
            let owner = Owner()
            released = owner
            window.contentViewController = NSHostingController(rootView: Host(box: box, owner: owner))
        }
        window.orderFront(nil)
        await Self.spin(seconds: 0.5)
        // A frame change while mounted still reports, through the weak capture.
        window.setContentSize(NSSize(width: 420, height: 220))
        await Self.spin(seconds: 0.3)

        box.shows = false
        await Self.spin(seconds: 0.5)
        window.contentViewController = nil
        await Self.spin(seconds: 0.5)
        XCTAssertNil(released, "the composer's coordinator outlived the composer")
    }

    private static func spin(seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }
}
#endif
