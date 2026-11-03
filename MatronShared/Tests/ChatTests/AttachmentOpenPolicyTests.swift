import XCTest
import MatronModels

final class AttachmentOpenPolicyTests: XCTestCase {
    func testEverydayDocumentsOpenStraightAway() {
        for name in ["photo.jpg", "scan.PNG", "report.pdf", "notes.txt", "README.md", "data.csv", "data.json",
                     "budget.xlsx", "deck.key", "letter.docx", "clip.mov", "voice.m4a", "server.log"] {
            XCTAssertTrue(AttachmentOpenPolicy.opensWithoutAsking(filename: name), name)
        }
    }

    func testAnythingThatCanRunOrHandOffIsConfirmed() {
        for name in ["setup.command", "run.sh", "profile.terminal", "Thing.app", "install.pkg", "disk.dmg",
                     "page.html", "page.htm", "link.webloc", "link.inetloc", "place.fileloc", "logo.svg",
                     "settings.plist", "bundle.zip", "script.applescript", "tool.py", "noextension", "odd.zzqq"] {
            XCTAssertFalse(AttachmentOpenPolicy.opensWithoutAsking(filename: name), name)
        }
    }

    func testVisibleFilenameDropsInvisibleControls() {
        let spoofed = "report\u{202E}fdp.command"
        XCTAssertEqual(AttachmentOpenPolicy.visibleFilename(spoofed), "reportfdp.command")
        XCTAssertFalse(AttachmentOpenPolicy.opensWithoutAsking(filename: spoofed))
        XCTAssertEqual(AttachmentOpenPolicy.visibleFilename("a\u{2066}b\u{200B}c\u{0007}.txt"), "abc.txt")
        XCTAssertEqual(AttachmentOpenPolicy.visibleFilename("Résumé 日本.pdf"), "Résumé 日本.pdf")
    }
}
