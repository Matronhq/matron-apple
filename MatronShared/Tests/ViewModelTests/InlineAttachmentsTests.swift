import XCTest
import MatronModels

/// The shared inline-images spec's test vectors, plus the edges around
/// them. Every Matron client splits a body the same way.
final class InlineAttachmentsTests: XCTestCase {
    private let aa11 = TrackerAttachment(blobRef: "aa11", mime: "image/png", name: "login.png", size: 10)
    private let bb22 = TrackerAttachment(blobRef: "bb22", mime: "image/png", name: "other.png", size: 20)
    private let pdf = TrackerAttachment(blobRef: "cc33", mime: "application/pdf", name: "spec.pdf", size: 30)

    // MARK: - The spec's eight vectors

    func testVector1_textAttachmentText_unusedTrails() {
        let split = splitInlineAttachments(body: "Before\n\n![login](attachment:aa11)\n\nAfter", attachments: [aa11, bb22])
        XCTAssertEqual(split.segments, [.text("Before"), .attachment(aa11), .text("After")])
        XCTAssertEqual(split.trailing, [bb22])
    }

    func testVector2_unresolvedRefBecomesCaptionText() {
        let split = splitInlineAttachments(body: "See ![x](attachment:zz99) here", attachments: [aa11])
        XCTAssertEqual(split.segments, [.text("See x here")])
        XCTAssertEqual(split.trailing, [aa11])
    }

    func testVector3_secondRefToTheSameBlobIsCaptionText() {
        let split = splitInlineAttachments(body: "![a](attachment:aa11) and again ![b](attachment:aa11)", attachments: [aa11])
        XCTAssertEqual(split.segments, [.attachment(aa11), .text("and again b")])
        XCTAssertEqual(split.trailing, [])
    }

    func testVector4_refInsideAFencedBlockIsLiteral() {
        let body = "```\n![a](attachment:aa11)\n```"
        let split = splitInlineAttachments(body: body, attachments: [aa11])
        XCTAssertEqual(split.segments, [.text(body)])
        XCTAssertEqual(split.trailing, [aa11])
    }

    func testVector5_refInsideAnInlineCodeSpanIsLiteral() {
        let body = "`![a](attachment:aa11)`"
        let split = splitInlineAttachments(body: body, attachments: [aa11])
        XCTAssertEqual(split.segments, [.text(body)])
        XCTAssertEqual(split.trailing, [aa11])
    }

    func testVector6_emptyBodyTrailsEveryAttachment() {
        let split = splitInlineAttachments(body: "", attachments: [aa11, bb22])
        XCTAssertEqual(split.segments, [])
        XCTAssertEqual(split.trailing, [aa11, bb22])
    }

    func testVector7_emptyCaptionRef() {
        let split = splitInlineAttachments(body: "![](attachment:aa11)", attachments: [aa11])
        XCTAssertEqual(split.segments, [.attachment(aa11)])
        XCTAssertEqual(split.trailing, [])
    }

    func testVector8_codeSpanWhollyInsideTheCaptionDoesNotHideTheRef() {
        let split = splitInlineAttachments(body: "![run `make`](attachment:aa11)", attachments: [aa11])
        XCTAssertEqual(split.segments, [.attachment(aa11)])
        XCTAssertEqual(split.trailing, [])
        XCTAssertEqual(inlineAttachmentPlainText("![run `make`](attachment:aa11)"), "run `make`",
                       "the caption, backticks and all")
    }

    // MARK: - Edges

    func testUnresolvedEmptyCaptionRendersNothing() {
        let split = splitInlineAttachments(body: "![](attachment:zz99)", attachments: [])
        XCTAssertEqual(split.segments, [])
        XCTAssertEqual(split.trailing, [])
    }

    func testBodyWithoutRefsIsOneUntouchedSegment() {
        let body = "# Title\n\n- one\n- two\n\n    indented code"
        let split = splitInlineAttachments(body: body, attachments: [pdf])
        XCTAssertEqual(split.segments, [.text(body)])
        XCTAssertEqual(split.trailing, [pdf])
    }

    func testNonImageAttachmentCanBePlacedInline() {
        let split = splitInlineAttachments(body: "Spec: ![spec](attachment:cc33)", attachments: [pdf])
        XCTAssertEqual(split.segments, [.text("Spec:"), .attachment(pdf)])
        XCTAssertEqual(split.trailing, [])
    }

    func testTwoAttachmentsInARowDropTheBlankBetweenThem() {
        let split = splitInlineAttachments(body: "![a](attachment:aa11)\n\n![b](attachment:bb22)", attachments: [aa11, bb22])
        XCTAssertEqual(split.segments, [.attachment(aa11), .attachment(bb22)])
        XCTAssertEqual(split.textSegmentCount, 0)
    }

    func testTildeFenceAndCodeAfterItClosesAgain() {
        let body = "~~~\n![a](attachment:aa11)\n~~~\n![b](attachment:aa11)"
        let split = splitInlineAttachments(body: body, attachments: [aa11])
        XCTAssertEqual(split.segments, [.text("~~~\n![a](attachment:aa11)\n~~~"), .attachment(aa11)])
        XCTAssertEqual(split.trailing, [])
    }

    func testBacktickFenceIsNotClosedByTildes() {
        let body = "```\n~~~\n![a](attachment:aa11)\n```"
        let split = splitInlineAttachments(body: body, attachments: [aa11])
        XCTAssertEqual(split.segments, [.text(body)])
    }

    func testFenceClosesOnlyOnALongEnoughBareRun() {
        // A shorter run, or a run with text after it, sits inside the
        // block (CommonMark) — the ref under it stays literal.
        let longer = "````\n```\n![a](attachment:aa11)\n````"
        XCTAssertEqual(splitInlineAttachments(body: longer, attachments: [aa11]).segments, [.text(longer)])
        let info = "```\n```swift\n![a](attachment:aa11)\n```"
        XCTAssertEqual(splitInlineAttachments(body: info, attachments: [aa11]).segments, [.text(info)])
        let closed = "```swift\ncode\n```  \n![a](attachment:aa11)"
        XCTAssertEqual(splitInlineAttachments(body: closed, attachments: [aa11]).segments,
                       [.text("```swift\ncode\n```"), .attachment(aa11)])
    }

    func testUnclosedBacktickIsLiteralAndTheRefStillMatches() {
        let split = splitInlineAttachments(body: "a ` b ![x](attachment:aa11)", attachments: [aa11])
        XCTAssertEqual(split.segments, [.text("a ` b"), .attachment(aa11)])
    }

    func testOverlongOrMalformedRefsAreLiteral() {
        let long = String(repeating: "a", count: 129)
        for body in ["![x](attachment:\(long))", "![x](attachment:)", "![x](attachment:a b)", "![x\ny](attachment:aa11)",
                     "![x](attachment:aa11", "[x](attachment:aa11)"] {
            let split = splitInlineAttachments(body: body, attachments: [aa11])
            XCTAssertEqual(split.segments, [.text(body)], body)
            XCTAssertEqual(split.trailing, [aa11], body)
        }
    }

    func testCodeSpanOpeningInsideTheRefAndRunningPastItHidesTheRef() {
        let body = "![a `b](attachment:aa11) c`"
        let split = splitInlineAttachments(body: body, attachments: [aa11])
        XCTAssertEqual(split.segments, [.text(body)])
        XCTAssertEqual(split.trailing, [aa11])
    }

    func testCodeSpanCoveringTheRefStartHidesIt() {
        let body = "x `y ![a](attachment:aa11)` z"
        let split = splitInlineAttachments(body: body, attachments: [aa11])
        XCTAssertEqual(split.segments, [.text(body)])
    }

    func testCodeSpanBeforeTheRefLeavesItAlone() {
        let split = splitInlineAttachments(body: "`code` then ![a](attachment:aa11)", attachments: [aa11])
        XCTAssertEqual(split.segments, [.text("`code` then"), .attachment(aa11)])
    }

    func testMaxLengthRefResolves() {
        let ref = String(repeating: "Z", count: 128)
        let a = TrackerAttachment(blobRef: ref, mime: "image/png", name: "", size: 1)
        XCTAssertEqual(splitInlineAttachments(body: "![](attachment:\(ref))", attachments: [a]).segments, [.attachment(a)])
    }

    func testCRLFBodies() {
        let split = splitInlineAttachments(body: "Before\r\n\r\n![a](attachment:aa11)\r\n\r\nAfter", attachments: [aa11])
        XCTAssertEqual(split.segments, [.text("Before"), .attachment(aa11), .text("After")])
    }

    func testRefOnlyResolvesAgainstItsOwnAttachments() {
        // A comment's ref to the item body's attachment is not this
        // comment's attachment: caption text, never fetched.
        let split = splitInlineAttachments(body: "![body pic](attachment:aa11)", attachments: [bb22])
        XCTAssertEqual(split.segments, [.text("body pic")])
        XCTAssertEqual(split.trailing, [bb22])
    }

    // MARK: - Plain text

    func testPlainTextUsesCaptionsOrImage() {
        XCTAssertEqual(inlineAttachmentPlainText("See ![login](attachment:aa11) and ![](attachment:bb22)."),
                       "See login and (image).")
        XCTAssertEqual(inlineAttachmentPlainText("`![a](attachment:aa11)`"), "`![a](attachment:aa11)`")
        XCTAssertEqual(inlineAttachmentPlainText("No refs"), "No refs")
    }
}
