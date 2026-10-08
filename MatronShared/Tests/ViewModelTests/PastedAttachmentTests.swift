import XCTest
import UniformTypeIdentifiers
@testable import MatronViewModels

/// Covers the paste classification rules and the staging round-trip. The
/// classification cases are the load-bearing ones: both app shells decide
/// "attach this" vs "let the field paste it as text" purely from
/// `classify(_:)`, and a wrong answer either eats the user's text paste or
/// silently attaches a rendered HTML/webarchive blob.
final class PastedAttachmentTests: XCTestCase {
    // MARK: - classify

    func test_classify_plainText_isText() {
        let provider = NSItemProvider(object: "hello" as NSString)
        XCTAssertEqual(PastedAttachment.classify(provider), .text)
    }

    func test_classify_image_isAttachment() {
        let provider = NSItemProvider(
            item: Data([0x89, 0x50]) as NSData,
            typeIdentifier: UTType.png.identifier
        )
        XCTAssertEqual(
            PastedAttachment.classify(provider),
            .attachment(typeIdentifier: UTType.png.identifier)
        )
    }

    func test_classify_fileURL_isFileReference() throws {
        let source = try makeTempFile(named: "notes.txt", contents: "hi")
        let provider = NSItemProvider()
        provider.registerObject(source as NSURL, visibility: .all)
        XCTAssertEqual(PastedAttachment.classify(provider), .fileReference)
    }

    /// A Files-app copy puts the file's URL *and* a plain-text rendering of
    /// its contents on the pasteboard (verified: `NSItemProvider(contentsOf:)`
    /// on a .txt registers `["public.plain-text", "public.file-url",
    /// "public.url"]`). "Paste the file" is what the user meant, so the URL
    /// has to win over the text rendering.
    func test_classify_fileURLWithTextRendering_prefersTheFile() throws {
        let source = try makeTempFile(named: "notes.txt", contents: "hi")
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: source))
        XCTAssertTrue(provider.registeredTypeIdentifiers.contains(UTType.plainText.identifier))
        XCTAssertEqual(PastedAttachment.classify(provider), .fileReference)
    }

    /// Copying styled text from a browser or word processor registers an
    /// HTML/RTF flavour alongside the plain text. Both conform to
    /// `public.text`, so they must paste as text — never as an attached
    /// .html file.
    func test_classify_styledText_isText() {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.html.identifier, visibility: .all
        ) { completion in
            completion(Data("<b>hi</b>".utf8), nil)
            return nil
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.plainText.identifier, visibility: .all
        ) { completion in
            completion(Data("hi".utf8), nil)
            return nil
        }
        XCTAssertEqual(PastedAttachment.classify(provider), .text)
    }

    /// A web copy can carry a webarchive, which does NOT conform to
    /// `public.text` — the "any text flavour present wins" rule is what stops
    /// it being attached as a mystery file instead of pasted as text.
    func test_classify_webArchiveAlongsideText_isText() {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: "com.apple.webarchive", visibility: .all
        ) { completion in
            completion(Data([0x00]), nil)
            return nil
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.plainText.identifier, visibility: .all
        ) { completion in
            completion(Data("hi".utf8), nil)
            return nil
        }
        XCTAssertEqual(PastedAttachment.classify(provider), .text)
    }

    func test_classify_nonTextData_isAttachment() {
        let provider = NSItemProvider(
            item: Data([0x25, 0x50]) as NSData,
            typeIdentifier: UTType.pdf.identifier
        )
        XCTAssertEqual(
            PastedAttachment.classify(provider),
            .attachment(typeIdentifier: UTType.pdf.identifier)
        )
    }

    // MARK: - stage

    func test_stage_image_writesTempFileKeepingBytesAndExtension() async throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let provider = NSItemProvider(item: bytes as NSData, typeIdentifier: UTType.png.identifier)

        let staged = try await PastedAttachment.stage(provider)

        addTeardownBlock { try? FileManager.default.removeItem(at: staged) }
        // The extension is load-bearing: `ComposerViewModel.attachFiles(_:)`
        // derives the MIME type from it, which is what routes the upload to
        // `sendImage` rather than `sendFile`.
        XCTAssertEqual(staged.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
    }

    func test_stage_fileURL_copiesBytesAndKeepsFilename() async throws {
        let source = try makeTempFile(named: "report.pdf", contents: "%PDF-1.4")
        let provider = NSItemProvider()
        provider.registerObject(source as NSURL, visibility: .all)

        let staged = try await PastedAttachment.stage(provider)

        addTeardownBlock { try? FileManager.default.removeItem(at: staged) }
        // Exactly the name, with nothing added: it is what the tray shows
        // and what the agent is told the file is called.
        XCTAssertEqual(staged.lastPathComponent, "report.pdf")
        XCTAssertEqual(try Data(contentsOf: staged), Data("%PDF-1.4".utf8))
    }

    /// A file copied in another app can name a URL this app may not open.
    /// The item's own bytes still come through, under the file's name.
    func test_stage_unreadableFileURL_fallsBackToTheItemsOwnBytes() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("archive.zip")
        let bytes = Data([0x50, 0x4B, 0x05, 0x06])
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.zip.identifier, visibility: .all
        ) { completion in
            completion(bytes, nil)
            return nil
        }
        provider.registerObject(missing as NSURL, visibility: .all)
        XCTAssertEqual(PastedAttachment.classify(provider), .fileReference)

        let staged = try await PastedAttachment.stage(provider)

        addTeardownBlock { PastedAttachment.removeStagingFile(staged) }
        XCTAssertEqual(staged.lastPathComponent, "archive.zip")
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
    }

    func test_stage_unreadableFileURL_withNoBytes_reportsTheReadError() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("archive.zip")
        let provider = NSItemProvider()
        provider.registerObject(missing as NSURL, visibility: .all)
        do {
            let url = try await PastedAttachment.stage(provider)
            XCTFail("expected a throw, staged \(url)")
        } catch {
            XCTAssertNil(error as? PastedAttachmentError)
        }
    }

    func test_stage_zipData_keepsTheSuggestedNameAndExtension() async throws {
        let bytes = Data([0x50, 0x4B, 0x05, 0x06])
        let provider = NSItemProvider(item: bytes as NSData, typeIdentifier: UTType.zip.identifier)
        provider.suggestedName = "build-1.2"

        let staged = try await PastedAttachment.stage(provider)

        addTeardownBlock { PastedAttachment.removeStagingFile(staged) }
        XCTAssertEqual(staged.lastPathComponent, "build-1.2.zip")
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
    }

    func test_stage_fileOverTheLimit_isRefusedByName() async throws {
        let source = try makeTempFile(named: "huge.zip", contents: "")
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(PastedAttachment.maxBytes) + 1)
        try handle.close()
        let provider = NSItemProvider()
        provider.registerObject(source as NSURL, visibility: .all)
        do {
            let url = try await PastedAttachment.stage(provider)
            XCTFail("expected a throw, staged \(url)")
        } catch {
            XCTAssertEqual(error as? PastedAttachmentError, .tooLarge(name: "huge.zip"))
            XCTAssertEqual(error.localizedDescription,
                           "huge.zip is too large to attach. The limit is 52.4 MB.")
        }
    }

    // MARK: - filename

    func test_filename_withoutASuggestion_usesTheTypesExtension() {
        XCTAssertEqual(PastedAttachment.filename(suggestedName: nil, typeIdentifier: UTType.png.identifier),
                       "pasted-file.png")
    }

    func test_filename_keepsAnExtensionThatAlreadyFitsTheType() {
        XCTAssertEqual(PastedAttachment.filename(suggestedName: "photo.jpg", typeIdentifier: UTType.jpeg.identifier),
                       "photo.jpg")
        XCTAssertEqual(PastedAttachment.filename(suggestedName: "Report", typeIdentifier: UTType.pdf.identifier),
                       "Report.pdf")
    }

    // MARK: - staging locations

    func test_inlineFileType_prefersTheFilesOwnTypeOverATextRendering() {
        let provider = NSItemProvider()
        for identifier in [UTType.plainText.identifier, UTType.zip.identifier] {
            provider.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .all) { completion in
                completion(Data(), nil)
                return nil
            }
        }
        provider.registerObject(URL(fileURLWithPath: "/tmp/a.zip") as NSURL, visibility: .all)
        XCTAssertEqual(PastedAttachment.inlineFileType(of: provider), UTType.zip.identifier)
    }

    func test_removeStagingFile_takesThePerItemDirectoryWithIt() throws {
        let url = PastedAttachment.stagingURL(forName: "a.zip")
        try Data([1]).write(to: url)
        PastedAttachment.removeStagingFile(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    func test_removeStagingFile_leavesOtherDirectoriesAlone() throws {
        let other = try makeTempFile(named: "keep.txt", contents: "x")
        let sibling = other.deletingLastPathComponent().appendingPathComponent("sibling.txt")
        try Data([1]).write(to: sibling)
        PastedAttachment.removeStagingFile(other)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func test_stage_text_throwsNotAnAttachment() async {
        let provider = NSItemProvider(object: "hello" as NSString)
        do {
            let url = try await PastedAttachment.stage(provider)
            XCTFail("expected a throw, staged \(url)")
        } catch {
            XCTAssertEqual(error as? PastedAttachmentError, .notAnAttachment)
        }
    }

    /// Mirrors `ComposerView.stagedTempURL(for:)`'s uniqueness guarantee:
    /// pasting the same photo twice in quick succession must not have the
    /// second write clobber the first before `attachFiles(_:)` reads it.
    func test_stagingURL_isUniquePerCall() {
        let first = PastedAttachment.stagingURL(forName: "photo.png")
        let second = PastedAttachment.stagingURL(forName: "photo.png")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "photo.png")
        XCTAssertEqual(second.lastPathComponent, "photo.png")
    }

    // MARK: - Helpers

    private func makeTempFile(named name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }
}
