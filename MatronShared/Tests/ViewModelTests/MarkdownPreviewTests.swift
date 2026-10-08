import XCTest
import MatronChat
@testable import MatronModels
@testable import MatronViewModels

/// Markdown attachment preview (shared spec "markdown preview"): which
/// attachments preview, the rewrite that keeps a previewed file from
/// loading anything, and the panel's open / replace / close state.
final class MarkdownPreviewPredicateTests: XCTestCase {
    private func previewable(_ mime: String?, _ name: String?, _ size: Int64? = 10) -> Bool {
        MarkdownPreview.isPreviewable(mime: mime, name: name, size: size)
    }

    func testMarkdownMimeTypesPreviewWhateverTheName() {
        XCTAssertTrue(previewable("text/markdown", "notes"))
        XCTAssertTrue(previewable("text/x-markdown", "notes.txt"))
        XCTAssertTrue(previewable("text/markdown", nil))
        XCTAssertTrue(previewable("Text/Markdown; charset=utf-8", "notes"))
    }

    func testMarkdownExtensionsPreviewWithAGenericMimeType() {
        XCTAssertTrue(previewable("", "README.md"))
        XCTAssertTrue(previewable(nil, "README.md"))
        XCTAssertTrue(previewable("text/plain", "plan.markdown"))
        XCTAssertTrue(previewable("application/octet-stream", "notes.mdown"))
        XCTAssertTrue(previewable("text/plain; charset=utf-8", "notes.md"))
    }

    func testExtensionsMatchInAnyCase() {
        XCTAssertTrue(previewable("", "README.MD"))
        XCTAssertTrue(previewable("", "Plan.Markdown"))
        XCTAssertTrue(previewable("", "x.mDoWn"))
    }

    func testMarkdownNameWithASpecificOtherMimeTypeDoesNotPreview() {
        XCTAssertFalse(previewable("application/pdf", "report.md"))
        XCTAssertFalse(previewable("text/html", "page.md"))
        XCTAssertFalse(previewable("image/png", "diagram.md"))
    }

    func testNonMarkdownFilesDoNotPreview() {
        XCTAssertFalse(previewable("text/plain", "notes.txt"))
        XCTAssertFalse(previewable("application/pdf", "spec.pdf"))
        XCTAssertFalse(previewable("image/png", "shot.png"))
        XCTAssertFalse(previewable("", "readme"))
        XCTAssertFalse(previewable("", "notes.md.txt"))
        XCTAssertFalse(previewable("", "cmd"))
        XCTAssertFalse(previewable(nil, nil))
    }

    func testSizeCapIsTwoMegabytesInclusive() {
        let cap: Int64 = 2 * 1024 * 1024
        XCTAssertEqual(MarkdownPreview.maxBytes, cap)
        XCTAssertTrue(previewable("text/markdown", "a.md", cap))
        XCTAssertFalse(previewable("text/markdown", "a.md", cap + 1))
        XCTAssertFalse(previewable("", "a.md", cap + 1))
    }

    func testUnknownSizePreviews() {
        XCTAssertTrue(previewable("text/markdown", "a.md", nil))
    }

    func testTrackerAttachment() {
        XCTAssertTrue(TrackerAttachment(blobRef: "a", mime: "text/markdown", name: "plan", size: 100).isPreviewableMarkdown)
        XCTAssertTrue(TrackerAttachment(blobRef: "a", mime: "text/plain", name: "plan.md", size: 100).isPreviewableMarkdown)
        // A missing size decodes as 0: unknown, so it still previews.
        XCTAssertTrue(TrackerAttachment(blobRef: "a", mime: "", name: "plan.md", size: 0).isPreviewableMarkdown)
        XCTAssertFalse(TrackerAttachment(blobRef: "a", mime: "text/markdown", name: "big.md",
                                         size: MarkdownPreview.maxBytes + 1).isPreviewableMarkdown)
        XCTAssertFalse(TrackerAttachment(blobRef: "a", mime: "image/png", name: "a.png", size: 10).isPreviewableMarkdown)
    }
}

final class MarkdownPreviewSanitiserTests: XCTestCase {
    private func clean(_ s: String) -> String { MarkdownPreview.sanitized(s) }

    func testRemoteImageBecomesItsAltText() {
        XCTAssertEqual(clean("Logo: ![the logo](https://example.com/logo.png) here"), "Logo: the logo here")
    }

    func testImageWithNoAltBecomesItsURLText() {
        XCTAssertEqual(clean("![](https://example.com/logo.png)"), "https://example.com/logo.png")
    }

    func testRelativeImageBecomesItsAltText() {
        XCTAssertEqual(clean("![diagram](./img/diagram.png)"), "diagram")
        XCTAssertEqual(clean("![diagram](img/diagram.png \"Title\")"), "diagram")
    }

    func testAttachmentImageRefBecomesItsAltText() {
        XCTAssertEqual(clean("![shot](attachment:aa11)"), "shot")
    }

    func testNoImageSyntaxSurvivesOutsideCode() {
        let source = """
        # Title
        ![a](https://x.example/a.png) and ![b](<https://x.example/b c.png>)
        - item ![c](http://x.example/c.gif "c")
        | col | ![d](https://x.example/d.png) |
        """
        XCTAssertFalse(clean(source).contains("!["))
    }

    func testWebAndMailLinksStay() {
        XCTAssertEqual(clean("[docs](https://example.com/docs)"), "[docs](https://example.com/docs)")
        XCTAssertEqual(clean("[site](http://example.com \"Site\")"), "[site](http://example.com \"Site\")")
        XCTAssertEqual(clean("[mail](mailto:a@example.com)"), "[mail](mailto:a@example.com)")
        XCTAssertEqual(clean("[w](https://en.wikipedia.org/wiki/Foo_(bar))"),
                       "[w](https://en.wikipedia.org/wiki/Foo_(bar))")
    }

    func testRelativeAnchorAndOtherSchemeLinksBecomeText() {
        XCTAssertEqual(clean("See [the other file](./other.md)."), "See the other file.")
        XCTAssertEqual(clean("Jump to [intro](#intro)."), "Jump to intro.")
        XCTAssertEqual(clean("[hosts](file:///etc/hosts)"), "hosts")
        XCTAssertEqual(clean("[item](matron://item/5)"), "item")
        XCTAssertEqual(clean("[x](javascript:alert(1))"), "x")
    }

    func testBadgeLinkKeepsTheLinkAndDropsTheImage() {
        XCTAssertEqual(clean("[![build](https://ci.example/badge.svg)](https://ci.example/run)"),
                       "[build](https://ci.example/run)")
    }

    func testInlineCodeIsLeftAlone() {
        let source = "Write `![a](https://x.example/a.png)` and `[b](./b.md)`."
        XCTAssertEqual(clean(source), source)
    }

    func testFencedCodeIsLeftAlone() {
        let source = "```md\n![a](https://x.example/a.png)\n[b](./b.md)\n```\nafter ![c](./c.png)"
        XCTAssertEqual(clean(source), "```md\n![a](https://x.example/a.png)\n[b](./b.md)\n```\nafter c")
    }

    func testEscapedBracketsAreLeftAlone() {
        XCTAssertEqual(clean("\\![not an image] and \\[not a link](./x)"), "\\![not an image] and \\[not a link](./x)")
    }

    func testOtherSchemeAutolinksAreEscaped() {
        XCTAssertEqual(clean("<file:///etc/hosts>"), "\\<file:///etc/hosts>")
        XCTAssertEqual(clean("<https://example.com>"), "<https://example.com>")
        XCTAssertEqual(clean("<mailto:a@example.com>"), "<mailto:a@example.com>")
        XCTAssertEqual(clean("a <b> c"), "a <b> c")
    }

    func testPlainTextAndUnclosedBracketsAreUnchanged() {
        XCTAssertEqual(clean("Just text, no links."), "Just text, no links.")
        XCTAssertEqual(clean("[unclosed (x) and ![half"), "[unclosed (x) and ![half")
        XCTAssertEqual(clean("[a] [b]"), "[a] [b]")
    }

    func testALinkWrappedOntoTheNextLineStillBecomesText() {
        XCTAssertEqual(clean("See [the other\nfile](./other.md) now."), "See the other\nfile now.")
        XCTAssertEqual(clean("A ![wrapped\nalt](https://x.example/a.png)"), "A wrapped\nalt")
        XCTAssertEqual(clean("[x](\n./a.md)"), "x")
        XCTAssertEqual(clean("a\r\n[b](./b.md)\r\n"), "a\r\nb\r\n")
    }

    func testIndentedCodeIsLeftAlone() {
        let source = "Text\n\n    ![a](https://x.example/a.png)\n    [b](./b.md)\n\nafter [c](./c.md)"
        XCTAssertEqual(clean(source),
                       "Text\n\n    ![a](https://x.example/a.png)\n    [b](./b.md)\n\nafter c")
        // Indented under a paragraph or a list item it is text, not code.
        XCTAssertEqual(clean("para\n    [x](./x.md)"), "para\n    x")
        XCTAssertEqual(clean("- item\n\n    [x](./x.md)"), "- item\n\n    x")
        // A fence inside a list item is still a fence.
        XCTAssertEqual(clean("- item\n\n  ```\n  [x](./x.md)\n  ```"), "- item\n\n  ```\n  [x](./x.md)\n  ```")
    }

    /// Fence characters inside an indented code block don't open a fence,
    /// so the line after them is still sanitised.
    func testAnIndentedFenceDoesNotHideTheNextLine() {
        XCTAssertEqual(clean("    ```\n[x](file:///etc/hosts)"), "    ```\nx")
    }

    func testReferenceLinksToInertDestinationsBecomeText() {
        XCTAssertEqual(clean("See [text][ref].\n\n[ref]: ./other.md"), "See [text][ref].\n\n\\[ref]: ./other.md")
        XCTAssertEqual(clean("[t][f]\n\n[f]: <file:///etc/hosts>"), "[t][f]\n\n\\[f]: \\<file:///etc/hosts>")
        let web = "See [text][ref].\n\n[ref]: https://example.com \"T\""
        XCTAssertEqual(clean(web), web)
    }

    func testReferenceImagesBecomeTheirAltText() {
        XCTAssertEqual(clean("Logo ![the logo][logo] and ![x][] and ![y]\n\n[logo]: https://x.example/l.png"),
                       "Logo the logo and x and y\n\n[logo]: https://x.example/l.png")
    }

    /// Anything the rewrite doesn't model is caught by parsing the result:
    /// every bracket outside code is escaped instead.
    func testConstructsTheRewriteMissesFallBackToEscaping() {
        let quoted = "> [a][r]\n>\n> [r]: ./x.md"
        XCTAssertEqual(clean(quoted), "> \\[a]\\[r]\n>\n> \\[r]: ./x.md")
        XCTAssertFalse(MarkdownPreview.hasUnsafeInline(clean(quoted)))
    }

    /// The renderers turn a bare `matron://item/<n>` into an in-app link
    /// before parsing; in a previewed file it must stay text.
    func testBareItemURLsCannotBecomeLinks() {
        XCTAssertEqual(clean("see matron://item/5 and `matron://item/6`"),
                       "see matron\\://item/5 and `matron://item/6`")
        XCTAssertEqual(clean("<matron://item/5>"), "\\<matron\\://item/5>")
        XCTAssertEqual(clean("![](matron://item/5)"), "matron\\://item/5")
        XCTAssertEqual(clean("[x](matron://item/5)"), "x")
        XCTAssertEqual(MarkdownPreview.rewrite(Array("[a] matron://item/7".unicodeScalars), mode: .escapeOutsideCode),
                       "\\[a] matron\\://item/7")
    }

    func testUnsafeInlineCheck() {
        XCTAssertTrue(MarkdownPreview.hasUnsafeInline("[a](./x.md)"))
        XCTAssertTrue(MarkdownPreview.hasUnsafeInline("[a](file:///etc/hosts)"))
        XCTAssertTrue(MarkdownPreview.hasUnsafeInline("![a](https://x.example/a.png)"))
        XCTAssertFalse(MarkdownPreview.hasUnsafeInline("[a](https://x.example) <mailto:a@b.example>"))
        XCTAssertFalse(MarkdownPreview.hasUnsafeInline("`[a](./x.md)` and \\[b](./y.md)"))
    }

    func testEscapeModes() {
        let source = Array("[a](b) `[c](d)` <x:y> \\[e\n```\n[f](g)\n```".unicodeScalars)
        XCTAssertEqual(MarkdownPreview.rewrite(source, mode: .escapeOutsideCode),
                       "\\[a](b) `[c](d)` \\<x:y> \\[e\n```\n[f](g)\n```")
        // An escaped backslash before a bracket never swallows the new escape.
        XCTAssertEqual(MarkdownPreview.rewrite(Array("```\n[f](g)\n```\n\\\\[h](i)".unicodeScalars), mode: .escapeEverywhere),
                       "```\n\\[f](g)\n```\n\\\\\\[h](i)")
    }

    func testOpensExternally() {
        XCTAssertTrue(MarkdownPreview.opensExternally("https://a.example"))
        XCTAssertTrue(MarkdownPreview.opensExternally("HTTP://a.example"))
        XCTAssertTrue(MarkdownPreview.opensExternally("mailto:a@b.example"))
        XCTAssertFalse(MarkdownPreview.opensExternally("./a.md"))
        XCTAssertFalse(MarkdownPreview.opensExternally("#top"))
        XCTAssertFalse(MarkdownPreview.opensExternally("dir/a:b.md"))
        XCTAssertFalse(MarkdownPreview.opensExternally("ftp://a.example"))
    }
}

final class MarkdownPreviewDocumentTests: XCTestCase {
    func testDecodesUTF8ReplacingInvalidBytes() {
        let document = MarkdownPreviewDocument(data: Data([0x61, 0xFF, 0x62]))
        XCTAssertEqual(document.text, "a\u{FFFD}b")
    }

    func testDropsAByteOrderMark() {
        let document = MarkdownPreviewDocument(data: Data([0xEF, 0xBB, 0xBF]) + Data("# Hi".utf8))
        XCTAssertEqual(document.text, "# Hi")
    }

    func testRenderedTextIsSanitised() {
        let document = MarkdownPreviewDocument(text: "![a](https://x.example/a.png)")
        XCTAssertEqual(document.text, "![a](https://x.example/a.png)")
        XCTAssertEqual(document.rendered, "a")
    }

    func testSourceChunksCoverEveryLine() {
        let text = (1...450).map { "line \($0)" }.joined(separator: "\n")
        let chunks = MarkdownPreview.sourceChunks(text, linesPerChunk: 200)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.joined(separator: "\n"), text)
        XCTAssertEqual(MarkdownPreview.sourceChunks("short"), ["short"])
    }

    func testRequestDefaultsBlobRefAndName() {
        let url = URL(string: "https://journal.example/media/abc123")!
        let request = MarkdownPreviewRequest(mediaURL: url, name: "", size: nil)
        XCTAssertEqual(request.blobRef, "abc123")
        XCTAssertEqual(request.name, "abc123")
        XCTAssertEqual(request.id, url.absoluteString)
    }
}

/// Counts fetches per URL and answers from a script.
private actor FetchLog {
    private(set) var urls: [URL] = []
    private var outcomes: [URL: MediaFetchOutcome] = [:]

    func set(_ outcome: MediaFetchOutcome, for url: URL) { outcomes[url] = outcome }

    func fetch(_ url: URL) -> MediaFetchOutcome {
        urls.append(url)
        return outcomes[url] ?? .failure
    }
}

@MainActor
final class MarkdownPreviewModelTests: XCTestCase {
    private let urlA = URL(string: "https://journal.example/media/aaa")!
    private let urlB = URL(string: "https://journal.example/media/bbb")!
    private var log: FetchLog!
    private var cache: MarkdownPreviewTextCache!
    private var model: MarkdownPreviewModel!

    override func setUp() async throws {
        log = FetchLog()
        cache = MarkdownPreviewTextCache()
        model = MarkdownPreviewModel(cache: cache, writeShareFile: { _, request in
            URL(fileURLWithPath: "/tmp/share/\(request.name)")
        })
    }

    private var fetch: MarkdownPreviewModel.Fetch {
        let log = log!
        return { await log.fetch($0) }
    }

    private func request(_ url: URL, _ name: String) -> MarkdownPreviewRequest {
        MarkdownPreviewRequest(mediaURL: url, name: name, size: nil)
    }

    func testStartsClosed() {
        XCTAssertFalse(model.isOpen)
        XCTAssertNil(model.request)
        XCTAssertEqual(model.phase, .idle)
    }

    func testOpenLoadsTheText() async {
        await log.set(.data(Data("# A".utf8)), for: urlA)
        model.open(request(urlA, "a.md"), fetch: fetch)
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(model.phase, .loading)
        await model.waitForLoad()
        XCTAssertEqual(model.phase, .loaded(MarkdownPreviewDocument(text: "# A")))
        XCTAssertEqual(model.shareURL, URL(fileURLWithPath: "/tmp/share/a.md"))
        let fetched = await log.urls
        XCTAssertEqual(fetched, [urlA])
    }

    func testOpeningAnotherFileReplacesTheFirst() async {
        await log.set(.data(Data("# A".utf8)), for: urlA)
        await log.set(.data(Data("# B".utf8)), for: urlB)
        model.open(request(urlA, "a.md"), fetch: fetch)
        await model.waitForLoad()
        model.showsSource = true
        model.open(request(urlB, "b.md"), fetch: fetch)
        XCTAssertEqual(model.request?.name, "b.md")
        XCTAssertFalse(model.showsSource, "a new file opens rendered")
        await model.waitForLoad()
        XCTAssertEqual(model.phase, .loaded(MarkdownPreviewDocument(text: "# B")))
    }

    func testReplacingAFileStillLoadingNeverShowsTheOldOne() async {
        await log.set(.data(Data("# A".utf8)), for: urlA)
        await log.set(.data(Data("# B".utf8)), for: urlB)
        model.open(request(urlA, "a.md"), fetch: fetch)
        model.open(request(urlB, "b.md"), fetch: fetch)
        await model.waitForLoad()
        // Give A's cancelled task every chance to land late.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.request?.name, "b.md")
        XCTAssertEqual(model.phase, .loaded(MarkdownPreviewDocument(text: "# B")))
    }

    func testReopeningTheSameFileKeepsItsState() async {
        await log.set(.data(Data("# A".utf8)), for: urlA)
        model.open(request(urlA, "a.md"), fetch: fetch)
        await model.waitForLoad()
        model.showsSource = true
        model.open(request(urlA, "a.md"), fetch: fetch)
        XCTAssertTrue(model.showsSource)
        let fetched = await log.urls
        XCTAssertEqual(fetched.count, 1)
    }

    func testCloseClearsEverything() async {
        await log.set(.data(Data("# A".utf8)), for: urlA)
        model.open(request(urlA, "a.md"), fetch: fetch, download: {})
        await model.waitForLoad()
        model.showsSource = true
        model.close()
        XCTAssertFalse(model.isOpen)
        XCTAssertNil(model.request)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.showsSource)
        XCTAssertNil(model.shareURL)
        XCTAssertNil(model.download)
    }

    func testCloseWhileLoadingDropsTheLateResult() async {
        await log.set(.data(Data("# A".utf8)), for: urlA)
        model.open(request(urlA, "a.md"), fetch: fetch)
        model.close()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.request)
    }

    func testTextIsCachedPerFileForTheSession() async {
        await log.set(.data(Data("# A".utf8)), for: urlA)
        model.open(request(urlA, "a.md"), fetch: fetch)
        await model.waitForLoad()
        model.close()
        let other = MarkdownPreviewModel(cache: cache, writeShareFile: { _, _ in nil })
        other.open(request(urlA, "a.md"), fetch: fetch)
        XCTAssertEqual(other.phase, .loaded(MarkdownPreviewDocument(text: "# A")), "a cache hit shows at once")
        let fetched = await log.urls
        XCTAssertEqual(fetched.count, 1)
    }

    func testMissingBlobIsExpired() async {
        await log.set(.notFound, for: urlA)
        model.open(request(urlA, "a.md"), fetch: fetch)
        await model.waitForLoad()
        XCTAssertEqual(model.phase, .failed(.expired))
    }

    func testFailureThenRetry() async {
        await log.set(.failure, for: urlA)
        model.open(request(urlA, "a.md"), fetch: fetch)
        await model.waitForLoad()
        XCTAssertEqual(model.phase, .failed(.unavailable))
        XCTAssertNil(model.shareURL)
        await log.set(.data(Data("# A".utf8)), for: urlA)
        model.retry()
        await model.waitForLoad()
        XCTAssertEqual(model.phase, .loaded(MarkdownPreviewDocument(text: "# A")))
    }

    func testReopeningAFailedFileTriesAgain() async {
        await log.set(.failure, for: urlA)
        model.open(request(urlA, "a.md"), fetch: fetch)
        await model.waitForLoad()
        await log.set(.data(Data("# A".utf8)), for: urlA)
        model.open(request(urlA, "a.md"), fetch: fetch)
        await model.waitForLoad()
        XCTAssertEqual(model.phase, .loaded(MarkdownPreviewDocument(text: "# A")))
    }

    func testBytesOverTheCapFallBack() async {
        await log.set(.data(Data(count: Int(MarkdownPreview.maxBytes) + 1)), for: urlA)
        model.open(request(urlA, "big.md"), fetch: fetch)
        await model.waitForLoad()
        XCTAssertEqual(model.phase, .failed(.tooLarge))
        XCTAssertNil(cache.document(for: urlA.absoluteString))
    }

    func testDownloadIsTheHostsPath() async {
        var downloads = 0
        model.open(request(urlA, "a.md"), fetch: fetch, download: { downloads += 1 })
        model.download?()
        XCTAssertEqual(downloads, 1)
    }

    /// A Share file written from the cache is the file as fetched — its
    /// byte-order mark and its invalid bytes intact — not the decoded text.
    func testShareFileFromTheCacheIsTheOriginalBytes() async {
        var written: [Data] = []
        let model = MarkdownPreviewModel(cache: cache, writeShareFile: { data, request in
            written.append(data)
            return URL(fileURLWithPath: "/tmp/share/\(request.name)")
        })
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("# A".utf8) + Data([0xFF])
        await log.set(.data(bytes), for: urlA)
        model.open(request(urlA, "a.md"), fetch: fetch)
        await model.waitForLoad()
        model.close()
        model.open(request(urlA, "a.md"), fetch: fetch)
        XCTAssertEqual(written, [bytes, bytes])
        let fetched = await log.urls
        XCTAssertEqual(fetched, [urlA])
    }

    func testThePanelGivesEscUpWhileAnotherViewHoldsIt() {
        XCTAssertTrue(model.closesOnEscape)
        model.holdEscape("search:a", true)
        model.holdEscape("search:b", true)
        model.holdEscape("search:a", false)
        XCTAssertFalse(model.closesOnEscape)
        model.close()
        XCTAssertFalse(model.closesOnEscape, "closing the file doesn't forget the window's holders")
        model.holdEscape("search:b", false)
        XCTAssertTrue(model.closesOnEscape)
    }
}
