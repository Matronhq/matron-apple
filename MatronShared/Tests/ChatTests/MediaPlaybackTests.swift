import XCTest
import MatronModels

/// Which attachments the Mac plays in place, and with which engine.
final class MediaPlaybackTests: XCTestCase {
    func testAVFoundationFormatsPlayNatively() {
        for name in ["voice-note.m4a", "clip.mp3", "take.wav", "sound.aiff"] {
            XCTAssertEqual(MediaPlayback.engine(filename: name), .native(isVideo: false), name)
        }
        for name in ["movie.mov", "screen.mp4", "Clip.MP4", "phone.m4v"] {
            XCTAssertEqual(MediaPlayback.engine(filename: name), .native(isVideo: true), name)
        }
    }

    func testWebMAndMatroskaPlayInWebKitAsWebM() {
        XCTAssertEqual(MediaPlayback.engine(filename: "screen.webm"), .web(sourceType: "video/webm"))
        XCTAssertEqual(MediaPlayback.engine(filename: "Recording.WEBM"), .web(sourceType: "video/webm"))
        XCTAssertEqual(MediaPlayback.engine(filename: "film.mkv"), .web(sourceType: "video/webm"))
        XCTAssertEqual(MediaPlayback.engine(filename: "song.weba"), .web(sourceType: "audio/webm"))
        XCTAssertTrue(MediaPlayback.web(sourceType: "video/webm").isVideo)
        XCTAssertFalse(MediaPlayback.web(sourceType: "audio/webm").isVideo)
    }

    func testOtherFilesAreNotPlayable() {
        for name in ["report.pdf", "notes.txt", "photo.png", "archive.zip", "attachment"] {
            XCTAssertNil(MediaPlayback.engine(filename: name), name)
        }
    }

    func testExtensionlessFileIsJudgedByMime() {
        XCTAssertEqual(MediaPlayback.engine(filename: "Screen recording", mime: "video/webm"),
                       .web(sourceType: "video/webm"))
        XCTAssertEqual(MediaPlayback.engine(filename: "", mime: "video/x-matroska"), .web(sourceType: "video/webm"))
        XCTAssertEqual(MediaPlayback.engine(filename: "", mime: "video/mp4; codecs=avc1"), .native(isVideo: true))
        XCTAssertNil(MediaPlayback.engine(filename: "", mime: "application/pdf"))
        // The name's extension wins over a generic MIME type.
        XCTAssertEqual(MediaPlayback.engine(filename: "clip.mov", mime: "application/octet-stream"),
                       .native(isVideo: true))
    }
}
