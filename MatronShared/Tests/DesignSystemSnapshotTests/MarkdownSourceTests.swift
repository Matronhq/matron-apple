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

    /// Inside a list item, continuation is expressed as indentation; an
    /// indented line that still carries the quote marker continues the
    /// quote and its fence (Bugbot round 5, PR #183).
    func test_indentedQuoteContinuationKeepsTheFenceOpen() {
        let body = "- > ```\n    > [x]: a\n  > [x]: b\n  > ```"
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(body), body)
    }

    /// At document level, four columns of indentation are indented code,
    /// so a `>` behind them is content and the quote — with its fence —
    /// has ended. Inside a list item the same columns are the item's
    /// continuation and the marker is real (Bugbot round 7, PR #183).
    func test_indentedQuoteMarkerOnlyContinuesAQuoteInsideAListItem() {
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("> ```\n    > code\n> [x]: y"),
                       "> ```\n    > code\n> \\[x]: y")
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("- > ```\n    > [x]: y\n  > ```\n  > [x]: z"),
                       "- > ```\n    > [x]: y\n  > ```\n  > \\[x]: z")
    }

    /// Indentation is measured from the enclosing item's content offset,
    /// not from the line start: a fence closer up to three columns past
    /// that offset closes, four or more make it content, and a definition
    /// four columns in on a `- ` item is a two-column paragraph line
    /// (Bugbot round 7, PR #183).
    func test_indentationIsMeasuredFromTheListItemContentOffset() {
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("- ```\n     ```\n  [x]: y"),
                       "- ```\n     ```\n  \\[x]: y", "a closer three columns past the content offset closes")
        let stillOpen = "- ```\n      ```\n  [x]: y"
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(stillOpen), stillOpen, "four columns past it is content")
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("- item\n\n    [x]: y"), "- item\n\n    \\[x]: y")
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("- item\n\n      [x]: y"), "- item\n\n      [x]: y",
                       "six columns are four past the offset: indented code")
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("- item\n    ```\n    [x]: y\n    ```\n    [x]: z"),
                       "- item\n    ```\n    [x]: y\n    ```\n    \\[x]: z", "a fence two columns into the item opens and closes")
    }

    /// A blank line keeps a list item open but ends a block quote; an
    /// under-indented line ends the item.
    func test_blankAndUnderIndentedLinesCloseTheRightContainers() {
        let itemFence = "- ```\n\n  [x]: y\n  ```"
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(itemFence), itemFence, "a blank line is fence content inside the item")
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("> ```\n\n> [x]: y"), "> ```\n\n> \\[x]: y",
                       "a blank line ends the quote and its fence")
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("- ```\n [x]: y"), "- ```\n \\[x]: y",
                       "one column is not the item's continuation")
    }

    /// A tab after a quote marker is the marker's padding, not indented
    /// code: the definition behind it is a paragraph line (CodeRabbit,
    /// PR #183). A second tab is four more columns, and code.
    func test_tabAfterQuoteMarkerIsPadding() {
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(">\t[x]: y"), ">\t\\[x]: y")
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("> ```\n>\t[x]: y\n> ```\n>\t[x]: z"),
                       "> ```\n>\t[x]: y\n> ```\n>\t\\[x]: z", "the same inside a continued quote")
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(">\t\t[x]: y"), ">\t\t[x]: y")
    }

    /// Tabs advance to the next multiple of four columns, so a tab is one
    /// to four columns depending on where it sits, and consuming a list
    /// item's offset out of a tab leaves the remainder as indent (Bugbot
    /// round 8, PR #183).
    func test_tabsAreMeasuredAgainstTabStops() {
        let stillOpen = "- ```\n\t  ```\n  [x]: y"
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(stillOpen), stillOpen,
                       "a tab past a two-column offset leaves two columns, plus two spaces: not a closer")
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("- ```\n\t```\n  [x]: y"), "- ```\n\t```\n  \\[x]: y",
                       "the same tab alone leaves two columns: a closer")
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("1.\t[x]: a\n\n    [x]: b"), "1.\t\\[x]: a\n\n    \\[x]: b",
                       "a tab after a two-character marker is two columns: content offset four")
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("- item\n\n\t[x]: y"), "- item\n\n\t\\[x]: y")
        XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions("-\t[x]: y"), "-\t\\[x]: y")
        for body in ["  \t[x]: y", " \t> [x]: y"] {
            XCTAssertEqual(MarkdownSource.escapingReferenceDefinitions(body), body, body)
        }
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
