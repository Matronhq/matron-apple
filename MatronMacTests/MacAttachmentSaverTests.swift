#if os(macOS)
import UniformTypeIdentifiers
import XCTest
@testable import MatronMac

@MainActor
final class MacAttachmentSaverTests: XCTestCase {
    func test_contentType_prefersTheMimeType_thenTheExtension() {
        XCTAssertEqual(MacAttachmentSaver.contentType(mime: "application/pdf", filename: "a.bin"), .pdf)
        XCTAssertEqual(MacAttachmentSaver.contentType(mime: nil, filename: "notes.txt"), .plainText)
        XCTAssertEqual(MacAttachmentSaver.contentType(mime: "nonsense", filename: "noext"), .data)
    }

    /// A drop asks the provider for the file; it loads it only then, under
    /// the attachment's own name.
    func test_dragProvider_loadsTheFileOnDemand() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Cover proof.pdf")
        try Data("%PDF-1.4".utf8).write(to: file)
        var loads = 0
        let provider = MacAttachmentSaver.dragProvider(filename: "Cover proof.pdf", contentType: .pdf) {
            loads += 1
            return file
        }
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(provider.suggestedName, "Cover proof.pdf")
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier))
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                if let url, let data = try? Data(contentsOf: url) {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
        XCTAssertEqual(bytes, Data("%PDF-1.4".utf8))
        XCTAssertEqual(loads, 1)
    }

    /// A file that can't be fetched fails the drop rather than hanging it.
    func test_dragProvider_failsWhenTheFileCantBeHad() async {
        let provider = MacAttachmentSaver.dragProvider(filename: "gone.pdf", contentType: .pdf) { nil }
        let failed: Bool = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                continuation.resume(returning: url == nil && error != nil)
            }
        }
        XCTAssertTrue(failed)
    }
}
#endif
