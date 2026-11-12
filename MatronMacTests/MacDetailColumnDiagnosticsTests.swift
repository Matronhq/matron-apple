#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac
import MatronViewModels

@MainActor
final class MacDetailColumnDiagnosticsTests: XCTestCase {
    func test_pillState_withoutASession_isNone() {
        XCTAssertEqual(MacDetailColumnDiagnostics.pillState(nil), "none")
    }

    /// The breadcrumb the crash hunt rests on: the root's `onAppear` fires
    /// once for a mounted column, and again when its content is built anew.
    func test_rootAppearance_isCountedEachTimeTheContentIsBuilt() async throws {
        let before = MacDetailColumnLog.rootAppearances
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: Harness(generation: 0))
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(MacDetailColumnLog.rootAppearances, before + 1)

        // The same content updated in place is not a rebuild.
        host.rootView = Harness(generation: 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(MacDetailColumnLog.rootAppearances, before + 1)

        // A new identity is: SwiftUI builds the content again.
        host.rootView = Harness(generation: 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(MacDetailColumnLog.rootAppearances, before + 2)
    }

    private struct Harness: View {
        let generation: Int
        var body: some View {
            Text("detail")
                .modifier(MacDetailColumnDiagnostics(voiceNotes: nil, markdownPreview: MarkdownPreviewModel()))
                .id(generation)
        }
    }
}
#endif
