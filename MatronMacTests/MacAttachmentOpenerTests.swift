import XCTest
@testable import MatronMac

/// Which downloaded attachments play in the app's own player rather than
/// going to the default app (which for audio was Music).
final class MacAttachmentOpenerTests: XCTestCase {
    private func url(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    func testAudioAndVideoPlayInApp() {
        for name in ["voice-note.m4a", "clip.mp3", "take.wav", "sound.aiff",
                     "movie.mov", "screen.mp4", "Clip.MP4", "phone.m4v"] {
            XCTAssertTrue(MacAttachmentOpener.playsInApp(url(name)), name)
        }
    }

    func testEverythingElseOpensExternally() {
        for name in ["report.pdf", "notes.txt", "photo.png", "archive.zip",
                     "attachment", "web.webm", "film.mkv"] {
            XCTAssertFalse(MacAttachmentOpener.playsInApp(url(name)), name)
        }
    }

    func testPreviewKnowsVideoFromAudio() {
        XCTAssertTrue(MediaPlayerPreview(url: url("screen.mp4"), filename: "screen.mp4").isVideo)
        XCTAssertTrue(MediaPlayerPreview(url: url("movie.mov"), filename: "movie.mov").isVideo)
        XCTAssertFalse(MediaPlayerPreview(url: url("voice-note.m4a"), filename: "voice-note.m4a").isVideo)
        XCTAssertFalse(MediaPlayerPreview(url: url("clip.mp3"), filename: "clip.mp3").isVideo)
    }

    func testUnnamedAttachmentKeepsItsTypeFromMime() {
        XCTAssertEqual(MacAttachmentOpener.fallbackFilename(mime: "audio/mp4"), "attachment.m4a")
        XCTAssertEqual(MacAttachmentOpener.fallbackFilename(mime: "audio/mpeg"), "attachment.mp3")
        XCTAssertEqual(MacAttachmentOpener.fallbackFilename(mime: "video/quicktime"), "attachment.mov")
        XCTAssertEqual(MacAttachmentOpener.fallbackFilename(mime: "application/x-nonsense"), "attachment")
        // A voice note sent without a name still plays in the app, as audio.
        let voice = url(MacAttachmentOpener.fallbackFilename(mime: "audio/mp4"))
        XCTAssertTrue(MacAttachmentOpener.playsInApp(voice))
        XCTAssertFalse(MediaPlayerPreview(url: voice, filename: "Voice note").isVideo)
    }
}
