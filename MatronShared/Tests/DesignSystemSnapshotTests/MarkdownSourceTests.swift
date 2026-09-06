import XCTest
@testable import MatronDesignSystem

/// A chat body that happens to be a CommonMark link reference definition
/// (`[label]: destination`) renders as NOTHING — the bridge's voice-note
/// mirror "[Voice note transcription]: Hello." vanished into an empty
/// bubble on the Mac (2026-09-06). Chat bodies are prose, never a
/// reference definition, so such lines are escaped before either renderer
/// sees them.
final class MarkdownSourceTests: XCTestCase {
    func test_referenceDefinitionLine_isEscapedToLiteralText() {
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("[Voice note transcription]: Hello."),
                       "\\[Voice note transcription]: Hello.")
    }

    func test_onlyDefinitionLinesChange_inAMultilineBody() {
        let body = "First line\n[TODO]: fix the build\n  [x]: y\nA [real link](https://a.b) stays"
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(body),
                       "First line\n\\[TODO]: fix the build\n  \\[x]: y\nA [real link](https://a.b) stays")
    }

    func test_fencedCodeIsLeftAlone() {
        let body = "```\n[ref]: http://x\n```\n[ref]: http://x"
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(body),
                       "```\n[ref]: http://x\n```\n\\[ref]: http://x")
    }

    func test_ordinaryBodiesPassThroughUntouched() {
        for body in ["plain", "[link](u)", "[x] not a definition", "a: b", "[]: empty label", ""] {
            XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(body), body)
        }
    }
}
