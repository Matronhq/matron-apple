import XCTest
import UniformTypeIdentifiers
@testable import MatronShare

final class ShareItemLoaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFile(_ name: String, _ contents: Data) throws -> URL {
        let folder = directory.appendingPathComponent("source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    // MARK: - classify

    func test_classify_plainText_isText() {
        XCTAssertEqual(ShareItemLoader.classify(NSItemProvider(object: "hello" as NSString)), .text)
    }

    func test_classify_webAddress_isALink() {
        let provider = NSItemProvider(object: URL(string: "https://example.com/page")! as NSURL)
        XCTAssertEqual(ShareItemLoader.classify(provider), .webLink)
    }

    func test_classify_zipData_isAFile() {
        let provider = NSItemProvider(item: Data([1]) as NSData, typeIdentifier: UTType.zip.identifier)
        XCTAssertEqual(ShareItemLoader.classify(provider), .file(typeIdentifier: UTType.zip.identifier))
    }

    /// A text file shared from a file browser carries its contents as plain
    /// text beside its URL. The file was shared, not the words in it.
    func test_classify_textFile_isAFile() throws {
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: makeFile("notes.txt", Data("hi".utf8))))
        guard case .fileReference = ShareItemLoader.classify(provider) else {
            return XCTFail("classified as \(ShareItemLoader.classify(provider))")
        }
    }

    func test_classify_imageWithAWebAddress_isAFile() {
        let provider = NSItemProvider(item: Data([1]) as NSData, typeIdentifier: UTType.png.identifier)
        provider.registerObject(URL(string: "https://example.com/a.png")! as NSURL, visibility: .all)
        XCTAssertEqual(ShareItemLoader.classify(provider), .file(typeIdentifier: UTType.png.identifier))
    }

    // MARK: - load

    func test_load_file_copiesItUnderItsOwnName() async throws {
        let bytes = Data([0x50, 0x4B, 0x05, 0x06])
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: makeFile("archive.zip", bytes)))

        let content = try await ShareItemLoader.load(provider, into: directory)

        guard case .file(let file) = content else { return XCTFail("loaded \(String(describing: content))") }
        XCTAssertEqual(file.filename, "archive.zip")
        XCTAssertEqual(file.mimeType, "application/zip")
        XCTAssertEqual(file.sizeBytes, 4)
        XCTAssertFalse(file.isImage)
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertEqual(file.url.lastPathComponent, "archive.zip")
    }

    /// A shared file can name a URL this process may not open. Its bytes
    /// still arrive, and keep the file's name.
    func test_load_unreadableFileURL_fallsBackToTheItemsOwnBytes() async throws {
        let missing = directory.appendingPathComponent("gone").appendingPathComponent("archive.zip")
        let bytes = Data([0x50, 0x4B, 0x05, 0x06])
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.zip.identifier, visibility: .all) { completion in
            completion(bytes, nil)
            return nil
        }
        provider.registerObject(missing as NSURL, visibility: .all)

        guard case .file(let file) = try await ShareItemLoader.load(provider, into: directory)
        else { return XCTFail("expected a file") }

        XCTAssertEqual(file.filename, "archive.zip")
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertEqual(file.sizeBytes, 4)
    }

    func test_load_twoFilesWithOneName_doNotCollide() async throws {
        let first = try XCTUnwrap(NSItemProvider(contentsOf: makeFile("a.pdf", Data([1]))))
        let second = try XCTUnwrap(NSItemProvider(contentsOf: makeFile("a.pdf", Data([2]))))

        guard case .file(let one) = try await ShareItemLoader.load(first, into: directory),
              case .file(let two) = try await ShareItemLoader.load(second, into: directory)
        else { return XCTFail("expected two files") }

        XCTAssertNotEqual(one.url, two.url)
        XCTAssertEqual(try Data(contentsOf: one.url), Data([1]))
        XCTAssertEqual(try Data(contentsOf: two.url), Data([2]))
    }

    func test_load_image_isAnImage() async throws {
        let provider = NSItemProvider(item: Data([0x89, 0x50]) as NSData, typeIdentifier: UTType.png.identifier)
        provider.suggestedName = "Screenshot"

        guard case .file(let file) = try await ShareItemLoader.load(provider, into: directory)
        else { return XCTFail("expected a file") }

        XCTAssertEqual(file.filename, "Screenshot.png")
        XCTAssertTrue(file.isImage)
    }

    func test_load_text_andLink_becomeMessageText() async throws {
        let text = try await ShareItemLoader.load(NSItemProvider(object: "hello" as NSString), into: directory)
        XCTAssertEqual(text, .text("hello"))
        let link = try await ShareItemLoader.load(
            NSItemProvider(object: URL(string: "https://example.com/page")! as NSURL), into: directory)
        XCTAssertEqual(link, .text("https://example.com/page"))
    }

    func test_load_fileOverTheLimit_isRefusedByName() async throws {
        let source = try makeFile("huge.zip", Data())
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(ShareItemLoader.maxBytes) + 1)
        try handle.close()
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: source))
        do {
            _ = try await ShareItemLoader.load(provider, into: directory)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? ShareLoadError, .tooLarge(name: "huge.zip"))
        }
    }

    // MARK: - filename

    func test_filename_isTheHandedOverFilesName() {
        let url = URL(fileURLWithPath: "/tmp/x/build-1.2.zip")
        XCTAssertEqual(ShareItemLoader.filename(for: url, suggestedName: nil,
                                                typeIdentifier: UTType.zip.identifier), "build-1.2.zip")
    }

    func test_filename_withoutAnExtension_getsTheTypes() {
        let url = URL(fileURLWithPath: "/tmp/x/Report")
        XCTAssertEqual(ShareItemLoader.filename(for: url, suggestedName: nil,
                                                typeIdentifier: UTType.pdf.identifier), "Report.pdf")
    }
}
