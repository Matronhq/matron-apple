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

    /// Four spaces (or a tab) of indentation make an indented code block,
    /// where a definition-shaped line is content (CodeRabbit, PR #183).
    func test_indentedCodeIsLeftAlone() {
        for body in ["    [ref]: value", "\t[ref]: value", "para\n\n    [ref]: value"] {
            XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(body), body)
        }
        // Up to three spaces is still a paragraph line, and is escaped.
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("   [ref]: value"), "   \\[ref]: value")
    }

    /// A fence closes only on a run of the same character at least as long
    /// as the one that opened it — three backticks inside a four-backtick
    /// fence are content, not a closer.
    func test_longerFenceIsNotClosedByAShorterRun() {
        let body = "````\n```\n[ref]: x\n````\n[ref]: y"
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(body),
                       "````\n```\n[ref]: x\n````\n\\[ref]: y")
        let tilde = "~~~\n[ref]: x\n```\n[ref]: y\n~~~\n[ref]: z"
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(tilde),
                       "~~~\n[ref]: x\n```\n[ref]: y\n~~~\n\\[ref]: z",
                       "a backtick run does not close a tilde fence")
    }

    /// A definition inside a block quote or after a list marker is still a
    /// definition to CommonMark (Bugbot, PR #183) — a quoted voice note or
    /// a labelled list item vanished the same way.
    func test_definitionsBehindContainerPrefixesAreEscaped() {
        let cases: [(String, String)] = [
            ("> [Voice note transcription]: Hello.", "> \\[Voice note transcription]: Hello."),
            (">[x]: y", ">\\[x]: y"),
            ("> > [x]: y", "> > \\[x]: y"),
            ("- [x]: y", "- \\[x]: y"),
            ("* [x]: y", "* \\[x]: y"),
            ("1. [x]: y", "1. \\[x]: y"),
            ("2) [x]: y", "2) \\[x]: y"),
            ("> - [x]: y", "> - \\[x]: y"),
        ]
        for (body, expected) in cases {
            XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(body), expected, body)
        }
    }

    /// A fence opened behind a quote marker is a fence; its lines are
    /// content even when they look like definitions (Bugbot, PR #183).
    func test_fencesBehindContainerPrefixesAreHonoured() {
        for body in ["> ```\n> [x]: y\n> ```", "> > ~~~\n> > [x]: y\n> > ~~~", "- ```\n  [x]: y\n  ```"] {
            XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(body), body, body)
        }
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("> ```\n> [x]: y\n> ```\n> [x]: y"),
                       "> ```\n> [x]: y\n> ```\n> \\[x]: y", "after the quoted fence closes, a definition is escaped again")
    }

    /// Up to three spaces after a marker are still the same paragraph
    /// line; four or more make indented code inside the container.
    func test_indentAfterContainerPrefixes() {
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(">   [x]: y"), ">   \\[x]: y")
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("-   [x]: y"), "-   \\[x]: y")
        for body in [">     [x]: y", "-      [x]: y"] {
            XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(body), body, body)
        }
    }

    /// A fence lives inside its container: leaving the quote ends the
    /// fence, a deeper-nested line is still content, and only a closer at
    /// the fence's own level closes it (Bugbot round 3, PR #183).
    func test_fenceStateFollowsContainerBoundaries() {
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("> ```\n[x]: y"), "> ```\n\\[x]: y",
                       "an unprefixed line ends the quote, and the fence with it")
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("> ```\n> > [x]: y\n> ```\n> [x]: y"),
                       "> ```\n> > [x]: y\n> ```\n> \\[x]: y", "a deeper-nested line inside the quoted fence is content")
        let realFence = "```\n> ```\n[x]: y\n```"
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(realFence), realFence,
                       "a quoted fence line inside an unquoted fence is content, not a closer")
    }

    /// An indented-code line with no quote marker still exits the quote,
    /// and the fence with it (Bugbot round 4, PR #183).
    func test_indentedLineExitingTheQuoteEndsItsFence() {
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("> ```\n    code\n> [x]: y"),
                       "> ```\n    code\n> \\[x]: y")
        let stillInside = "> ```\n>     code\n> [x]: y\n> ```"
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(stillInside), stillInside,
                       "an indented line that keeps the quote marker is fence content")
    }

    /// A nested marker may sit behind up to three spaces of the previous
    /// marker's content indent.
    func test_nestedMarkersBehindLeftoverIndent() {
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("-   > [x]: y"), "-   > \\[x]: y")
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("1.  - [x]: y"), "1.  - \\[x]: y")
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(">  - [x]: y"), ">  - \\[x]: y")
    }

    func test_taskListItemsAndBlankLabelsAreNotDefinitions() {
        for body in ["- [x] done", "- [ ] todo", "[ ]: blank label", "- [ ]: blank label"] {
            XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(body), body, body)
        }
    }

    func test_ordinaryBodiesPassThroughUntouched() {
        for body in ["plain", "[link](u)", "[x] not a definition", "a: b", "[]: empty label", ""] {
            XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(body), body)
        }
    }
}
