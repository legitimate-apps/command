//
//  MarkdownSyntaxTests.swift
//  CommandTests
//
//  The live-styled note editor is only as good as its tokenizer, and a tokenizer is exactly the
//  kind of thing that looks right on screen while being off by one. These tests pin the SOURCE
//  RANGES deterministically — no UIKit, no simulator — so a styling regression fails here first.
//

import XCTest
@testable import Command

final class MarkdownSyntaxTests: XCTestCase {

    // MARK: Helpers

    private func spans(_ s: String) -> [MDSpan] {
        MarkdownSyntax.spans(in: s as NSString)
    }

    /// The substring a span covers — asserting on text instead of raw integers keeps these
    /// readable and catches off-by-one directly.
    private func text(_ span: MDSpan, in s: String) -> String {
        (s as NSString).substring(with: span.range)
    }

    private func first(_ kind: MDStyleKind, in s: String) -> MDSpan? {
        spans(s).first { $0.kind == kind }
    }

    private func all(_ kind: MDStyleKind, in s: String) -> [MDSpan] {
        spans(s).filter { $0.kind == kind }
    }

    // MARK: Line splitting

    func testLineRangesExcludeNewlineAndCoverEveryLine() {
        let s = "one\ntwo\n\nfour"
        let ranges = MarkdownSyntax.lineRanges(of: s as NSString)
        XCTAssertEqual(ranges.count, 4)
        XCTAssertEqual((s as NSString).substring(with: ranges[0]), "one")
        XCTAssertEqual((s as NSString).substring(with: ranges[1]), "two")
        XCTAssertEqual((s as NSString).substring(with: ranges[2]), "")
        XCTAssertEqual((s as NSString).substring(with: ranges[3]), "four")
    }

    func testEmptyTextProducesNoSpans() {
        XCTAssertTrue(spans("").isEmpty)
    }

    // MARK: The title convention

    func testFirstLineIsAlwaysTitle() {
        let s = "My note\nbody text"
        let title = first(.title, in: s)
        XCTAssertEqual(text(title!, in: s), "My note")
        // ...and the second line is NOT a title.
        XCTAssertEqual(all(.title, in: s).count, 1)
    }

    func testHashOnTitleLineStillDimsItsMarker() {
        let s = "# Big title\nbody"
        XCTAssertNotNil(first(.title, in: s))
        let marker = first(.syntaxMarker, in: s)
        XCTAssertEqual(text(marker!, in: s), "# ")
    }

    // MARK: Headings

    func testHeadingLevelsAndMarker() {
        let s = "t\n## Section\n### Deeper"
        let headings = all(.heading, in: s)
        XCTAssertEqual(headings.count, 2)
        XCTAssertEqual(headings[0].level, 2)
        XCTAssertEqual(text(headings[0], in: s), "## Section")
        XCTAssertEqual(headings[1].level, 3)

        let markers = all(.syntaxMarker, in: s)
        XCTAssertEqual(text(markers[0], in: s), "## ")
        XCTAssertEqual(text(markers[1], in: s), "### ")
    }

    func testHashTagIsNotAHeading() {
        // `#project` is a tag people type in notes; it must stay body text.
        let s = "t\n#project notes"
        XCTAssertTrue(all(.heading, in: s).isEmpty)
    }

    func testSevenHashesIsNotAHeading() {
        let s = "t\n####### too deep"
        XCTAssertTrue(all(.heading, in: s).isEmpty)
    }

    // MARK: Emphasis

    func testBoldContentAndMarkers() {
        let s = "t\nsome **strong** words"
        let bold = first(.bold, in: s)
        XCTAssertEqual(text(bold!, in: s), "strong")
        let markers = all(.syntaxMarker, in: s)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(text(markers[0], in: s), "**")
        XCTAssertEqual(text(markers[1], in: s), "**")
    }

    func testItalicWithUnderscoreAndAsterisk() {
        let a = "t\nan *slanted* word"
        XCTAssertEqual(text(first(.italic, in: a)!, in: a), "slanted")
        let b = "t\nan _slanted_ word"
        XCTAssertEqual(text(first(.italic, in: b)!, in: b), "slanted")
    }

    func testBoldItalicTripleAsteriskDoesNotDegradeToBold() {
        let s = "t\n***both*** here"
        XCTAssertEqual(text(first(.boldItalic, in: s)!, in: s), "both")
        XCTAssertTrue(all(.bold, in: s).isEmpty, "*** must not also match as **")
    }

    func testStrikethrough() {
        let s = "t\n~~gone~~ now"
        XCTAssertEqual(text(first(.strikethrough, in: s)!, in: s), "gone")
    }

    func testUnmatchedDelimiterStaysPlain() {
        let s = "t\na ** dangling"
        XCTAssertTrue(all(.bold, in: s).isEmpty)
        XCTAssertTrue(all(.syntaxMarker, in: s).isEmpty)
    }

    func testOpeningDelimiterFollowedBySpaceIsNotEmphasis() {
        // "2 * 3 * 4" is arithmetic, not italics — a very common false positive in notes.
        let s = "t\n2 * 3 * 4"
        XCTAssertTrue(all(.italic, in: s).isEmpty)
    }

    // MARK: Code

    func testInlineCodeClaimsItsContents() {
        let s = "t\nrun `make **all**` now"
        let code = first(.inlineCode, in: s)
        XCTAssertEqual(text(code!, in: s), "`make **all**`")
        XCTAssertTrue(all(.bold, in: s).isEmpty, "emphasis inside a code span must stay literal")
    }

    func testFencedCodeBlockCoversEveryLineAndSuppressesInline() {
        let s = "t\n```swift\nlet x = **not bold**\n```\nafter"
        let code = all(.codeBlock, in: s)
        XCTAssertEqual(code.count, 1, "only the line BETWEEN the fences is code body")
        XCTAssertEqual(text(code[0], in: s), "let x = **not bold**")
        XCTAssertTrue(all(.bold, in: s).isEmpty)

        // The fences are their own kind, tagged opening (1) / closing (2) so they can carry the
        // block's outer spacing.
        let fences = all(.codeFence, in: s)
        XCTAssertEqual(fences.count, 2)
        XCTAssertEqual(fences[0].level, 1)
        XCTAssertEqual(fences[1].level, 2)

        // The line after the closing fence is back to normal body text.
        XCTAssertTrue(spans(s).contains { $0.kind == .body && self.text($0, in: s) == "after" })
    }

    // MARK: Lists

    func testBulletMarker() {
        let s = "t\n- first\n- second"
        let markers = all(.bulletMarker, in: s)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(text(markers[0], in: s), "- ")
    }

    func testOrderedMarkerBothDelimiters() {
        let s = "t\n1. one\n2) two"
        let markers = all(.orderedMarker, in: s)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(text(markers[0], in: s), "1. ")
        XCTAssertEqual(text(markers[1], in: s), "2) ")
    }

    func testTaskItemCheckedAndUnchecked() {
        let s = "t\n- [ ] todo\n- [x] done"
        let open = all(.taskBoxUnchecked, in: s)
        let done = all(.taskBoxChecked, in: s)
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(text(open[0], in: s), "- [ ] ")
        XCTAssertEqual(text(done[0], in: s), "- [x] ")
        // The checked item's text is marked so it can be struck through.
        XCTAssertEqual(text(first(.taskCheckedText, in: s)!, in: s), "done")
    }

    func testJustTypedCheckboxWithNoTrailingSpaceStillParses() {
        let s = "t\n- [x]"
        XCTAssertEqual(all(.taskBoxChecked, in: s).count, 1)
    }

    func testListLinesCarryListItemWithNestLevel() {
        let s = "t\n- top\n  - nested\n    - deeper"
        let items = all(.listItem, in: s)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].level, 1)
        XCTAssertEqual(items[1].level, 2)
        XCTAssertEqual(items[2].level, 3)
    }

    func testTaskItemIsNotAlsoAPlainBullet() {
        let s = "t\n- [ ] todo"
        XCTAssertTrue(all(.bulletMarker, in: s).isEmpty)
    }

    // MARK: Links

    func testLinkSplitsLabelFromURL() {
        let s = "t\nsee [the docs](https://example.com) here"
        XCTAssertEqual(text(first(.link, in: s)!, in: s), "the docs")
        // The URL half is plumbing — same dimmed marker treatment as `**` or `#`.
        let markers = all(.syntaxMarker, in: s).map { text($0, in: s) }
        XCTAssertTrue(markers.contains("(https://example.com)"), "got \(markers)")
    }

    func testBracketWithoutParenIsNotALink() {
        let s = "t\na [bracketed] word"
        XCTAssertTrue(all(.link, in: s).isEmpty)
    }

    // MARK: Rules, quotes, tables

    func testHorizontalRule() {
        for line in ["---", "***", "___", "- - -"] {
            let s = "t\n\(line)"
            XCTAssertEqual(all(.rule, in: s).count, 1, "\(line) should be a rule")
        }
    }

    func testTwoDashesIsNotARule() {
        let s = "t\n--"
        XCTAssertTrue(all(.rule, in: s).isEmpty)
    }

    func testBlockquoteDepthAndMarker() {
        let s = "t\n> quoted\n>> deeper"
        let quotes = all(.blockquote, in: s)
        XCTAssertEqual(quotes.count, 2)
        XCTAssertEqual(quotes[0].level, 1)
        XCTAssertEqual(quotes[1].level, 2)
        XCTAssertEqual(text(all(.syntaxMarker, in: s)[0], in: s), "> ")
    }

    func testTableHeaderIsPromotedByTheSeparatorBelowIt() {
        let s = "t\n| a | b |\n| --- | --- |\n| 1 | 2 |"
        XCTAssertEqual(all(.tableHeader, in: s).count, 1, "the row above the separator is the header")
        XCTAssertEqual(text(first(.tableHeader, in: s)!, in: s), "| a | b |")
        XCTAssertEqual(all(.tableSeparator, in: s).count, 1)
        XCTAssertEqual(all(.tableCell, in: s).count, 1, "only the body row stays a plain cell row")
    }

    func testPipeRowWithoutASeparatorStaysAPlainCellRow() {
        let s = "t\n| a | b |"
        XCTAssertEqual(all(.tableCell, in: s).count, 1)
        XCTAssertTrue(all(.tableHeader, in: s).isEmpty)
    }

    // MARK: Unicode safety (the classic off-by-one source)

    func testEmojiBeforeEmphasisKeepsRangesAligned() {
        // A non-BMP scalar is 2 UTF-16 units; if the scanner used Character offsets this drifts.
        let s = "t\n\u{1F600} **bold** tail"
        let bold = first(.bold, in: s)
        XCTAssertEqual(text(bold!, in: s), "bold")
    }

    func testAllSpanRangesStayInBounds() {
        let s = """
        Title with **bold**
        ## Section `code` and [link](https://x.dev)
        - [ ] task with *emphasis*
        > quote
        ```
        fenced **literal**
        ```
        | a | b |
        ---
        \u{1F9EA} trailing unicode ~~strike~~
        """
        let ns = s as NSString
        for span in spans(s) {
            XCTAssertGreaterThanOrEqual(span.range.location, 0, "\(span)")
            XCTAssertLessThanOrEqual(NSMaxRange(span.range), ns.length,
                                     "span \(span.kind) escapes the text")
        }
    }

    // MARK: Plain text (list rows / previews / accessibility)

    func testPlainTextStripsHeadingAndEmphasisPunctuation() {
        let s = "Title\n## Plan\nsome **urgent** and *soft* work"
        let plain = MarkdownSyntax.plainText(s)
        XCTAssertFalse(plain.contains("#"))
        XCTAssertFalse(plain.contains("*"))
        XCTAssertTrue(plain.contains("Plan"))
        XCTAssertTrue(plain.contains("urgent"))
    }

    func testPlainTextKeepsListBulletsButSimplifiesCheckboxes() {
        let s = "t\n- a bullet\n- [x] a done task"
        let plain = MarkdownSyntax.plainText(s)
        XCTAssertTrue(plain.contains("- a bullet"))
        XCTAssertTrue(plain.contains("- a done task"), "got: \(plain)")
        XCTAssertFalse(plain.contains("[x]"))
    }

    func testPlainTextKeepsLinkLabelAndDropsURL() {
        let s = "t\nsee [the docs](https://example.com)"
        let plain = MarkdownSyntax.plainText(s)
        XCTAssertTrue(plain.contains("the docs"))
        XCTAssertFalse(plain.contains("example.com"))
    }

    func testPlainTextDropsRulesAndFences() {
        let s = "t\n---\n```\ncode\n```"
        let plain = MarkdownSyntax.plainText(s)
        XCTAssertFalse(plain.contains("---"))
        XCTAssertFalse(plain.contains("```"))
        XCTAssertTrue(plain.contains("code"), "code CONTENT is still prose worth previewing")
    }

    func testPlainTextSingleLineCollapsesWhitespace() {
        let s = "Title\n\n## A\n\n- one\n- two"
        let plain = MarkdownSyntax.plainText(s, singleLine: true)
        XCTAssertFalse(plain.contains("\n"))
        XCTAssertEqual(plain, "Title A - one - two")
    }

    func testPlainTextOnPlainProseIsUnchanged() {
        let s = "Just a note\nwith two lines"
        XCTAssertEqual(MarkdownSyntax.plainText(s), s)
    }

    // MARK: Editing helpers

    func testListContinuationBullet() {
        let s = "t\n- item"
        let caret = (s as NSString).length
        XCTAssertEqual(MarkdownSyntax.listContinuation(forLineAt: caret, in: s as NSString), "- ")
    }

    func testListContinuationPreservesIndentAndBulletCharacter() {
        let s = "t\n  * item"
        let caret = (s as NSString).length
        XCTAssertEqual(MarkdownSyntax.listContinuation(forLineAt: caret, in: s as NSString), "  * ")
    }

    func testListContinuationIncrementsOrderedNumber() {
        let s = "t\n3. third"
        let caret = (s as NSString).length
        XCTAssertEqual(MarkdownSyntax.listContinuation(forLineAt: caret, in: s as NSString), "4. ")
    }

    func testListContinuationOnTaskGivesUncheckedBox() {
        let s = "t\n- [x] done"
        let caret = (s as NSString).length
        XCTAssertEqual(MarkdownSyntax.listContinuation(forLineAt: caret, in: s as NSString), "- [ ] ")
    }

    func testEmptyListItemReturnsEmptyStringMeaningEndTheList() {
        let s = "t\n- "
        let caret = (s as NSString).length
        XCTAssertEqual(MarkdownSyntax.listContinuation(forLineAt: caret, in: s as NSString), "")
    }

    func testListContinuationNilOnPlainParagraph() {
        let s = "t\njust a sentence"
        let caret = (s as NSString).length
        XCTAssertNil(MarkdownSyntax.listContinuation(forLineAt: caret, in: s as NSString))
    }

    func testListMarkerRangeCoversTheWholeMarker() {
        let s = "t\n  - [ ] "
        let ns = s as NSString
        let range = MarkdownSyntax.listMarkerRange(forLineAt: ns.length, in: ns)
        XCTAssertEqual(ns.substring(with: range!), "  - [ ] ")
    }

    func testTaskToggleFlipsTheBoxBothWays() {
        let unchecked = "t\n- [ ] todo" as NSString
        let onToggle = MarkdownSyntax.taskToggle(forLineAt: unchecked.length, in: unchecked)
        XCTAssertEqual(onToggle?.replacement, "x")
        XCTAssertEqual(unchecked.substring(with: onToggle!.range), " ")

        let checked = "t\n- [x] todo" as NSString
        let offToggle = MarkdownSyntax.taskToggle(forLineAt: checked.length, in: checked)
        XCTAssertEqual(offToggle?.replacement, " ")
        XCTAssertEqual(checked.substring(with: offToggle!.range), "x")
    }

    func testTaskToggleNilOnNonTaskLine() {
        let s = "t\n- plain bullet" as NSString
        XCTAssertNil(MarkdownSyntax.taskToggle(forLineAt: s.length, in: s))
    }

    // MARK: Performance guard (this runs on every keystroke)

    func testTokenizingALongNoteIsFast() {
        let block = """
        ## Section
        Some **bold** and *italic* text with `code` and a [link](https://example.com).
        - [ ] a task
        - a bullet
        > a quote

        """
        let s = String(repeating: block, count: 200) as NSString   // ~1200 lines
        measure { _ = MarkdownSyntax.spans(in: s) }
    }
}
