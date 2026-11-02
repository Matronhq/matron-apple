import XCTest
import MatronModels
@testable import MatronMac

/// Which attachments play in the app's own player rather than going to the
/// default app (which for audio was Music), and with which engine.
final class MacAttachmentOpenerTests: XCTestCase {
    private func url(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    private func preview(_ name: String, mime: String? = nil) -> MediaPlayerPreview? {
        MediaPlayback.engine(filename: name, mime: mime).map {
            MediaPlayerPreview(filename: name, mime: mime, playback: $0, load: { nil })
        }
    }

    func testAudioAndVideoPlayInApp() {
        for name in ["voice-note.m4a", "clip.mp3", "take.wav", "sound.aiff",
                     "movie.mov", "screen.mp4", "Clip.MP4", "phone.m4v",
                     "web.webm", "Recording.WEBM", "film.mkv"] {
            XCTAssertTrue(MacAttachmentOpener.playsInApp(url(name)), name)
        }
    }

    func testEverythingElseOpensExternally() {
        for name in ["report.pdf", "notes.txt", "photo.png", "archive.zip", "attachment"] {
            XCTAssertFalse(MacAttachmentOpener.playsInApp(url(name)), name)
        }
    }

    func testPreviewKnowsVideoFromAudio() {
        XCTAssertEqual(preview("screen.mp4")?.isVideo, true)
        XCTAssertEqual(preview("movie.mov")?.isVideo, true)
        XCTAssertEqual(preview("screen.webm")?.isVideo, true)
        XCTAssertEqual(preview("voice-note.m4a")?.isVideo, false)
        XCTAssertEqual(preview("clip.mp3")?.isVideo, false)
    }

    func testUnnamedAttachmentKeepsItsTypeFromMime() {
        XCTAssertEqual(MacAttachmentOpener.fallbackFilename(mime: "audio/mp4"), "attachment.m4a")
        XCTAssertEqual(MacAttachmentOpener.fallbackFilename(mime: "audio/mpeg"), "attachment.mp3")
        XCTAssertEqual(MacAttachmentOpener.fallbackFilename(mime: "video/quicktime"), "attachment.mov")
        XCTAssertEqual(MacAttachmentOpener.fallbackFilename(mime: "video/webm"), "attachment.webm")
        XCTAssertEqual(MacAttachmentOpener.fallbackFilename(mime: "video/x-matroska"), "attachment.mkv")
        XCTAssertEqual(MacAttachmentOpener.fallbackFilename(mime: "application/x-nonsense"), "attachment")
        // A voice note sent without a name still plays in the app, as audio.
        let voice = MacAttachmentOpener.fallbackFilename(mime: "audio/mp4")
        XCTAssertTrue(MacAttachmentOpener.playsInApp(url(voice)))
        XCTAssertEqual(preview(voice)?.isVideo, false)
    }

    @MainActor
    func testPlayableClickOpensThePlayerBeforeTheFetch() {
        var shown: MediaPlayerPreview?
        var fetched = false
        MacAttachmentOpener.open(filename: "screen.webm", mime: "video/webm",
                                 load: { fetched = true; return nil },
                                 preview: { shown = $0 })
        XCTAssertEqual(shown?.playback, .web(sourceType: "video/webm"))
        XCTAssertFalse(fetched, "the player sheet runs the fetch itself")
    }

    func testWebPageDeclaresTheSourceTypeAndReportsErrors() {
        let page = WebMediaPlayer.page(fileName: "Screen recording #2.mkv", sourceType: "video/webm", isVideo: true)
        XCTAssertTrue(page.contains(#"<video controls autoplay playsinline><source src="Screen%20recording%20%232.mkv" type="video/webm">"#))
        XCTAssertTrue(page.contains("messageHandlers.matron.postMessage('error')"))
        XCTAssertTrue(page.contains("default-src 'none'"), "the page makes no network requests")
        let audio = WebMediaPlayer.page(fileName: "song.weba", sourceType: "audio/webm", isVideo: false)
        XCTAssertTrue(audio.contains("<audio controls autoplay>"))
    }
}

/// The WebKit player's failure callback captures the sheet's state, which
/// holds the player: `stop()` must let go of it, or the pair leaks.
final class WebMediaPlayerTests: XCTestCase {
    @MainActor
    func testStopReleasesTheFailureCallback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("clip.webm")
        try Data().write(to: file)

        var sentinel: NSObject? = NSObject()
        weak var weakSentinel = sentinel
        let player: WebMediaPlayer = autoreleasepool {
            WebMediaPlayer(file: file, sourceType: "video/webm", isVideo: true,
                           onFailure: { [sentinel] in _ = sentinel })
        }
        sentinel = nil
        XCTAssertNotNil(weakSentinel, "the callback holds it while the player plays")
        autoreleasepool { player.stop() }
        XCTAssertNil(weakSentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: WebMediaPlayer.pageURL(for: file).path))
    }
}
