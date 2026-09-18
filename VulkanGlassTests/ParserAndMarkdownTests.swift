import AppKit
import SwiftUI
import XCTest
@testable import VulkanGlass

final class InlineParserTests: XCTestCase {
    func testUnmatchedWikiOpenerIsLiteralAndTerminates() {
        XCTAssertEqual(InlineRunsView.parse("see [[Foo"), [.text("see [[Foo")])
    }

    func testAliasKeepsNavigationTargetAndDisplayLabelSeparate() {
        XCTAssertEqual(
            InlineRunsView.parse("[[Target|Readable label]]"),
            [.wiki(target: "Target", label: "Readable label")]
        )
    }

    func testHeadingAnchorIsRemovedOnlyFromNavigationTarget() {
        XCTAssertEqual(
            InlineRunsView.parse("[[Target#Section]]"),
            [.wiki(target: "Target", label: "Target#Section")]
        )
    }

    func testEmptyAndMalformedConstructsRemainText() {
        XCTAssertEqual(InlineRunsView.parse("[[]] bare #"), [.text("[[]] bare #")])
    }

    func testImagesAreParsedInEveryInlineContext() {
        XCTAssertEqual(
            InlineRunsView.parse("before ![alt](images/pic.png) after"),
            [.text("before "), .image(alt: "alt", url: "images/pic.png"), .text(" after")]
        )
        XCTAssertEqual(
            InlineRunsView.parse("![cell](pic.png)"),
            [.image(alt: "cell", url: "pic.png")]
        )
    }

    func testGitHubTableInlineFormattingIsParsed() {
        XCTAssertEqual(
            InlineRunsView.parse("**bold** *italic* _also italic_ `git status` ~~old~~"),
            [
                .bold("bold"), .text(" "), .italic("italic"), .text(" "),
                .italic("also italic"), .text(" "), .code("git status"), .text(" "),
                .strikethrough("old")
            ]
        )
        XCTAssertEqual(
            InlineRunsView.parse("\\*literal\\* and ***important***"),
            [.text("*literal* and "), .boldItalic("important")]
        )
    }

    func testEmphasisDelimitersRespectWordAndWhitespaceBoundaries() {
        for value in [
            "snake_case_name",
            "use my_file_name.md here",
            "https://x.com/a_b_c/d_e",
            "2 * 3 * 4",
            "cost: 3*4 and 5*6",
            "__init__",
            "not _ italic_ or _italic _"
        ] {
            XCTAssertEqual(InlineRunsView.parse(value), [.text(value)], value)
        }

        XCTAssertEqual(InlineRunsView.parse("(_italic_)"), [.text("("), .italic("italic"), .text(")")])
        XCTAssertEqual(InlineRunsView.parse("__two words__"), [.bold("two words")])
    }

    func testEscapedClosingDelimiterDoesNotEndEmphasis() {
        XCTAssertEqual(
            InlineRunsView.parse("*not closed\\*"),
            [.text("*not closed*")]
        )
        XCTAssertEqual(
            InlineRunsView.parse("*closed* and \\_literal\\_"),
            [.italic("closed"), .text(" and _literal_")]
        )
    }

    func testNestedEmphasisCombinesTextStyles() {
        XCTAssertEqual(
            InlineRunsView.parse("**bold and _italic_**"),
            [.bold("bold and "), .boldItalic("italic")]
        )
        XCTAssertEqual(
            InlineRunsView.parse("_italic and **bold**_"),
            [.italic("italic and "), .boldItalic("bold")]
        )
    }

    func testStyledTextRunsShareOneLayoutElement() {
        let runs = InlineRunsView.parse("before **bold**, _italic_, and ~~old~~")
        XCTAssertEqual(InlineRunsView.layoutGroups(for: runs), [.text(runs)])

        let withCode = InlineRunsView.parse("before **bold** `code` after")
        XCTAssertEqual(
            InlineRunsView.layoutGroups(for: withCode),
            [
                .text([.text("before "), .bold("bold"), .text(" ")]),
                .element(.code("code")),
                .text([.text(" after")])
            ]
        )
    }

    func testUnderlineHTMLIsRenderedInTheReadingPreview() {
        XCTAssertEqual(
            InlineRunsView.parse("before <u>glass</u> and <INS>clear</ins>"),
            [.text("before "), .underline("glass"), .text(" and "), .underline("clear")]
        )
        let runs = InlineRunsView.parse("<u>glass</u>")
        XCTAssertEqual(InlineRunsView.layoutGroups(for: runs), [.text(runs)])
    }

    func testSubscriptAndSuperscriptHTMLAreRenderedInTheReadingPreview() {
        XCTAssertEqual(
            InlineRunsView.parse("H<sub>2</sub>O and x<SUP>3</sup>"),
            [
                .text("H"), .subscriptText("2"), .text("O and x"),
                .superscriptText("3")
            ]
        )
    }

    func testCoreRawHTMLInlineElementsRenderSemantically() {
        XCTAssertEqual(
            InlineRunsView.parse("<strong>bold</strong> <em>italic</em> <del>old</del> <code>x</code> <kbd>⌘K</kbd> <mark>new</mark> <a href=\"https://example.com\">site</a><br><img alt=\"Glass\" src=\"pic.png\">") ,
            [
                .bold("bold"), .text(" "), .italic("italic"), .text(" "),
                .strikethrough("old"), .text(" "), .code("x"), .text(" "),
                .keyboard("⌘K"), .text(" "), .highlight("new"), .text(" "),
                .link(label: "site", url: "https://example.com"), .text("\n"),
                .image(alt: "Glass", url: "pic.png")
            ]
        )
        XCTAssertEqual(
            InlineRunsView.parse("<a href=\"javascript:alert(1)\">unsafe</a>"),
            [.text("unsafe")]
        )
        XCTAssertNil(SemanticHTML.safeURL("java\tscript:alert(1)", image: false))
        XCTAssertNil(SemanticHTML.safeURL("\u{01}javascript:alert(1)", image: false))
        XCTAssertNil(SemanticHTML.safeURL("java\u{0085}script:alert(1)", image: false))
    }

    func testVoidHTMLImagesUseAQuoteAwareTagBoundary() {
        XCTAssertEqual(
            InlineRunsView.parse(#"<img alt=">" src="pic.png">"#),
            [.image(alt: ">", url: "pic.png")]
        )
        XCTAssertEqual(
            InlineRunsView.parse(#"<img alt="a>b" src="https://example.com/x.png">"#),
            [.image(alt: "a>b", url: "https://example.com/x.png")]
        )
    }

    func testInlineLinksSupportBalancedAndAngleBracketDestinations() {
        let balanced = "[Swift](https://example.com/Swift_(language))"
        XCTAssertEqual(
            InlineRunsView.parse(balanced),
            [.link(label: "Swift", url: "https://example.com/Swift_(language)")]
        )
        XCTAssertEqual(
            InlineRunsView.parse("[Swift](<https://example.com/Swift_(language)>)"),
            [.link(label: "Swift", url: "https://example.com/Swift_(language)")]
        )
        let token = LivePreview.tokens(in: balanced).filter { $0.kind == .markdownLink }
        XCTAssertEqual(token.count, 1)
        XCTAssertEqual(token.first?.fullRange, NSRange(location: 0, length: (balanced as NSString).length))
    }
}

@MainActor
final class SourceTextFormattingTests: XCTestCase {
    func testBoldAndItalicShortcutsComposeAndToggleAroundTheVisibleSelection() throws {
        let (_, textView) = focusedTextView()
        textView.string = "glass"
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        XCTAssertTrue(textView.performKeyEquivalent(with: try keyEvent("b", keyCode: 11, modifiers: .command)))
        XCTAssertEqual(textView.string, "**glass**")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 5))

        XCTAssertTrue(textView.performKeyEquivalent(with: try keyEvent("i", keyCode: 34, modifiers: .command)))
        XCTAssertEqual(textView.string, "***glass***")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 5))

        textView.toggleBold(nil)
        XCTAssertEqual(textView.string, "*glass*")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 5))

        textView.toggleItalic(nil)
        XCTAssertEqual(textView.string, "glass")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 5))
    }

    func testFormattingKeyEquivalentsRequireTheEditorToBeFocusedEditableAndExactlyModified() throws {
        let (window, textView) = focusedTextView()
        textView.string = "glass"
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        let otherField = NSTextField(frame: NSRect(x: 0, y: 40, width: 120, height: 24))
        window.contentView?.addSubview(otherField)

        XCTAssertTrue(window.makeFirstResponder(otherField))
        XCTAssertFalse(textView.performKeyEquivalent(with: try keyEvent("b", keyCode: 11, modifiers: .command)))
        XCTAssertFalse(textView.performKeyEquivalent(with: try keyEvent("k", keyCode: 40, modifiers: .command)))
        XCTAssertEqual(textView.string, "glass")
        XCTAssertNil(window.attachedSheet)

        XCTAssertTrue(window.makeFirstResponder(textView))
        for modifiers: NSEvent.ModifierFlags in [[.command, .shift], [.control], [.command, .option]] {
            XCTAssertFalse(textView.performKeyEquivalent(with: try keyEvent("b", keyCode: 11, modifiers: modifiers)))
            XCTAssertEqual(textView.string, "glass")
        }
        XCTAssertFalse(textView.performKeyEquivalent(with: try keyEvent("4", keyCode: 21, modifiers: [.command, .option])))
        XCTAssertEqual(textView.string, "glass")

        textView.isEditable = false
        XCTAssertFalse(textView.performKeyEquivalent(with: try keyEvent("b", keyCode: 11, modifiers: .command)))
        XCTAssertEqual(textView.string, "glass")
    }

    func testBoldAndItalicToggleSupportedUnderscoreMarkupWithoutTouchingLiteralRuns() {
        let textView = SourceTextView()

        for (source, action, expected) in [
            ("_glass_", #selector(SourceTextView.toggleItalic(_:)), "glass"),
            ("__glass__", #selector(SourceTextView.toggleBold(_:)), "glass"),
            ("___glass___", #selector(SourceTextView.toggleBold(_:)), "_glass_"),
            ("___glass___", #selector(SourceTextView.toggleItalic(_:)), "__glass__")
        ] {
            textView.string = source
            let content = (source as NSString).range(of: "glass")
            textView.setSelectedRange(content)
            textView.doCommand(by: action)
            XCTAssertEqual(textView.string, expected, source)
        }

        textView.string = "snake_case_name"
        textView.setSelectedRange((textView.string as NSString).range(of: "case"))
        textView.toggleItalic(nil)
        XCTAssertEqual(textView.string, "snake_*case*_name")

        textView.string = #"\_glass_"#
        textView.setSelectedRange((textView.string as NSString).range(of: "glass"))
        textView.toggleItalic(nil)
        XCTAssertEqual(textView.string, #"\_*glass*_"#)
    }

    func testUnderlineTogglesExistingUAndInsMarkup() {
        let textView = SourceTextView()
        textView.string = "glass"
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        textView.toggleUnderline(nil)
        XCTAssertEqual(textView.string, "<u>glass</u>")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 5))

        textView.toggleUnderline(nil)
        XCTAssertEqual(textView.string, "glass")

        textView.string = "<ins>glass</ins>"
        textView.setSelectedRange(NSRange(location: 5, length: 5))
        textView.toggleUnderline(nil)
        XCTAssertEqual(textView.string, "glass")

        for source in ["<INS>glass</INS>", "<U>glass</u>"] {
            textView.string = source
            textView.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
            textView.toggleUnderline(nil)
            XCTAssertEqual(textView.string, "glass", source)
        }
    }

    func testHeadingShortcutsReplaceExistingHeadingLevelsAcrossSelectedLines() throws {
        let (_, textView) = focusedTextView()
        textView.string = "First\n## Second\nThird"
        textView.setSelectedRange(NSRange(location: 0, length: 15))

        XCTAssertTrue(textView.performKeyEquivalent(with: try keyEvent("3", keyCode: 20, modifiers: [.command, .option])))
        XCTAssertEqual(textView.string, "### First\n### Second\nThird")

        let second = (textView.string as NSString).range(of: "Second")
        textView.setSelectedRange(second)
        textView.applyHeading1(nil)
        XCTAssertEqual(textView.string, "### First\n# Second\nThird")
        XCTAssertEqual(
            (textView.string as NSString).substring(with: textView.selectedRange()),
            "Second"
        )

        textView.string = "First\n\nThird"
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        textView.applyHeading2(nil)
        XCTAssertEqual(textView.string, "## First\n\n## Third")
        XCTAssertEqual(
            (textView.string as NSString).substring(with: textView.selectedRange()),
            "First\n\n## Third"
        )
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 15))
    }

    func testHeadingPrefixBoundariesAndEmptyLines() {
        let cases: [(String, String)] = [
            ("##", "# "),
            ("##\n", "# \n"),
            ("##\tTitle", "# Title"),
            ("####### Title", "# ####### Title"),
            ("##Title", "# ##Title"),
            ("", ""),
            ("   \n", "   \n")
        ]
        for (source, expected) in cases {
            let textView = SourceTextView()
            textView.string = source
            textView.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
            textView.applyHeading1(nil)
            XCTAssertEqual(textView.string, expected, source)
        }
    }

    func testLinkCommandAddsAndEditsTheURLWithoutChangingTheLabel() {
        let textView = SourceTextView()
        textView.string = "Read docs"
        textView.setSelectedRange(NSRange(location: 5, length: 4))

        XCTAssertTrue(textView.applyLink(url: "https://example.com/one"))
        XCTAssertEqual(textView.string, "Read [docs](https://example.com/one)")
        XCTAssertEqual(
            (textView.string as NSString).substring(with: textView.selectedRange()),
            "docs"
        )

        XCTAssertTrue(textView.applyLink(url: "https://example.com/two"))
        XCTAssertEqual(textView.string, "Read [docs](https://example.com/two)")
        XCTAssertEqual(
            (textView.string as NSString).substring(with: textView.selectedRange()),
            "docs"
        )
    }

    func testLinkSerializationRoundTripsParenthesesAndEscapedLabelsAcrossBothPreviews() throws {
        let textView = SourceTextView()
        textView.string = "Read docs] \\ guide"
        let labelRange = (textView.string as NSString).range(of: "docs] \\ guide")
        textView.setSelectedRange(labelRange)
        let url = "https://en.wikipedia.org/wiki/Swift_(programming_language)"

        XCTAssertTrue(textView.applyLink(url: url))
        XCTAssertEqual(textView.string, "Read [docs\\] \\\\ guide](<\(url)>)")
        let parsed = try XCTUnwrap(GFM.inlineLinks(in: textView.string).first)
        XCTAssertEqual(parsed.label, "docs] \\ guide")
        XCTAssertEqual(parsed.destination, url)
        XCTAssertEqual(InlineRunsView.parse(String((textView.string as NSString).substring(from: 5))), [
            .link(label: "docs] \\ guide", url: url)
        ])
        XCTAssertEqual(LivePreview.tokens(in: textView.string).filter { $0.kind == .markdownLink }.count, 1)

        XCTAssertTrue(textView.applyLink(url: "https://example.com/Function_(math)"))
        XCTAssertEqual(GFM.inlineLinks(in: textView.string).first?.destination, "https://example.com/Function_(math)")
    }

    func testLinkLabelsCollapseNewlinesAndCaretSelectionsUseTheURLAsLabel() {
        let textView = SourceTextView()
        textView.string = "two\nlines"
        textView.setSelectedRange(NSRange(location: 0, length: 9))
        XCTAssertTrue(textView.applyLink(url: "https://example.com"))
        XCTAssertEqual(textView.string, "[two lines](https://example.com)")

        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.applyLink(url: "https://example.com"))
        XCTAssertEqual(textView.string, "[https://example.com](https://example.com)")

        textView.string = "space"
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(textView.applyLink(url: "https://example.com/two words"))
        XCTAssertEqual(textView.string, "[space](<https://example.com/two%20words>)")
        XCTAssertNotNil(MarkdownResourceResolver.linkURL("https://example.com/two%20words", relativeTo: nil))
    }

    func testLinkCommandRejectsImagesAndDoesNotTreatTheCaretAfterALinkAsInsideIt() {
        let textView = SourceTextView()
        var error: String?
        textView.linkEditErrorHandler = { error = $0 }
        textView.string = "![alt](img.png)"
        textView.setSelectedRange((textView.string as NSString).range(of: "alt"))

        XCTAssertFalse(textView.applyLink(url: "https://example.com"))
        XCTAssertEqual(textView.string, "![alt](img.png)")
        XCTAssertNotNil(error)

        textView.string = "[docs](https://example.com) next"
        let link = GFM.inlineLinks(in: textView.string)[0]
        textView.setSelectedRange(NSRange(location: NSMaxRange(link.range), length: 0))
        XCTAssertFalse(textView.linkEditingContext().isExistingLink)
    }

    func testLinkResponseSupportsCancelUnlinkValidationAndStaleContextFeedback() {
        let textView = SourceTextView()
        var errors: [String] = []
        textView.linkEditErrorHandler = { errors.append($0) }
        textView.string = "[docs](https://example.com)"
        textView.setSelectedRange((textView.string as NSString).range(of: "docs"))
        let context = textView.linkEditingContext()

        XCTAssertFalse(textView.handleLinkResponse(.alertSecondButtonReturn, url: "https://new.example", context: context))
        XCTAssertEqual(textView.string, "[docs](https://example.com)")
        XCTAssertTrue(textView.handleLinkResponse(.alertFirstButtonReturn, url: "   ", context: context))
        XCTAssertEqual(textView.string, "docs")

        textView.string = "plain"
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertFalse(textView.applyLink(url: " \n "))
        XCTAssertTrue(errors.last?.contains("Enter a URL") == true)

        textView.string = "[docs](https://example.com)"
        textView.setSelectedRange((textView.string as NSString).range(of: "docs"))
        let stale = textView.linkEditingContext()
        textView.string = "changed"
        XCTAssertFalse(textView.completeLinkEdit(url: "https://new.example", context: stale))
        XCTAssertTrue(errors.last?.contains("note changed") == true)
    }

    func testLinkEditorUsesCancelableSheetAndDetachedModalFallback() throws {
        let (window, textView) = focusedTextView()
        textView.string = "docs"
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        textView.editLink(nil)

        let sheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        XCTAssertEqual(textView.string, "docs")
        XCTAssertNil(window.attachedSheet)

        let detached = SourceTextView()
        detached.string = "standalone"
        detached.setSelectedRange(NSRange(location: 0, length: 10))
        DispatchQueue.main.async { NSApp.abortModal() }
        detached.editLink(nil)
        XCTAssertEqual(detached.string, "standalone")
    }

    func testCaretFormattingInsertsBalancedDelimiters() {
        let textView = SourceTextView()
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.toggleBold(nil)
        XCTAssertEqual(textView.string, "****")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))

        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.toggleUnderline(nil)
        XCTAssertEqual(textView.string, "<u></u>")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 0))
    }

    private func focusedTextView() -> (NSWindow, SourceTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        let textView = SourceTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        container.addSubview(textView)
        window.contentView = container
        XCTAssertTrue(window.makeFirstResponder(textView))
        return (window, textView)
    }

    private func keyEvent(
        _ characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}

final class MarkdownBlockTests: XCTestCase {
    func testClosedAndUnclosedFencesPreserveExactlyTheirContent() {
        XCTAssertEqual(
            MDBlock.parse("```swift\nlet a = 1\nlet b = 2\n```"),
            [.code(language: "swift", code: "let a = 1\nlet b = 2")]
        )
        XCTAssertEqual(
            MDBlock.parse("```swift\nlet a = 1\nlet b = 2"),
            [.code(language: "swift", code: "let a = 1\nlet b = 2")]
        )
        XCTAssertEqual(
            MDBlock.parse("```\nline\n"),
            [.code(language: "", code: "line\n")]
        )
    }

    func testRulesAlertsQuotesTablesHeadingsAndLists() {
        XCTAssertEqual(MDBlock.parse("---"), [.rule])
        XCTAssertEqual(MDBlock.parse("> [!NOTE]\n> body"), [.alert(.note, ["body"])])
        XCTAssertEqual(MDBlock.parse("> quoted"), [.quote(["quoted"])])
        XCTAssertEqual(
            MDBlock.parse("| A | B |\n| --- | --- |\n| 1 | 2 |"),
            [.table([["A", "B"], ["1", "2"]], [.left, .left], hasHeader: true)]
        )
        XCTAssertEqual(MDBlock.parse("## Heading"), [.heading(2, "Heading")])
        XCTAssertEqual(MDBlock.parse("1. first\n- second"), [.lines(["1. first", "- second"])])
    }

    func testBareAlertAndMismatchedTableRemainText() {
        XCTAssertEqual(MDBlock.parse("[!NOTE]"), [.lines(["[!NOTE]"])])
        XCTAssertEqual(
            MDBlock.parse("A | B\n| --- |\nnext"),
            [.lines(["A | B", "| --- |", "next"])]
        )
    }

    func testGitHubTableSyntaxAlignmentAndOptionalOuterPipes() {
        XCTAssertEqual(
            MDBlock.parse("Left | Centre | Right\n:--- | :---: | ---:\nA | B | C"),
            [.table(
                [["Left", "Centre", "Right"], ["A", "B", "C"]],
                [.left, .center, .right],
                hasHeader: true
            )]
        )
        XCTAssertEqual(
            MDBlock.parse("| Header |\n| --- |"),
            [.table([["Header"]], [.left], hasHeader: true)]
        )
    }

    func testGitHubTableRowsArePaddedOrTruncatedToTheHeader() {
        XCTAssertEqual(
            MDBlock.parse("| A | B |\n| --- | --- |\n| one |\n| 1 | 2 | ignored |"),
            [.table(
                [["A", "B"], ["one", ""], ["1", "2"]],
                [.left, .left],
                hasHeader: true
            )]
        )
    }

    func testEscapedPipesStayInsideCellsAndOtherEscapesArePreserved() {
        XCTAssertEqual(
            GFM.splitTableRow(#"| `A \| B` | \*literal\* |"#),
            ["`A | B`", #"\*literal\*"#]
        )
        XCTAssertEqual(
            MDBlock.parse("| Expression | Meaning |\n| --- | --- |\n| `A \\| B` | A or B |"),
            [.table(
                [["Expression", "Meaning"], ["`A | B`", "A or B"]],
                [.left, .left],
                hasHeader: true
            )]
        )
    }

    func testBlankLineEndsTableAndEmptyCellsAreRetained() {
        XCTAssertEqual(
            MDBlock.parse("Intro\n\n| Name | Email |\n| --- | --- |\n| Sam | |\n\nAfter | prose"),
            [
                .lines(["Intro"]),
                .table(
                    [["Name", "Email"], ["Sam", ""]],
                    [.left, .left],
                    hasHeader: true
                ),
                .lines(["After | prose"])
            ]
        )
    }

    func testHeaderlessHTMLTableUsesDataCells() {
        let html = """
        <table>
          <tr>
            <td>Row 1 Col 1</td>
            <td>Row 1 Col 2</td>
          </tr>
          <tr>
            <td>Row 2 Col 1</td>
            <td>Row 2 Col 2</td>
          </tr>
        </table>
        """
        XCTAssertEqual(
            MDBlock.parse(html),
            [.table(
                [["Row 1 Col 1", "Row 1 Col 2"], ["Row 2 Col 1", "Row 2 Col 2"]],
                [.left, .left],
                hasHeader: false
            )]
        )
    }

    func testHTMLTableHeadersAttributesRaggedRowsAndMixedCells() {
        let headerTable = """
        <table class="data">
          <tr></tr>
          <tr class="heading"><th scope="col">Name</th><th>Value</th></tr>
          <tr><td>A</td></tr>
        </table>
        """
        XCTAssertEqual(
            GFM.parseHTMLTable(headerTable),
            GFM.HTMLTable(
                rows: [["Name", "Value"], ["A", ""]],
                hasHeader: true,
                cells: [
                    .init(row: 0, column: 0, rowSpan: 1, columnSpan: 1, content: "Name", isHeader: true, alignment: .left),
                    .init(row: 0, column: 1, rowSpan: 1, columnSpan: 1, content: "Value", isHeader: true, alignment: .left),
                    .init(row: 1, column: 0, rowSpan: 1, columnSpan: 1, content: "A", isHeader: false, alignment: .left)
                ]
            )
        )

        let mixedTable = """
        <table>
          <tr><th>Name</th><td>Value</td></tr>
          <tr><td>A</td><td>1</td></tr>
        </table>
        """
        XCTAssertEqual(GFM.parseHTMLTable(mixedTable)?.hasHeader, false)
        XCTAssertNil(GFM.parseHTMLTable("<table><tr><th>broken</td></tr></table>"))
    }

    func testHTMLCellTextDecodesEntitiesOnceAndNormalizesMarkup() {
        let html = """
        <table><tr><td>
          Hello<br> <em>wide</em> world &amp;lt; &lt; &gt; &quot; &#39; &apos; &unknown;
        </td></tr></table>
        """
        XCTAssertEqual(
            GFM.parseHTMLTable(html)?.rows,
            [["Hello<br> *wide* world &lt; \\< \\> \" ' ' &unknown;"]]
        )
    }

    func testPreservedHTMLKeepsEntityEscapedMarkupLiteralAndStable() throws {
        let html = "<table><tr><td>&lt;b&gt;x&lt;/b&gt;</td></tr></table>"
        let converted = try XCTUnwrap(SemanticHTML.markdown(from: html))
        XCTAssertEqual(
            converted,
            "<table>\n  <tr>\n    <td>&lt;b&gt;x&lt;/b&gt;</td>\n  </tr>\n</table>"
        )
        XCTAssertEqual(SemanticHTML.markdown(from: converted), converted)
        XCTAssertEqual(GFM.parseHTMLTable(converted)?.rows, [["\\<b\\>x\\</b\\>"]])
        XCTAssertEqual(InlineRunsView.parse("\\<b\\>x\\</b\\>"), [.text("<b>x</b>")])

        XCTAssertEqual(
            SemanticHTML.markdown(from: "<details><summary>&lt;em&gt;hi&lt;/em&gt;</summary>x</details>"),
            "<details>\n<summary>&lt;em&gt;hi&lt;/em&gt;</summary>\nx\n</details>"
        )
        let literalDetails = try XCTUnwrap(SemanticHTML.markdown(
            from: "<details><summary>Markup</summary><p>&lt;b&gt;x&lt;/b&gt;</p></details>"
        ))
        guard case .details(_, let literalBody, _) = MDBlock.parse(literalDetails).first else {
            return XCTFail("Expected details block")
        }
        XCTAssertEqual(literalBody, "\\<b\\>x\\</b\\>")

        let codeDetails = try XCTUnwrap(SemanticHTML.markdown(
            from: "<details><summary>Code</summary><pre><code>&lt;tag&gt;\n````</code></pre></details>"
        ))
        guard case .details(_, let codeBody, _) = MDBlock.parse(codeDetails).first else {
            return XCTFail("Expected code details block")
        }
        XCTAssertEqual(MDBlock.parse(codeBody), [.code(language: "", code: "<tag>\n````")])
        XCTAssertEqual(
            SemanticHTML.markdown(from: "<dl><dt>&lt;code&gt;x&lt;/code&gt;</dt><dd>value</dd></dl>"),
            "<dl>\n<dt>&lt;code&gt;x&lt;/code&gt;</dt>\n<dd>value</dd>\n</dl>"
        )
    }

    func testHTMLTablePreservesCaptionSpansAlignmentAndLinks() throws {
        let html = """
        <table><caption>Release matrix</caption>
        <tr><th rowspan="2">Version</th><th colspan="2" align="center">Platforms</th></tr>
        <tr><td><a href="https://example.com/mac">macOS</a></td><td>Linux</td></tr>
        </table>
        """
        let table = try XCTUnwrap(GFM.parseHTMLTable(html))
        XCTAssertEqual(table.caption, "Release matrix")
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertTrue(table.hasSpans)
        XCTAssertEqual(table.cells[0].rowSpan, 2)
        XCTAssertEqual(table.cells[1].columnSpan, 2)
        XCTAssertEqual(table.cells[1].alignment, .center)
        XCTAssertEqual(table.cells[2].content, "[macOS](https://example.com/mac)")
        guard case .richTable = MDBlock.parse(html).first else {
            return XCTFail("Expected a spanning HTML table block")
        }
    }

    func testNestedHTMLTableRemainsCellContentInsteadOfBecomingOuterRows() throws {
        let html = """
        <table><tr><td>Outer<table><tr><td>Inner 1</td></tr><tr><td>Inner 2</td></tr></table></td></tr></table>
        """
        let table = try XCTUnwrap(GFM.parseHTMLTable(html))
        XCTAssertEqual(table.rowCount, 1)
        XCTAssertEqual(table.columnCount, 1)
        XCTAssertTrue(table.rows[0][0].contains("<table>"))
        XCTAssertTrue(table.rows[0][0].contains("Inner 2"))

        let sanitized = try XCTUnwrap(SemanticHTML.markdown(from: html))
        let roundTripped = try XCTUnwrap(GFM.parseHTMLTable(sanitized))
        XCTAssertEqual(roundTripped.rowCount, 1)
        XCTAssertTrue(roundTripped.rows[0][0].contains("<table>"))
        XCTAssertTrue(roundTripped.rows[0][0].contains("Inner 2"))
    }

    func testRaggedHTMLTablePadsAlignmentMetadataToItsWidestRow() {
        let html = """
        <table>
        <tr><td>A</td></tr>
        <tr><td>B</td><td align="right">C</td></tr>
        </table>
        """
        XCTAssertEqual(
            MDBlock.parse(html),
            [.table([["A", ""], ["B", "C"]], [.left, .left], hasHeader: false)]
        )
    }

    func testNestedHTMLContainersAreCollectedThroughTheirOuterCloser() {
        let source = """
        <div>
        <div>inner</div>
        after
        </div>

        trailing
        """
        let blocks = MDBlock.parse(source)
        XCTAssertFalse(String(describing: blocks).contains("</div>"))
        XCTAssertTrue(String(describing: blocks).contains("inner"))
        XCTAssertTrue(String(describing: blocks).contains("after"))
        XCTAssertTrue(String(describing: blocks).contains("trailing"))

        let nestedDetails = """
        <details open>
        <summary>Outer</summary>
        <details><summary>Inner</summary><p>inside</p></details>
        after
        </details>
        """
        guard case .details(_, let body, _) = MDBlock.parse(nestedDetails).first else {
            return XCTFail("Expected outer details block")
        }
        XCTAssertTrue(body.contains("<details>"))
        XCTAssertTrue(body.contains("after"))
    }

    func testDetailsAndDefinitionsRetainNestedMarkdownBlocks() throws {
        let source = """
        <details open>
        <summary>More</summary>
        <h2>Heading</h2>
        <pre><code>let x = 1</code></pre>
        <blockquote><p>Quote</p></blockquote>
        <table><tr><td>Cell</td></tr></table>
        <details><summary>Nested</summary><p>Body</p></details>
        </details>

        <dl><dt>Term</dt><dd><p>First</p><ul><li>One</li><li>Two</li></ul></dd></dl>
        """
        let blocks = MDBlock.parse(source)
        guard case .details(_, let body, _) = blocks.first else {
            return XCTFail("Expected details block")
        }
        let detailBlocks = MDBlock.parse(body)
        XCTAssertTrue(detailBlocks.contains { if case .heading(2, "Heading") = $0 { true } else { false } })
        XCTAssertTrue(detailBlocks.contains { if case .code(_, "let x = 1") = $0 { true } else { false } })
        XCTAssertTrue(detailBlocks.contains { if case .quote = $0 { true } else { false } })
        XCTAssertTrue(detailBlocks.contains { if case .table = $0 { true } else { false } })
        XCTAssertTrue(detailBlocks.contains { if case .details = $0 { true } else { false } })

        guard case .definitionList(let items) = blocks.last else {
            return XCTFail("Expected definition list")
        }
        XCTAssertEqual(items.first?.term, "Term")
        let definition = try XCTUnwrap(items.first?.definitions.first)
        let definitionBlocks = MDBlock.parse(definition)
        XCTAssertTrue(String(describing: definitionBlocks).contains("First"))
        XCTAssertTrue(String(describing: definitionBlocks).contains("- One"))
        XCTAssertTrue(String(describing: definitionBlocks).contains("- Two"))
    }

    func testLongCodeFencesProtectEmbeddedBacktickRuns() throws {
        let code = "before\n````\nafter"
        let converted = try XCTUnwrap(SemanticHTML.markdown(from: "<pre><code>\(code)</code></pre>"))
        XCTAssertTrue(converted.hasPrefix("`````\n"))
        XCTAssertTrue(converted.hasSuffix("\n`````"))
        XCTAssertEqual(MDBlock.parse(converted), [.code(language: "", code: code)])
    }

    func testSemanticHTMLBoundsPathologicalNesting() {
        let depth = 50_000
        let html = String(repeating: "<div>", count: depth)
            + "deep"
            + String(repeating: "</div>", count: depth)
        _ = SemanticHTML.markdown(from: html)
    }

    func testHTMLTableStartsAfterProseWithoutARequiredBlankLine() {
        let markdown = """
        Intro
        <table>
        <tr><td>A</td></tr>
        </table>
        """
        XCTAssertEqual(
            MDBlock.parse(markdown),
            [
                .lines(["Intro"]),
                .table([["A"]], [.left], hasHeader: false)
            ]
        )
    }

    func testHTMLTableScannerDoesNotConsumeProseOrCrossBlockBoundaries() {
        let proseThenTable = """
        <table> is an HTML element.

        Keep this paragraph.

        <table>
        <tr><td>A</td></tr>
        </table>
        """
        XCTAssertEqual(
            MDBlock.parse(proseThenTable),
            [
                .lines(["<table> is an HTML element."]),
                .lines(["Keep this paragraph."]),
                .table([["A"]], [.left], hasHeader: false)
            ]
        )

        let interrupted = """
        <table>
        <tr><td>A</td></tr>

        Keep this paragraph.
        </table>
        """
        XCTAssertEqual(
            MDBlock.parse(interrupted),
            [
                .lines(["<table>", "<tr><td>A</td></tr>"]),
                .lines(["Keep this paragraph.", "</table>"])
            ]
        )
    }

    func testMalformedAndFencedHTMLTablesRemainSourceText() {
        XCTAssertEqual(
            MDBlock.parse("<table>\n<tr><td>A</td></tr>"),
            [.lines(["<table>", "<tr><td>A</td></tr>"])]
        )
        XCTAssertEqual(
            MDBlock.parse("```html\n<table>\n<tr><td>A</td></tr>\n</table>\n```"),
            [.code(language: "html", code: "<table>\n<tr><td>A</td></tr>\n</table>")]
        )
    }

    func testCRLFTablesAndRulesAreRecognized() {
        XCTAssertEqual(
            MDBlock.parse("A | B\r\n--- | ---\r\n1 | 2\r\n\r\n---\r\n"),
            [
                .table([["A", "B"], ["1", "2"]], [.left, .left], hasHeader: true),
                .rule
            ]
        )
    }

    func testDelimiterRequiresThreeDashesAndMatchingColumnCount() {
        XCTAssertFalse(GFM.isTable(header: "A | B", separator: "-- | ---"))
        XCTAssertFalse(GFM.isTable(header: "A | B", separator: "---"))
        XCTAssertFalse(GFM.isTable(header: "A | B", separator: "--- | --- | ---"))
        XCTAssertTrue(GFM.isTable(header: "A | B", separator: "--- | ---"))
    }
}

final class MarkdownResourceTests: XCTestCase {
    func testRelativeImagesAndLinksResolveAgainstTheNoteDirectory() {
        let base = URL(fileURLWithPath: "/vault/Notes", isDirectory: true)
        XCTAssertEqual(
            MarkdownResourceResolver.imageURL("images/pic.png", relativeTo: base),
            URL(fileURLWithPath: "/vault/Notes/images/pic.png")
        )
        XCTAssertEqual(
            MarkdownResourceResolver.linkURL("Other.md", relativeTo: base),
            URL(fileURLWithPath: "/vault/Notes/Other.md")
        )
    }

    func testResourcePolicyRejectsUnsafeSchemesAndPrivateTargets() {
        XCTAssertNil(MarkdownResourceResolver.imageURL("javascript:alert(1)", relativeTo: nil))
        XCTAssertNil(MarkdownResourceResolver.linkURL("data:text/plain,no", relativeTo: nil))
        for raw in [
            "http://localhost/pixel", "http://127.0.0.1/pixel", "http://10.0.0.1/pixel",
            "http://169.254.169.254/pixel", "http://172.16.0.1/pixel",
            "http://192.168.1.1/pixel", "http://[::1]/pixel", "http://host.local/pixel"
        ] {
            XCTAssertFalse(MarkdownResourceResolver.isAllowedRemoteURL(URL(string: raw)!))
        }
        let publicURL = URL(string: "https://example.com/image.png")!
        XCTAssertTrue(MarkdownResourceResolver.isAllowedRemoteURL(publicURL))
        XCTAssertFalse(MarkdownResourceResolver.mayLoadImage(publicURL, loadRemoteImages: false))
        XCTAssertTrue(MarkdownResourceResolver.mayLoadImage(publicURL, loadRemoteImages: true))

        let localURL = URL(fileURLWithPath: "/vault/Notes/images/pic.png")
        XCTAssertFalse(MarkdownResourceResolver.mayLoadImage(
            localURL,
            loadLocalImages: false,
            loadRemoteImages: false
        ))
        XCTAssertEqual(
            MarkdownResourceResolver.imagePlaceholder(
                alt: "Diagram",
                resolvedURL: localURL,
                loadLocalImages: false,
                loadRemoteImages: false
            ),
            "Diagram (local image blocked)"
        )
    }

    func testRemoteLoaderRejectsErrorsAndOversizedResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://example.com/image.png")!

        ImageURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }
        do {
            _ = try await RemoteImageLoader.data(from: url, session: session)
            XCTFail("expected an invalid response")
        } catch {
            XCTAssertEqual(error as? RemoteImageLoadError, .invalidResponse)
        }

        ImageURLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(RemoteImageLoader.maximumBytes + 1)"]
            )!
            return (response, Data([0]))
        }
        do {
            _ = try await RemoteImageLoader.data(from: url, session: session)
            XCTFail("expected responseTooLarge")
        } catch {
            XCTAssertEqual(error as? RemoteImageLoadError, .responseTooLarge)
        }
    }

    func testRedirectDelegateRejectsPrivateDestination() async {
        let delegate = RemoteImageRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://example.com/image.png")!
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(
            url: original,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "http://127.0.0.1/pixel"]
        )!
        let redirected = URLRequest(url: URL(string: "http://127.0.0.1/pixel")!)
        let accepted = await withCheckedContinuation { continuation in
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: redirected
            ) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(accepted)
    }
}

private final class ImageURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MarkdownTests: XCTestCase {
    func testExtractorsIgnoreFencedTagsAndLimitHeadingDepth() {
        let fence = String(repeating: "\u{60}", count: 3)
        let content = [
            "# One", "###### Six", "####### Seven", "#outside",
            "body #inside [[Target#Section|Alias]]",
            fence, "#hidden [[Hidden]]", fence
        ].joined(separator: "\n")
        XCTAssertEqual(Markdown.tags(in: content), ["outside", "inside"])
        XCTAssertEqual(Markdown.wikiLinks(in: content), ["Target"])
        XCTAssertEqual(Markdown.headings(in: content).map(\.level), [1, 6])
    }

    func testRewriteWikiLinkUsesTargetAndAlias() {
        let rewritten = Markdown.rewriteWikiLinks("[[My Note#Details|Read this]]")
        XCTAssertTrue(rewritten.contains("[Read this](wiki://My%20Note)"))
    }
}

final class WikiLinkSuggestTests: XCTestCase {
    func testSessionDetectsOpenWikiLinkAndQuery() {
        let text = "See [[Wel"
        let session = WikiLinkSuggest.session(in: text, utf16Cursor: (text as NSString).length)
        XCTAssertEqual(session?.query, "Wel")
        XCTAssertEqual(session?.queryRange.location, 6)
        XCTAssertEqual(session?.queryRange.length, 3)
    }

    func testSessionPreservesHeadingAndAliasSuffixes() {
        let heading = "[[Note#Heading"
        let headingSession = WikiLinkSuggest.session(in: heading, utf16Cursor: (heading as NSString).length)
        XCTAssertEqual(headingSession?.query, "Note")
        XCTAssertEqual(headingSession?.suffix, "#Heading")
        XCTAssertEqual(
            headingSession.map { WikiLinkSuggest.replacement(target: "Target", in: $0) },
            "Target#Heading]]"
        )

        let alias = "[[Note|Readable label"
        let aliasSession = WikiLinkSuggest.session(in: alias, utf16Cursor: (alias as NSString).length)
        XCTAssertEqual(aliasSession?.query, "Note")
        XCTAssertEqual(aliasSession?.suffix, "|Readable label")
        XCTAssertEqual(
            aliasSession.map { WikiLinkSuggest.replacement(target: "Target", in: $0) },
            "Target|Readable label]]"
        )
    }

    func testCurrentNoteHeadingDoesNotRequestNoteSuggestions() {
        let text = "[[#Overview"
        let session = WikiLinkSuggest.session(in: text, utf16Cursor: (text as NSString).length)
        XCTAssertEqual(session?.query, "")
        XCTAssertEqual(session?.suffix, "#Overview")
        XCTAssertEqual(session?.allowsNoteSuggestions, false)
    }

    func testSessionIgnoresCompletedLinkAndFindsTheNextOpener() {
        let text = "[[Welcome]] then [["
        let session = WikiLinkSuggest.session(in: text, utf16Cursor: (text as NSString).length)
        XCTAssertEqual(session?.query, "")
        XCTAssertEqual(session?.markerRange.location, 17)
    }

    func testSessionIgnoresClosedLinkAndCodeFences() {
        XCTAssertNil(WikiLinkSuggest.session(in: "[[Welcome]]", utf16Cursor: 11))
        let fenced = "```\n[[Nope"
        XCTAssertNil(WikiLinkSuggest.session(in: fenced, utf16Cursor: (fenced as NSString).length))
    }

    func testSuggestionsNarrowByTitleAndPath() {
        let notes = [
            note("Welcome.md", "Welcome"),
            note("Ideas/First principles.md", "First principles"),
            note("Daily/2026-08-28.md", "2026-08-28")
        ]
        XCTAssertEqual(WikiLinkSuggest.suggestions(from: notes, query: "").map(\.title), [
            "2026-08-28", "First principles", "Welcome"
        ])
        XCTAssertEqual(WikiLinkSuggest.suggestions(from: notes, query: "wel").map(\.title), ["Welcome"])
        XCTAssertEqual(WikiLinkSuggest.suggestions(from: notes, query: "ideas").map(\.title), ["First principles"])
        XCTAssertTrue(WikiLinkSuggest.suggestions(from: notes, query: "zzz").isEmpty)
    }

    func testInsertTargetUsesPathWhenTitlesCollide() {
        let notes = [
            note("A/Index.md", "Index"),
            note("B/Index.md", "Index"),
            note("Welcome.md", "Welcome")
        ]
        XCTAssertEqual(WikiLinkSuggest.insertTarget(for: notes[0], among: notes), "A/Index")
        XCTAssertEqual(WikiLinkSuggest.insertTarget(for: notes[2], among: notes), "Welcome")
        XCTAssertEqual(WikiLinkSuggest.folderLabel(for: notes[0]), "A/")
        XCTAssertEqual(WikiLinkSuggest.folderLabel(for: notes[2]), "")
    }

    private func note(_ relative: String, _ title: String) -> NoteMeta {
        NoteMeta(
            path: "/vault/\(relative)",
            relativePath: relative,
            title: title,
            content: "",
            tags: [],
            wikiLinks: [],
            headings: []
        )
    }
}

final class LivePreviewTests: XCTestCase {
    func testTokensCoverHeadingsWikiLinksAndMarkdownLinks() {
        let text = "# Welcome\nTry a wiki link: [[Welcome]]\n- [Bases](https://obsidian.md)\n#test"
        let tokens = LivePreview.tokens(in: text)
        XCTAssertEqual(tokens.map(\.kind), [
            .heading(level: 1),
            .wikiLink,
            .list,
            .markdownLink,
            .tag
        ])

        let ns = text as NSString
        let heading = tokens[0]
        XCTAssertEqual(ns.substring(with: heading.fullRange), "# Welcome")
        XCTAssertEqual(ns.substring(with: heading.delimiterRanges[0]), "# ")

        let wiki = tokens[1]
        XCTAssertEqual(ns.substring(with: wiki.fullRange), "[[Welcome]]")
        XCTAssertEqual(ns.substring(with: wiki.delimiterRanges[0]), "[[")
        XCTAssertEqual(ns.substring(with: wiki.delimiterRanges[1]), "]]")

        let link = tokens[3]
        XCTAssertEqual(ns.substring(with: link.fullRange), "[Bases](https://obsidian.md)")
        XCTAssertEqual(ns.substring(with: link.delimiterRanges[0]), "[")
        XCTAssertEqual(ns.substring(with: link.delimiterRanges[1]), "](https://obsidian.md)")

        let tag = tokens[4]
        XCTAssertTrue(tag.delimiterRanges.isEmpty)
        XCTAssertEqual(ns.substring(with: tag.fullRange), "#test")
    }

    func testWikiAliasHidesTargetAndPipes() {
        let tokens = LivePreview.tokens(in: "[[Target|Label]]")
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].kind, .wikiLink)
        let ns = "[[Target|Label]]" as NSString
        XCTAssertEqual(tokens[0].delimiterRanges.map { ns.substring(with: $0) }, ["[[", "Target|", "]]"])
    }

    func testFencedBlocksSkipInlineMarkupAndKeepTheHeadingAfter() {
        let fence = String(repeating: "`", count: 3)
        let text = "\(fence)\n# Hidden [[Nope]]\n\(fence)\n# Visible"
        let tokens = LivePreview.tokens(in: text)
        XCTAssertEqual(tokens.count, 2)
        guard case .codeBlock(let language, let content) = tokens[0].kind else {
            return XCTFail("expected a code block")
        }
        XCTAssertEqual(language, "")
        XCTAssertEqual((text as NSString).substring(with: content), "# Hidden [[Nope]]\n")
        XCTAssertEqual(tokens[1].kind, .heading(level: 1))
        XCTAssertEqual((text as NSString).substring(with: tokens[1].fullRange), "# Visible")
        XCTAssertFalse(tokens[0].containsCaret((text as NSString).length - 1))
        XCTAssertTrue(tokens[1].containsCaret((text as NSString).length - 1))
    }

    func testCodeBlockHighlightsAndHidesFencesUntilEdited() {
        let text = "```python\ntesting = 5\n```\n"
        let tokens = LivePreview.tokens(in: text)
        XCTAssertEqual(tokens.count, 1)
        guard case .codeBlock(let language, let content) = tokens[0].kind else {
            return XCTFail("expected a python code block")
        }
        XCTAssertEqual(language, "python")
        XCTAssertEqual((text as NSString).substring(with: content), "testing = 5\n")
        XCTAssertEqual(CodeHighlight.displayName(for: language), "Python")

        let storage = NSTextStorage(string: text)
        let outside = (text as NSString).length
        let decorations = LivePreview.apply(
            to: storage,
            caret: outside,
            selection: NSRange(location: outside, length: 0),
            dark: true
        )
        XCTAssertTrue(isHidden(storage, at: 0))
        XCTAssertTrue(isHidden(storage, at: tokens[0].delimiterRanges[1].location))
        XCTAssertFalse(isHidden(storage, at: content.location))
        XCTAssertEqual(decorations.codeBlocks.count, 1)
        XCTAssertTrue(decorations.codeBlocks[0].showBadge)
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: content.location, effectiveRange: nil) as? NSColor,
            CodeHighlight.color(for: .ident, dark: true)
        )
        let five = content.location + ("testing = " as NSString).length
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: five, effectiveRange: nil) as? NSColor,
            CodeHighlight.color(for: .number, dark: true)
        )

        LivePreview.apply(
            to: storage,
            caret: 3,
            selection: NSRange(location: 3, length: 0),
            dark: true
        )
        XCTAssertFalse(isHidden(storage, at: 0))
        XCTAssertFalse(isHidden(storage, at: tokens[0].delimiterRanges[1].location))
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: content.location, effectiveRange: nil) as? NSColor,
            CodeHighlight.color(for: .ident, dark: true)
        )
    }

    func testPythonHighlighterTokenizesAssignment() {
        let spans = CodeHighlight.spans(in: "testing = 5", language: "python")
        XCTAssertEqual(spans.map(\.1), [.ident, .operator, .number])
        XCTAssertEqual(CodeHighlight.displayName(for: "js"), "JavaScript")
        XCTAssertEqual(CodeHighlight.displayName(for: ""), "")
    }

    func testInlineEmphasisAndCode() {
        let tokens = LivePreview.tokens(in: "**bold** *italic* `code` ~~strike~~")
        XCTAssertEqual(tokens.map(\.kind), [.inlineCode, .strikethrough, .bold, .italic])
    }

    func testUnderscoresInsideIdentifiersAreNotEmphasis() {
        for text in ["foo_bar_baz", "file_name", "__init__"] {
            let kinds = LivePreview.tokens(in: text).map(\.kind)
            XCTAssertFalse(kinds.contains(.italic), text)
            XCTAssertFalse(kinds.contains(.bold), text)
        }
        XCTAssertTrue(LivePreview.tokens(in: "_italic_").contains { $0.kind == .italic })
        XCTAssertTrue(LivePreview.tokens(in: "*italic*").contains { $0.kind == .italic })
    }

    func testHTMLCommentsInsideFencesRemainCode() {
        let text = "```html\n<!-- literal -->\n```"
        let tokens = LivePreview.tokens(in: text)
        XCTAssertEqual(tokens.count, 1)
        guard case .codeBlock = tokens[0].kind else { return XCTFail("expected code block") }
        let storage = NSTextStorage(string: text)
        LivePreview.apply(
            to: storage,
            caret: (text as NSString).length,
            selection: NSRange(location: (text as NSString).length, length: 0),
            dark: true,
            tokens: tokens
        )
        let comment = (text as NSString).range(of: "<!-- literal -->")
        XCTAssertFalse(isHidden(storage, at: comment.location))
    }

    func testApplyHidesDelimitersUntilCaretEntersTheConstruct() {
        let text = "# Welcome\n[[Note]] body"
        let storage = NSTextStorage(string: text)
        let hashes = NSRange(location: 0, length: 2)
        let open = NSRange(location: 10, length: 2)

        LivePreview.apply(
            to: storage,
            caret: 21,
            selection: NSRange(location: 21, length: 0),
            dark: true
        )
        XCTAssertTrue(isHidden(storage, at: hashes.location))
        XCTAssertTrue(isHidden(storage, at: open.location))
        XCTAssertFalse(isHidden(storage, at: 2))

        LivePreview.apply(
            to: storage,
            caret: 3,
            selection: NSRange(location: 3, length: 0),
            dark: true
        )
        XCTAssertFalse(isHidden(storage, at: hashes.location))
        XCTAssertTrue(isHidden(storage, at: open.location))
        XCTAssertEqual((storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize, 34)

        LivePreview.apply(
            to: storage,
            caret: 12,
            selection: NSRange(location: 12, length: 0),
            dark: true
        )
        XCTAssertTrue(isHidden(storage, at: hashes.location))
        XCTAssertFalse(isHidden(storage, at: open.location))
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: 12, effectiveRange: nil) as? NSColor,
            NSColor(red: 0.18, green: 0.83, blue: 0.75, alpha: 1)
        )
    }

    func testSelectingMarkupRevealsItAndTagsKeepTheirHash() {
        let text = "# Hello #tag"
        let storage = NSTextStorage(string: text)
        LivePreview.apply(
            to: storage,
            caret: 0,
            selection: NSRange(location: 0, length: (text as NSString).length),
            dark: true
        )
        XCTAssertFalse(isHidden(storage, at: 0))
        XCTAssertFalse(isHidden(storage, at: 8))
        XCTAssertEqual((storage.attribute(.font, at: 8, effectiveRange: nil) as? NSFont)?.pointSize, 16)
    }

    func testTaskListAndBlockquoteDelimitersFollowTheLine() {
        let text = "- [x] Done\n> quoted"
        let tokens = LivePreview.tokens(in: text)
        XCTAssertEqual(tokens.map(\.kind), [.taskList(checked: true), .blockquote])

        let storage = NSTextStorage(string: text)
        LivePreview.apply(
            to: storage,
            caret: 18,
            selection: NSRange(location: 18, length: 0),
            dark: true
        )
        XCTAssertFalse(isHidden(storage, at: 0))
        XCTAssertEqual((text as NSString).substring(with: tokens[0].delimiterRanges[0]), "- [x] ")
        XCTAssertFalse(isHidden(storage, at: 11))
    }

    func testTablesStaySeparatedAndRichCellsDoNotSplitDecorations() {
        let text = "| A | **B** |\n| --- | --- |\n| 1 | [[Two]] |\n\nprose\n\n| C | D |\n| --- | --- |\n| 3 | 4 |"
        let storage = NSTextStorage(string: text)
        let decorations = LivePreview.apply(
            to: storage,
            caret: (text as NSString).length,
            selection: NSRange(location: (text as NSString).length, length: 0),
            dark: true
        )
        XCTAssertEqual(decorations.tables.count, 2)
        XCTAssertEqual(decorations.tables.map { $0.rows.count }, [2, 2])
        XCTAssertTrue(decorations.tables.allSatisfy { $0.separatorRange.length > 0 })
        XCTAssertTrue(decorations.tables[0].range.upperBound < decorations.tables[1].range.location)
    }

    func testMultiLineAlertProducesOneTitleDecoration() {
        let text = "> [!WARNING]\n> first\n> second"
        let storage = NSTextStorage(string: text)
        let decorations = LivePreview.apply(
            to: storage,
            caret: (text as NSString).length,
            selection: NSRange(location: (text as NSString).length, length: 0),
            dark: true
        )
        let alerts = decorations.bars.filter { if case .alert = $0.kind { return true }; return false }
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].range, NSRange(location: 0, length: (text as NSString).length))
    }

    func testPipeProseFollowedByRuleIsNotATable() {
        let text = "Use the | operator\n---\n"
        let tokens = LivePreview.tokens(in: text)
        XCTAssertTrue(tokens.contains { $0.kind == .horizontalRule })
        XCTAssertFalse(tokens.contains { $0.kind == .tableSeparator })
        XCTAssertFalse(tokens.contains { if case .tableRow = $0.kind { return true }; return false })
        XCTAssertFalse(GFM.isTable(header: "A | B", separator: "| --- |"))
    }

    func testAlertsRequireBlockquotePrefix() {
        XCTAssertNil(GFM.isAlertMarker("[!NOTE]"))
        XCTAssertEqual(GFM.isAlertMarker("> [!NOTE]"), .note)
        XCTAssertFalse(LivePreview.tokens(in: "[!NOTE]").contains { if case .alert = $0.kind { return true }; return false })
    }

    func testTokenizationPerformance() {
        let text = Array(repeating: "Paragraph with **bold**, _italic_, [[Wiki]], and https://example.com.", count: 500)
            .joined(separator: "\n")
        measure(metrics: [XCTClockMetric()]) {
            XCTAssertFalse(LivePreview.tokens(in: text).isEmpty)
        }
    }

    func testHighlighterCoversStringsCommentsNumbersCallsAndLanguageFamilies() {
        let python = CodeHighlight.spans(in: "def run():\n  value = 0x2A + 3.5\n  text = \"unterminated\n  # note", language: "python")
        XCTAssertTrue(python.contains { $0.1 == .keyword })
        XCTAssertTrue(python.contains { $0.1 == .function })
        XCTAssertGreaterThanOrEqual(python.filter { $0.1 == .number }.count, 2)
        XCTAssertTrue(python.contains { $0.1 == .string })
        XCTAssertTrue(python.contains { $0.1 == .comment })

        XCTAssertTrue(CodeHighlight.spans(in: "/* open", language: "swift").contains { $0.1 == .comment })
        XCTAssertTrue(CodeHighlight.spans(in: "`template`", language: "javascript").contains { $0.1 == .string })
        XCTAssertTrue(CodeHighlight.spans(in: "SELECT * FROM notes -- comment", language: "sql").contains { $0.1 == .keyword })
        XCTAssertTrue(CodeHighlight.spans(in: "{\"ok\": true}", language: "json").contains { $0.1 == .string })
        XCTAssertTrue(CodeHighlight.spans(in: "<!-- open", language: "html").contains { $0.1 == .comment })
        XCTAssertTrue(CodeHighlight.spans(in: "# shell", language: "bash").contains { $0.1 == .comment })
        XCTAssertTrue(CodeHighlight.spans(in: "'''open", language: "python").contains { $0.1 == .string })
    }

    func testTablesFootnotesAlertsAndGitHubMarkdown() {
        let table = """
        | A | B |
        | --- | --- |
        | c | d |
        """
        let tableTokens = LivePreview.tokens(in: table)
        XCTAssertTrue(tableTokens.contains { if case .tableRow(true) = $0.kind { return true }; return false })
        XCTAssertTrue(tableTokens.contains { $0.kind == .tableSeparator })
        XCTAssertEqual(GFM.splitTableRow("| A | B |"), ["A", "B"])
        XCTAssertTrue(GFM.isTableSeparator("| :--- | ---: |"))

        let storage = NSTextStorage(string: table + "\n")
        let decorations = LivePreview.apply(
            to: storage,
            caret: (table as NSString).length + 1,
            selection: NSRange(location: (table as NSString).length + 1, length: 0),
            dark: true
        )
        XCTAssertEqual(decorations.tables.count, 1)
        XCTAssertEqual(decorations.tables[0].rows.count, 2)
        XCTAssertTrue(isHidden(storage, at: tableTokens.first { $0.kind == .tableSeparator }!.fullRange.location))

        let note = LivePreview.tokens(in: "See this[^1]\n\n[^1]: a footnote")
        XCTAssertTrue(note.contains { $0.kind == .footnoteRef })
        XCTAssertTrue(note.contains { $0.kind == .footnoteDef })

        let alert = LivePreview.tokens(in: "> [!WARNING]\n> Careful")
        XCTAssertTrue(alert.contains { if case .alert(.warning) = $0.kind { return true }; return false })

        let extras = LivePreview.tokens(in: "---\n1. First\n![Alt](https://example.com/a.png)\n:tada: <!-- hidden --> https://github.com")
        XCTAssertTrue(extras.contains { $0.kind == .horizontalRule })
        XCTAssertTrue(extras.contains { $0.kind == .orderedList })
        XCTAssertTrue(extras.contains { if case .image = $0.kind { return true }; return false })
        XCTAssertTrue(extras.contains { if case .emoji = $0.kind { return true }; return false })
        XCTAssertTrue(extras.contains { $0.kind == .htmlComment })
        XCTAssertTrue(extras.contains { $0.kind == .autolink })
        XCTAssertEqual(GFM.emoji(for: "tada"), "🎉")
        XCTAssertEqual(InlineRunsView.parse("See [^1] and :tada:"), [
            .text("See "),
            .footnote("1"),
            .text(" and "),
            .emoji("🎉")
        ])
    }

    func testLiveTableKeepsItsSourceChromeHiddenWhileEditingACell() throws {
        let table = "| Name | Count |\n| --- | ---: |\n| Glass | 2 |"
        let tokens = LivePreview.tokens(in: table)
        let header = try XCTUnwrap(tokens.first { $0.kind == .tableRow(isHeader: true) })
        let storage = NSTextStorage(string: table)
        let decorations = LivePreview.apply(
            to: storage,
            caret: header.fullRange.location + 3,
            selection: NSRange(location: header.fullRange.location + 3, length: 0),
            dark: true
        )

        XCTAssertEqual(decorations.tables.count, 1)
        XCTAssertEqual(decorations.tables[0].rows.count, 2)
        XCTAssertEqual(decorations.tables[0].rows.map { $0.cellRanges.count }, [2, 2])
        XCTAssertEqual(decorations.tables[0].columnWidths.count, 2)
        XCTAssertTrue(isHidden(storage, at: header.delimiterRanges[0].location))
        let separator = try XCTUnwrap(tokens.first { $0.kind == .tableSeparator })
        XCTAssertTrue(isHidden(storage, at: separator.fullRange.location))
        let style = storage.attribute(.paragraphStyle, at: header.fullRange.location + 2, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.minimumLineHeight, 38)

        let unicode = "😀 | Kind\n--- | ---\n🔥 | Hot"
        let unicodeStorage = NSTextStorage(string: unicode)
        let unicodeDecorations = LivePreview.apply(
            to: unicodeStorage,
            caret: 0,
            selection: NSRange(location: 0, length: 0),
            dark: true
        )
        let emojiRange = try XCTUnwrap(unicodeDecorations.tables.first?.rows.first?.cellRanges.first)
        XCTAssertEqual((unicode as NSString).substring(with: emojiRange).trimmingCharacters(in: .whitespaces), "😀")
    }

    func testLiveTableCellsAreRegularLeadingAlignedAndVerticallyCentered() throws {
        let table = "|       |       Header       |\n| --- | --- |\n| value | second |"
        let textView = SourceTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        textView.textContainerInset = NSSize(width: VGTheme.documentHorizontalPadding, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = table
        textView.liveDecorations = LivePreview.apply(
            to: textView.textStorage!,
            caret: 0,
            selection: NSRange(location: 0, length: 0),
            dark: true,
            maximumTableWidth: textView.maximumTableWidth
        )

        let source = table as NSString
        let headerRange = source.range(of: "Header")
        let font = try XCTUnwrap(textView.textStorage?.attribute(.font, at: headerRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.bold))

        let paragraph = try XCTUnwrap(
            textView.textStorage?.attribute(.paragraphStyle, at: headerRange.location, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertEqual(paragraph.alignment, .left)
        XCTAssertEqual(paragraph.firstLineHeadIndent, 12)

        let leadingPadding = source.range(of: "       Header")
        XCTAssertTrue(isHidden(textView.textStorage!, at: leadingPadding.location))

        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        let decoration = try XCTUnwrap(textView.liveDecorations.tables.first)
        let headerGlyphs = layoutManager.glyphRange(forCharacterRange: headerRange, actualCharacterRange: nil)
        let headerRect = layoutManager.boundingRect(forGlyphRange: headerGlyphs, in: container)
        let secondColumnX = decoration.columnWidths[0] + 12
        XCTAssertEqual(headerRect.minX, secondColumnX, accuracy: 1)

        let bodyFont = NSFont.systemFont(ofSize: 16)
        let fontHeight = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)
        let expectedBaselineOffset = floor((38 - fontHeight) / 2)
        let actualBaselineOffset = try XCTUnwrap(
            textView.textStorage?.attribute(.baselineOffset, at: headerRange.location, effectiveRange: nil) as? NSNumber
        )
        XCTAssertEqual(CGFloat(truncating: actualBaselineOffset), expectedBaselineOffset)
        XCTAssertLessThan(layoutManager.location(forGlyphAt: headerGlyphs.location).y, 38)
    }

    func testLiveTableCenteringPreservesInlineBaselineOffsets() throws {
        let table = "| H<sub>2</sub>O | x<sup>3</sup> [^1] |\n| --- | --- |\n| a | b |"
        let storage = NSTextStorage(string: table)
        _ = LivePreview.apply(
            to: storage,
            caret: 0,
            selection: NSRange(location: 0, length: 0),
            dark: true
        )

        let source = table as NSString
        let bodyLocation = source.range(of: "H<sub>").location
        let subscriptLocation = source.range(of: "2</sub>").location
        let superscriptLocation = source.range(of: "3</sup>").location
        let footnoteLocation = source.range(of: "1]").location

        func baseline(at location: Int) throws -> CGFloat {
            let value = try XCTUnwrap(
                storage.attribute(.baselineOffset, at: location, effectiveRange: nil) as? NSNumber
            )
            return CGFloat(truncating: value)
        }

        let bodyBaseline = try baseline(at: bodyLocation)
        XCTAssertEqual(try baseline(at: subscriptLocation), bodyBaseline - 3)
        XCTAssertEqual(try baseline(at: superscriptLocation), bodyBaseline + 6)
        XCTAssertEqual(try baseline(at: footnoteLocation), bodyBaseline + 6)
    }

    func testLiveWhitespaceOnlyTableCellStaysHiddenSizedAndAddressable() throws {
        let table = "| A | B |\n| --- | --- |\n|  | value |"
        let textView = SourceTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = table
        textView.liveDecorations = LivePreview.apply(
            to: textView.textStorage!,
            caret: 0,
            selection: NSRange(location: 0, length: 0),
            dark: true,
            maximumTableWidth: textView.maximumTableWidth
        )

        let tableDecoration = try XCTUnwrap(textView.liveDecorations.tables.first)
        let emptyCell = try XCTUnwrap(tableDecoration.rows.last?.cellRanges.first)
        XCTAssertGreaterThan(emptyCell.length, 0)
        for location in emptyCell.location..<NSMaxRange(emptyCell) {
            XCTAssertTrue(isHidden(textView.textStorage!, at: location))
        }
        XCTAssertEqual(tableDecoration.columnWidths[0], 112)

        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        let glyphs = layoutManager.glyphRange(forCharacterRange: emptyCell, actualCharacterRange: nil)
        XCTAssertGreaterThan(glyphs.length, 0)
        XCTAssertEqual(layoutManager.characterIndexForGlyph(at: glyphs.location), emptyCell.location)

        textView.setSelectedRange(NSRange(location: emptyCell.location, length: 0))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: emptyCell.location, length: 0))
    }

    func testTableMutationsAddAColumnAndRowWithUsefulCaretOffsets() throws {
        let table = "| A | B |\n| :--- | ---: |\n| 1 | 2 |"
        let column = try XCTUnwrap(GFM.addingTableColumn(to: table))
        XCTAssertEqual(
            column.replacement,
            "| A | B |  |\n| :--- | ---: | --- |\n| 1 | 2 |  |"
        )
        XCTAssertEqual(
            (column.replacement as NSString).substring(with: NSRange(location: column.selectionOffset, length: 1)),
            " "
        )
        XCTAssertEqual(GFM.splitTableRow(column.replacement.components(separatedBy: "\n")[0]).count, 3)

        let row = try XCTUnwrap(GFM.addingTableRow(to: table))
        XCTAssertEqual(row.replacement, table + "\n|  |  |")
        XCTAssertEqual(row.selectionOffset, (table as NSString).length + 3)
        XCTAssertEqual(
            (row.replacement as NSString).substring(with: NSRange(location: row.selectionOffset, length: 1)),
            " "
        )

        let windowsTable = table.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(
            GFM.addingTableRow(to: windowsTable)?.replacement,
            windowsTable + "\r\n|  |  |"
        )
    }

    func testAddingAColumnNormalizesRaggedRowsAndKeepsTheCaretInsideTrailingWhitespace() throws {
        let ragged = "| A | B |\n| --- | --- |\n| one |"
        let normalized = try XCTUnwrap(GFM.addingTableColumn(to: ragged))
        XCTAssertEqual(
            normalized.replacement.components(separatedBy: "\n").map(GFM.splitTableRow).map(\.count),
            [3, 3, 3]
        )

        let trailing = "| A | B |  \n| --- | --- |\n| 1 | 2 |"
        let mutation = try XCTUnwrap(GFM.addingTableColumn(to: trailing))
        let edited = NSMutableString(string: mutation.replacement)
        edited.insert("x", at: mutation.selectionOffset)
        let editedLines = (edited as String).components(separatedBy: "\n")
        XCTAssertTrue(GFM.isTable(header: editedLines[0], separator: editedLines[1]))
        XCTAssertEqual(GFM.splitTableRow(editedLines[0]).last, "x")
    }

    func testTableMutationsCoverInvalidSingleColumnAndOuterPipeVariants() throws {
        XCTAssertNil(GFM.addingTableColumn(to: "not a table"))
        XCTAssertNil(GFM.addingTableRow(to: "A | B\nnot a separator"))

        let single = try XCTUnwrap(GFM.addingTableColumn(to: "| A |\n| --- |\n| 1 |"))
        XCTAssertEqual(single.replacement.components(separatedBy: "\n").map(GFM.splitTableRow).map(\.count), [2, 2, 2])

        let noOuterPipes = "A | B\n--- | ---\n1 | 2"
        let column = try XCTUnwrap(GFM.addingTableColumn(to: noOuterPipes))
        XCTAssertEqual(column.replacement.components(separatedBy: "\n").map(GFM.splitTableRow).map(\.count), [3, 3, 3])
        let row = try XCTUnwrap(GFM.addingTableRow(to: noOuterPipes))
        XCTAssertTrue(row.replacement.components(separatedBy: "\n").last!.hasPrefix("|"))
        XCTAssertEqual(GFM.splitTableRow(row.replacement.components(separatedBy: "\n").last!).count, 2)
    }

    func testOnlyTheStructuralSeparatorReceivesAlignmentSyntaxDuringColumnInsertion() throws {
        let table = "| A | B |\n| --- | --- |\n| --- | value |"
        let mutation = try XCTUnwrap(GFM.addingTableColumn(to: table))
        let rows = mutation.replacement.components(separatedBy: "\n").map(GFM.splitTableRow)
        XCTAssertEqual(rows[1].last, "---")
        XCTAssertEqual(rows[2].last, "")
    }

    func testActiveTableSeparatorIsVisibleAtNormalLineHeight() throws {
        let table = "| A | B |\n| :--- | ---: |\n| 1 | 2 |"
        let separator = try XCTUnwrap(LivePreview.tokens(in: table).first { $0.kind == .tableSeparator })
        let storage = NSTextStorage(string: table)
        let decorations = LivePreview.apply(
            to: storage,
            caret: separator.fullRange.location + 3,
            selection: NSRange(location: separator.fullRange.location + 3, length: 0),
            dark: true
        )
        XCTAssertTrue(try XCTUnwrap(decorations.tables.first).separatorVisible)
        XCTAssertFalse(isHidden(storage, at: separator.fullRange.location + 3))
        let style = storage.attribute(.paragraphStyle, at: separator.fullRange.location + 3, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotEqual(style?.minimumLineHeight, 0.01)
    }

    func testTableColumnWidthsClampAndFitTheAvailableEditorWidth() throws {
        let long = String(repeating: "wide", count: 100)
        let table = "| A | \(long) |\n| --- | --- |\n| 1 | 2 |"
        let storage = NSTextStorage(string: table)
        let unconstrained = LivePreview.apply(
            to: storage,
            caret: 0,
            selection: NSRange(location: 0, length: 0),
            dark: true
        )
        XCTAssertEqual(try XCTUnwrap(unconstrained.tables.first).columnWidths, [112, 260])

        let constrainedStorage = NSTextStorage(string: table)
        let constrained = LivePreview.apply(
            to: constrainedStorage,
            caret: 0,
            selection: NSRange(location: 0, length: 0),
            dark: true,
            maximumTableWidth: 180
        )
        XCTAssertEqual(try XCTUnwrap(constrained.tables.first).columnWidths.reduce(0, +), 180, accuracy: 0.01)
    }

    private func isHidden(_ storage: NSTextStorage, at location: Int) -> Bool {
        let font = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        return (font?.pointSize ?? 16) < 1
    }
}

@MainActor
final class RichTextMarkdownConverterTests: XCTestCase {
    func testPreservesBoundaryWhitespaceFromHTMLAndRTF() throws {
        let htmlPasteboard = makePasteboard()
        htmlPasteboard.setData(Data("<span> word </span>".utf8), forType: .html)
        htmlPasteboard.setString(" word ", forType: .string)
        defer { htmlPasteboard.clearContents() }

        let htmlView = SourceTextView()
        htmlView.string = "AB"
        htmlView.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertTrue(htmlView.pasteMarkdown(from: htmlPasteboard))
        XCTAssertEqual(htmlView.string, "A word B")

        let rtfPasteboard = makePasteboard()
        let attributed = NSAttributedString(string: " word ")
        rtfPasteboard.setData(try data(from: attributed, as: .rtf), forType: .rtf)
        rtfPasteboard.setString(" word ", forType: .string)
        defer { rtfPasteboard.clearContents() }

        let rtfView = SourceTextView()
        rtfView.string = "AB"
        rtfView.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertTrue(rtfView.pasteMarkdown(from: rtfPasteboard))
        XCTAssertEqual(rtfView.string, "A word B")
    }

    func testPlainParagraphsNeutralizeMarkdownBlockMarkers() {
        let source = NSAttributedString(string: "1. Introduction\n1) Appendix\n# literal\n- literal\n---")
        XCTAssertEqual(
            RichTextMarkdownConverter.markdown(from: source),
            "1\\. Introduction\n\n1\\) Appendix\n\n\\# literal\n\n\\- literal\n\n\\---"
        )
    }

    func testOrdinaryProsePunctuationIsNotNeedlesslyEscaped() {
        let prose = "Our state-of-the-art plan uses file_name and issue #1"
        XCTAssertEqual(
            RichTextMarkdownConverter.markdown(from: NSAttributedString(string: prose)),
            prose
        )
    }

    func testAttributedAttachmentsAreRemovedAndHTMLImagesBecomeMarkdown() throws {
        let attributed = NSMutableAttributedString(string: "a")
        attributed.append(NSAttributedString(attachment: NSTextAttachment()))
        attributed.append(NSAttributedString(string: "b"))
        let converted = RichTextMarkdownConverter.markdown(from: attributed)
        XCTAssertEqual(converted, "ab")
        XCTAssertFalse(converted.contains("\u{FFFC}"))

        let mixedHTML = Data(#"<p>a<img src="https://example.com/x.png">b</p>"#.utf8)
        let mixedConversion = try XCTUnwrap(
            RichTextMarkdownConverter.markdown(from: mixedHTML, documentType: .html)
        )
        XCTAssertEqual(mixedConversion, "a![](https://example.com/x.png)b")
        XCTAssertFalse(mixedConversion.contains("\u{FFFC}"))

        let pasteboard = makePasteboard()
        pasteboard.setData(Data(#"<img src="https://example.com/x.png">"#.utf8), forType: .html)
        pasteboard.setString("image fallback", forType: .string)
        defer { pasteboard.clearContents() }

        let textView = SourceTextView()
        XCTAssertTrue(textView.pasteMarkdown(from: pasteboard))
        XCTAssertEqual(textView.string, "![](https://example.com/x.png)")
    }

    func testUTF8HTMLWithoutCharsetPreservesUnicode() throws {
        let html = "<p>café — “quoted”</p>"
        XCTAssertEqual(
            try XCTUnwrap(RichTextMarkdownConverter.markdown(from: Data(html.utf8), documentType: .html)),
            "café — “quoted”"
        )
    }

    func testSemanticHTMLHonorsDeclaredSingleByteAndBOMEncodings() throws {
        let cp1252HTML = #"<meta charset="windows-1252"><p>café naïve</p><br>"#
        let cp1252Data = try XCTUnwrap(cp1252HTML.data(using: .windowsCP1252))
        XCTAssertEqual(
            try XCTUnwrap(RichTextMarkdownConverter.markdown(from: cp1252Data, documentType: .html)),
            "café naïve"
        )

        let utf16HTML = "<p>雪 café</p><br>"
        var utf16Data = Data([0xFF, 0xFE])
        utf16Data.append(try XCTUnwrap(utf16HTML.data(using: .utf16LittleEndian)))
        XCTAssertEqual(
            try XCTUnwrap(RichTextMarkdownConverter.markdown(from: utf16Data, documentType: .html)),
            "雪 café"
        )

        XCTAssertNil(RichTextMarkdownConverter.decodedHTML(Data([0xFF, 0xFE, 0x41])))
        XCTAssertNil(RichTextMarkdownConverter.decodedHTML(
            try XCTUnwrap(utf16HTML.data(using: .utf16LittleEndian))
        ))
    }

    func testSemanticHTMLNeutralizesPlainBlockMarkers() throws {
        let html = """
        <p># literal</p><p>> quote</p><p>- item</p><p>1. item</p><p>---</p><br>
        """
        let converted = try XCTUnwrap(
            RichTextMarkdownConverter.markdown(from: Data(html.utf8), documentType: .html)
        )
        XCTAssertEqual(
            converted,
            "\\# literal\n\n\\> quote\n\n\\- item\n\n1\\. item\n\n\\---"
        )
        XCTAssertFalse(MDBlock.parse(converted).contains { block in
            if case .heading = block { return true }
            if case .quote = block { return true }
            if case .rule = block { return true }
            return false
        })
    }

    func testSemanticHTMLPreservesAllowlistedInlineCSSFormatting() throws {
        let html = """
        <p><span style="font-weight: 700">Bold</span>
        <span style="font-style: italic">Italic</span>
        <span style="text-decoration: underline">Under</span>
        <span style="text-decoration-line: line-through">Strike</span>
        <span style="font-family: ui-monospace, monospace">Mono</span></p><br>
        """
        XCTAssertEqual(
            try XCTUnwrap(RichTextMarkdownConverter.markdown(from: Data(html.utf8), documentType: .html)),
            "**Bold** *Italic* <ins>Under</ins> ~~Strike~~ `Mono`"
        )
    }

    func testNestedTaskListDoesNotPromoteItsPlainParent() throws {
        let html = "<ul><li>parent<ul><li><input type=checkbox>kid</li></ul></li></ul>"
        XCTAssertEqual(
            try XCTUnwrap(RichTextMarkdownConverter.markdown(from: Data(html.utf8), documentType: .html)),
            "- parent\n  - [ ] kid"
        )
    }

    func testChromeGitHubTablePastePreservesHTMLStructureAndInlineFormatting() throws {
        let html = """
        <h2>Styling text</h2>
        <p>You can indicate emphasis with several styles.</p>
        <table aria-labelledby="styling-text">
          <thead><tr><th scope="col">Style</th><th scope="col">Syntax</th><th scope="col">Output</th></tr></thead>
          <tbody>
            <tr><td>Bold</td><td><code>** **</code></td><td><strong>This is bold text</strong></td></tr>
            <tr><td>Strikethrough</td><td><code>~~ ~~</code></td><td><del>This was mistaken text</del></td></tr>
            <tr><td>All bold and italic</td><td><code>*** ***</code></td><td><em><strong>All this text is important</strong></em></td></tr>
            <tr><td>Subscript</td><td><code>&lt;sub&gt; &lt;/sub&gt;</code></td><td>This is a <sub>subscript</sub> text</td></tr>
            <tr><td>Superscript</td><td><code>&lt;sup&gt; &lt;/sup&gt;</code></td><td>This is a <sup>superscript</sup> text</td></tr>
            <tr><td>Underline</td><td><code>&lt;ins&gt; &lt;/ins&gt;</code></td><td>This is an <ins>underlined</ins> text</td></tr>
          </tbody>
        </table>
        """
        let pasteboard = makePasteboard()
        pasteboard.setData(Data(html.utf8), forType: .html)
        pasteboard.setString(
            "Styling text\nStyle\tSyntax\tOutput\nBold\t** **\tThis is bold text",
            forType: .string
        )
        defer { pasteboard.clearContents() }

        let textView = SourceTextView()
        XCTAssertTrue(textView.pasteMarkdown(from: pasteboard))
        XCTAssertTrue(textView.string.hasPrefix("## Styling text\n\nYou can indicate emphasis"))
        XCTAssertTrue(textView.string.contains("<table>"))
        XCTAssertTrue(textView.string.contains("<thead>"))
        XCTAssertTrue(textView.string.contains("<code>** **</code>"))
        XCTAssertTrue(textView.string.contains("<del>This was mistaken text</del>"))
        XCTAssertTrue(textView.string.contains("<sub>subscript</sub>"))
        XCTAssertTrue(textView.string.contains("<sup>superscript</sup>"))
        XCTAssertTrue(textView.string.contains("<ins>underlined</ins>"))
        XCTAssertFalse(textView.string.contains("| Style |"))

        let blocks = MDBlock.parse(textView.string)
        guard case .table(let rows, _, let hasHeader) = blocks.last else {
            return XCTFail("Expected the preserved HTML table to render as a table")
        }
        XCTAssertTrue(hasHeader)
        XCTAssertEqual(rows[1], ["Bold", "`** **`", "**This is bold text**"])
        XCTAssertEqual(rows[2][2], "~~This was mistaken text~~")
        XCTAssertEqual(rows[3][2], "***All this text is important***")
        XCTAssertEqual(rows[4][2], "This is a <sub>subscript</sub> text")
        XCTAssertEqual(rows[5][2], "This is a <sup>superscript</sup> text")
        XCTAssertEqual(rows[6][2], "This is an <ins>underlined</ins> text")
    }

    func testSemanticHTMLPasteCoversBlocksTasksDetailsDefinitionsAndSafety() throws {
        let html = """
        <blockquote><p>Quoted <mark>note</mark><br>next line</p></blockquote>
        <hr>
        <ul><li><input type="checkbox" checked>Done</li><li><input type="checkbox">Todo</li></ul>
        <picture><source srcset="ignored.webp"><img src="https://example.com/p.png" alt="Picture"></picture>
        <details open><summary>More <kbd>⌘K</kbd></summary><p>Hidden <strong>content</strong></p></details>
        <dl><dt>Term</dt><dd>A <em>definition</em></dd></dl>
        <script>alert('no')</script><img src="javascript:alert(1)" alt="Unsafe">
        """
        let converted = try XCTUnwrap(
            RichTextMarkdownConverter.markdown(from: Data(html.utf8), documentType: .html)
        )
        XCTAssertTrue(converted.contains("> Quoted <mark>note</mark>  \n> next line"))
        XCTAssertTrue(converted.contains("\n\n---\n\n"))
        XCTAssertTrue(converted.contains("- [x] Done\n- [ ] Todo"))
        XCTAssertTrue(converted.contains("![Picture](https://example.com/p.png)"))
        XCTAssertTrue(converted.contains("<details open>"))
        XCTAssertTrue(converted.contains("<summary>More <kbd>⌘K</kbd></summary>"))
        XCTAssertTrue(converted.contains("<dl>"))
        XCTAssertFalse(converted.contains("alert('no')"))
        XCTAssertFalse(converted.contains("javascript:"))

        let blocks = MDBlock.parse(converted)
        XCTAssertTrue(blocks.contains { if case .quote = $0 { true } else { false } })
        XCTAssertTrue(blocks.contains { if case .rule = $0 { true } else { false } })
        XCTAssertTrue(blocks.contains { if case .details = $0 { true } else { false } })
        XCTAssertTrue(blocks.contains { if case .definitionList = $0 { true } else { false } })
    }

    func testExplicitHTMLCharsetIsNotOverridden() {
        let unspecified = RichTextMarkdownConverter.readingOptions(
            for: Data("<p>café</p>".utf8),
            documentType: .html
        )
        XCTAssertEqual(
            unspecified[.characterEncoding] as? UInt,
            String.Encoding.utf8.rawValue
        )

        let declared = RichTextMarkdownConverter.readingOptions(
            for: Data(#"<meta charset="windows-1252"><p>text</p>"#.utf8),
            documentType: .html
        )
        XCTAssertNil(declared[.characterEncoding])
    }

    func testNestedOrderedListsCodeBlocksSeparatorsAndLinkEscaping() throws {
        let listHTML = "<ol><li>First<ol><li>Nested</li></ol></li><li>Second</li></ol>"
        let listMarkdown = try XCTUnwrap(
            RichTextMarkdownConverter.markdown(from: Data(listHTML.utf8), documentType: .html)
        )
        XCTAssertEqual(listMarkdown, "1. First\n  1. Nested\n1. Second")

        let codeStyle = NSMutableParagraphStyle()
        codeStyle.paragraphSpacing = 0
        let code = NSMutableAttributedString(string: "let x = 1\nprint(x)")
        code.addAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .paragraphStyle: codeStyle,
        ], range: NSRange(location: 0, length: code.length))
        XCTAssertEqual(
            RichTextMarkdownConverter.markdown(from: code),
            "```\nlet x = 1\nprint(x)\n```"
        )

        let linked = NSMutableAttributedString(string: "First\nLink\nLast")
        linked.addAttribute(
            .link,
            value: "https://example.com/a b(c)",
            range: NSRange(location: 6, length: 4)
        )
        XCTAssertEqual(
            RichTextMarkdownConverter.markdown(from: linked),
            "First\n\n[Link](https://example.com/a%20b\\(c\\))\n\nLast"
        )
    }

    func testRTFAndRTFDPasteRepresentationsConvertFormatting() throws {
        let bold = NSMutableAttributedString(string: "Bold")
        bold.addAttribute(
            .font,
            value: NSFont.boldSystemFont(ofSize: 13),
            range: NSRange(location: 0, length: bold.length)
        )

        for (pasteboardType, documentType) in [
            (NSPasteboard.PasteboardType.rtf, NSAttributedString.DocumentType.rtf),
            (.rtfd, .rtfd),
        ] {
            let pasteboard = makePasteboard()
            pasteboard.setData(try data(from: bold, as: documentType), forType: pasteboardType)
            pasteboard.setString("fallback", forType: .string)

            let textView = SourceTextView()
            XCTAssertTrue(textView.pasteMarkdown(from: pasteboard))
            XCTAssertEqual(textView.string, "**Bold**")
            pasteboard.clearContents()
        }
    }

    func testAttributedTableImportPreservesStructureFormattingAndSafeLinks() throws {
        let table = NSTextTable()
        table.numberOfColumns = 2
        let attributed = NSMutableAttributedString()

        appendTableParagraph("Head A", to: attributed, table: table, row: 0, column: 0, bold: true)
        appendTableParagraph("Head B", to: attributed, table: table, row: 0, column: 1, bold: true)
        appendTableParagraph(
            "First",
            to: attributed,
            table: table,
            row: 1,
            column: 0,
            rowSpan: 2,
            link: "https://example.com/a b"
        )
        appendTableParagraph("Second", to: attributed, table: table, row: 1, column: 0, rowSpan: 2)
        appendTableParagraph(
            "Unsafe",
            to: attributed,
            table: table,
            row: 1,
            column: 1,
            link: "javascript:alert(1)"
        )

        let converted = RichTextMarkdownConverter.markdown(from: attributed)
        XCTAssertTrue(converted.contains("<thead>"))
        XCTAssertTrue(converted.contains("<th><strong>Head A</strong></th>"))
        XCTAssertTrue(converted.contains("rowspan=\"2\""))
        XCTAssertTrue(converted.contains("<a href=\"https://example.com/a%20b\">First</a><br>Second"))
        XCTAssertTrue(converted.contains(">Unsafe</td>"))
        XCTAssertFalse(converted.contains("javascript:"))

        for documentType in [NSAttributedString.DocumentType.rtf, .rtfd] {
            let roundTripped = try XCTUnwrap(RichTextMarkdownConverter.markdown(
                from: data(from: attributed, as: documentType),
                documentType: documentType
            ))
            XCTAssertTrue(roundTripped.contains("<table>"), documentType.rawValue)
            XCTAssertTrue(roundTripped.contains("Head A"), documentType.rawValue)
            XCTAssertFalse(roundTripped.contains("javascript:"), documentType.rawValue)
        }
    }

    func testSemanticHTMLCodeBlockContainingTableSyntaxRemainsFenced() {
        let pasteboard = makePasteboard()
        let table = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let html = "<p><strong>Example</strong></p><pre><code>\(table)</code></pre>"
        pasteboard.setData(Data(html.utf8), forType: .html)
        pasteboard.setString("Example\n\(table)", forType: .string)
        defer { pasteboard.clearContents() }

        let textView = SourceTextView()
        XCTAssertTrue(textView.pasteMarkdown(from: pasteboard))
        XCTAssertEqual(textView.string, "**Example**\n\n```\n\(table)\n```")
    }

    func testRTFAndRTFDChoosePlainOnlyWhenRichConversionBreaksATable() throws {
        let table = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let codeStyle = NSMutableParagraphStyle()
        codeStyle.paragraphSpacing = 0
        let code = NSMutableAttributedString(string: table)
        code.addAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .paragraphStyle: codeStyle,
        ], range: NSRange(location: 0, length: code.length))

        for (pasteboardType, documentType) in [
            (NSPasteboard.PasteboardType.rtf, NSAttributedString.DocumentType.rtf),
            (.rtfd, .rtfd),
        ] {
            let presentationPasteboard = makePasteboard()
            presentationPasteboard.setData(
                try data(from: NSAttributedString(string: table), as: documentType),
                forType: pasteboardType
            )
            presentationPasteboard.setString(table, forType: .string)
            let presentationView = SourceTextView()
            XCTAssertTrue(presentationView.pasteMarkdown(from: presentationPasteboard))
            XCTAssertEqual(presentationView.string, table)
            presentationPasteboard.clearContents()

            let codePasteboard = makePasteboard()
            codePasteboard.setData(try data(from: code, as: documentType), forType: pasteboardType)
            codePasteboard.setString(table, forType: .string)
            let codeView = SourceTextView()
            XCTAssertTrue(codeView.pasteMarkdown(from: codePasteboard))
            XCTAssertEqual(codeView.string, "```\n\(table)\n```")
            codePasteboard.clearContents()
        }
    }

    func testRichSelectionReadingUsesMarkdownConversion() {
        let pasteboard = makePasteboard()
        pasteboard.setData(Data("<p><strong>Dragged</strong></p>".utf8), forType: .html)
        pasteboard.setString("Dragged", forType: .string)
        defer { pasteboard.clearContents() }

        let textView = SourceTextView()
        textView.string = "AB"
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertTrue(textView.readSelection(from: pasteboard, type: .html))
        XCTAssertEqual(textView.string, "A**Dragged**B")
    }

    func testOversizedRichPayloadFallsBackToPlainText() {
        let pasteboard = makePasteboard()
        pasteboard.setData(Data(repeating: 0x20, count: 2 * 1_024 * 1_024 + 1), forType: .html)
        pasteboard.setString("plain fallback", forType: .string)
        defer { pasteboard.clearContents() }

        let textView = SourceTextView()
        XCTAssertTrue(textView.pasteMarkdown(from: pasteboard))
        XCTAssertEqual(textView.string, "plain fallback")
    }

    func testHTMLReadingOptionsInstallAResourceBlockingDelegate() throws {
        let options = RichTextMarkdownConverter.readingOptions(
            for: Data("<p>text</p>".utf8),
            documentType: .html
        )
        let delegate = try XCTUnwrap(
            options[.webResourceLoadDelegate] as? RichTextMarkdownConverter.BlockingResourceLoadDelegate
        )
        let request = try XCTUnwrap(URLRequest(url: URL(string: "https://example.com/image.png")!))
        XCTAssertNil(delegate.rejectExternalResource(
            NSObject(),
            resource: NSObject(),
            request: request,
            redirectResponse: nil,
            dataSource: NSObject()
        ))
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("paste-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func data(
        from attributed: NSAttributedString,
        as documentType: NSAttributedString.DocumentType
    ) throws -> Data {
        try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: documentType]
        )
    }

    private func appendTableParagraph(
        _ text: String,
        to attributed: NSMutableAttributedString,
        table: NSTextTable,
        row: Int,
        column: Int,
        rowSpan: Int = 1,
        columnSpan: Int = 1,
        bold: Bool = false,
        link: String? = nil
    ) {
        let paragraph = NSMutableAttributedString(string: text + "\n")
        let style = NSMutableParagraphStyle()
        style.textBlocks = [NSTextTableBlock(
            table: table,
            startingRow: row,
            rowSpan: rowSpan,
            startingColumn: column,
            columnSpan: columnSpan
        )]
        paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
        if bold {
            paragraph.addAttribute(
                .font,
                value: NSFont.boldSystemFont(ofSize: 13),
                range: NSRange(location: 0, length: text.utf16.count)
            )
        }
        if let link {
            paragraph.addAttribute(.link, value: link, range: NSRange(location: 0, length: text.utf16.count))
        }
        attributed.append(paragraph)
    }
}

@MainActor
final class EditorLifecycleTests: XCTestCase {
    func testPasteInsertsMarkdownAtTheCaretAndNotifiesTheEditor() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("paste-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("# Pasted\n\n- markdown", forType: .string)
        defer { pasteboard.clearContents() }

        var changes: [String] = []
        let coordinator = SourceEditor.Coordinator(onChange: { changes.append($0) })
        let textView = SourceTextView()
        textView.delegate = coordinator
        textView.string = "Before  after"
        textView.setSelectedRange(NSRange(location: 7, length: 0))

        XCTAssertTrue(textView.pasteMarkdown(from: pasteboard))
        XCTAssertEqual(textView.string, "Before # Pasted\n\n- markdown after")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 27, length: 0))
        XCTAssertEqual(changes.last, textView.string)
    }

    func testPasteReplacesTheActiveSelection() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("paste-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("**new**", forType: .string)
        defer { pasteboard.clearContents() }

        let textView = SourceTextView()
        textView.string = "Replace old text"
        textView.setSelectedRange(NSRange(location: 8, length: 3))

        XCTAssertTrue(textView.pasteMarkdown(from: pasteboard))
        XCTAssertEqual(textView.string, "Replace **new** text")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 15, length: 0))
    }

    func testPasteIgnoresPasteboardsWithoutPlainText() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("paste-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Data([0x00, 0x01]), forType: .png)
        defer { pasteboard.clearContents() }

        let textView = SourceTextView()
        textView.string = "Unchanged"
        textView.setSelectedRange(NSRange(location: 9, length: 0))

        XCTAssertFalse(textView.pasteMarkdown(from: pasteboard))
        XCTAssertEqual(textView.string, "Unchanged")
    }

    func testPastePrefersChromeHTMLAndConvertsFormattingToMarkdown() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("paste-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let html = """
        <h2>Release notes</h2>
        <p>Use <strong>bold</strong>, <em>italics</em>, and <a href="https://example.com/docs">links</a>.</p>
        <ul><li>First item</li><li>Run <code>swift test</code></li></ul>
        """
        pasteboard.setData(Data(html.utf8), forType: .html)
        pasteboard.setString("Release notes Use bold, italics, and links. First item Run swift test", forType: .string)
        defer { pasteboard.clearContents() }

        var changes: [String] = []
        let coordinator = SourceEditor.Coordinator(onChange: { changes.append($0) })
        let textView = SourceTextView()
        textView.delegate = coordinator

        XCTAssertTrue(textView.pasteMarkdown(from: pasteboard))
        XCTAssertEqual(
            textView.string,
            "## Release notes\n\nUse **bold**, *italics*, and [links](https://example.com/docs).\n\n- First item\n- Run `swift test`"
        )
        XCTAssertEqual(changes.last, textView.string)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: (textView.string as NSString).length, length: 0))
    }

    func testPastePreservesMarkdownTableCopiedFromVSCode() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("paste-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let markdown = """
        | Component | Share of the final score |
        | ----- | ----: |
        | Track record | 30% |
        | Career quality | 20% |
        """
        let html = #"""
        <meta charset='utf-8'><div style="font-family: 'FiraCode Nerd Font', Menlo, monospace; font-size: 12px; line-height: 18px; white-space: pre;"><div><span>| Component | Share of the final score |</span></div><div><span>| ----- | ----: |</span></div><div><span>| Track record | 30% |</span></div><div><span>| Career quality | 20% |</span></div></div>
        """#
        pasteboard.setData(Data(html.utf8), forType: .html)
        pasteboard.setString(markdown, forType: .string)
        defer { pasteboard.clearContents() }

        let textView = SourceTextView()
        XCTAssertTrue(textView.pasteMarkdown(from: pasteboard))
        XCTAssertEqual(textView.string, markdown)
    }

    func testPastePreservesPlainMarkdownCopiedFromVSCodeWithoutHTMLBreakTags() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("paste-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let markdown = """
        Current Focus

        * Getting Funds finished
        * Finalising onboarding

        Next

        * My Network
        """
        pasteboard.setData(Data(sourceEditorHTML(for: markdown).utf8), forType: .html)
        pasteboard.setString(markdown, forType: .string)
        defer { pasteboard.clearContents() }

        let textView = SourceTextView()
        XCTAssertTrue(textView.pasteMarkdown(from: pasteboard))
        XCTAssertEqual(textView.string, markdown)
        XCTAssertFalse(textView.string.contains("<br>"))
    }

    func testPasteKeepsFormattingForPreWrappedRichHTML() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("paste-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let html = #"<div style="font-family: Menlo, monospace; white-space: pre-wrap;"><div><strong>Important</strong><br><a href="https://example.com">Open details</a></div></div>"#
        pasteboard.setData(Data(html.utf8), forType: .html)
        pasteboard.setString("Important\nOpen details", forType: .string)
        defer { pasteboard.clearContents() }

        let textView = SourceTextView()
        XCTAssertTrue(textView.pasteMarkdown(from: pasteboard))
        XCTAssertEqual(
            textView.string,
            "**Important**  \n[Open details](https://example.com)"
        )
    }

    func testPasteConvertsTelegramStyleRichTextAndBreaksToMarkdown() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("paste-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let html = #"<div><strong>Important</strong><br><em>Read this</em> and <a href="https://example.com">open it</a></div>"#
        pasteboard.setData(Data(html.utf8), forType: .html)
        pasteboard.setString("Important\nRead this and open it", forType: .string)
        defer { pasteboard.clearContents() }

        let textView = SourceTextView()
        XCTAssertTrue(textView.pasteMarkdown(from: pasteboard))
        XCTAssertEqual(
            textView.string,
            "**Important**  \n*Read this* and [open it](https://example.com)"
        )
        XCTAssertNil(textView.string.range(of: #"</?[A-Za-z][^>]*>"#, options: .regularExpression))
    }

    func testPastePreservesMixedSourceMarkdownWhenConversionBreaksALaterTable() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("paste-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let markdown = "Notes\n| A | B |\n| --- | --- |"
        pasteboard.setData(Data(sourceEditorHTML(for: markdown).utf8), forType: .html)
        pasteboard.setString(markdown, forType: .string)
        defer { pasteboard.clearContents() }

        let textView = SourceTextView()
        XCTAssertTrue(textView.pasteMarkdown(from: pasteboard))
        XCTAssertEqual(textView.string, markdown)
    }

    func testPastePreservesCRLFMarkdownTableFromSourceEditorHTML() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("paste-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let markdown = "| A | B |\r\n| --- | --- |\r\n| 1 | 2 |"
        pasteboard.setData(Data(sourceEditorHTML(for: markdown).utf8), forType: .html)
        pasteboard.setString(markdown, forType: .string)
        defer { pasteboard.clearContents() }

        let textView = SourceTextView()
        XCTAssertTrue(textView.pasteMarkdown(from: pasteboard))
        XCTAssertEqual(textView.string, markdown)
    }

    func testTableLikePlainTextWithoutAValidTableStillUsesRichHTML() {
        let fixtures = [
            (
                plain: "A | B",
                html: "<p><strong>A | B</strong></p>",
                expected: "**A | B**"
            ),
            (
                plain: "Cost | Benefit\n-- | --",
                html: "<p><strong>Cost | Benefit</strong></p><p>-- | --</p>",
                expected: "**Cost | Benefit**\n\n-- | --"
            ),
        ]

        for fixture in fixtures {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("paste-test-\(UUID().uuidString)"))
            pasteboard.clearContents()
            pasteboard.setData(Data(fixture.html.utf8), forType: .html)
            pasteboard.setString(fixture.plain, forType: .string)

            let textView = SourceTextView()
            XCTAssertTrue(textView.pasteMarkdown(from: pasteboard))
            XCTAssertEqual(textView.string, fixture.expected)
            pasteboard.clearContents()
        }
    }

    func testPasteFallsBackToPlainTextWhenRichRepresentationIsInvalid() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("paste-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(Data([0xFF, 0xFE, 0x00]), forType: .html)
        pasteboard.setString("**existing markdown**", forType: .string)
        defer { pasteboard.clearContents() }

        let textView = SourceTextView()
        XCTAssertTrue(textView.pasteMarkdown(from: pasteboard))
        XCTAssertEqual(textView.string, "**existing markdown**")
    }

    func testEditorContextMenuRoutesPasteToTheNativePasteAction() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = SourceTextView(frame: window.contentView!.bounds)
        window.contentView = textView
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        let menu = try XCTUnwrap(textView.menu(for: event))
        let pasteItem = try XCTUnwrap(menu.items.first(where: { $0.title == "Paste" }))
        XCTAssertEqual(pasteItem.action, #selector(NSText.paste(_:)))
    }

    func testImageCacheUsesResolvedURLsAndResetsAcrossNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let first = root.appendingPathComponent("One", isDirectory: true)
        let second = root.appendingPathComponent("Two", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try png.write(to: first.appendingPathComponent("image.png"))
        try png.write(to: second.appendingPathComponent("image.png"))

        let textView = SourceTextView()
        textView.liveDecorations.images = [
            .init(range: NSRange(location: 0, length: 1), url: "image.png", collapsed: true, dark: true)
        ]
        textView.configureImages(baseURL: first, loadRemoteImages: false)
        let firstLoaded = expectation(description: "first image loaded")
        textView.imageLoadHandler = { _, success in
            XCTAssertTrue(success)
            firstLoaded.fulfill()
        }
        textView.preloadImages()
        await fulfillment(of: [firstLoaded], timeout: 2)
        XCTAssertEqual(textView.cachedImageURLs, [first.appendingPathComponent("image.png").standardizedFileURL])

        textView.configureImages(baseURL: second, loadRemoteImages: false)
        XCTAssertTrue(textView.cachedImageURLs.isEmpty)
        let secondLoaded = expectation(description: "second image loaded")
        textView.imageLoadHandler = { _, success in
            XCTAssertTrue(success)
            secondLoaded.fulfill()
        }
        textView.preloadImages()
        await fulfillment(of: [secondLoaded], timeout: 2)
        XCTAssertEqual(textView.cachedImageURLs, [second.appendingPathComponent("image.png").standardizedFileURL])
    }

    func testMissingLocalImagesAreNegativeCachedAndRemoteImagesAreOptIn() async throws {
        let base = URL(fileURLWithPath: "/tmp/vulkanglass-missing", isDirectory: true)
        let missing = base.appendingPathComponent("missing.png").standardizedFileURL
        let textView = SourceTextView()
        textView.liveDecorations.images = [
            .init(range: NSRange(location: 0, length: 1), url: "missing.png", collapsed: true, dark: true)
        ]
        textView.configureImages(baseURL: base, loadRemoteImages: false)
        let failed = expectation(description: "missing image failed")
        textView.imageLoadHandler = { _, success in
            XCTAssertFalse(success)
            failed.fulfill()
        }
        textView.preloadImages()
        await fulfillment(of: [failed], timeout: 2)
        textView.preloadImages()
        XCTAssertEqual(textView.imageLoadAttempts[missing], 1)

        textView.configureImages(baseURL: nil, loadRemoteImages: false)
        textView.liveDecorations.images = [
            .init(range: NSRange(location: 0, length: 1), url: "https://example.com/pixel.png", collapsed: true, dark: true)
        ]
        textView.preloadImages()
        XCTAssertTrue(textView.imageLoadAttempts.isEmpty)
    }

    func testLivePreviewDrawingProducesAWindowlessSnapshot() {
        let text = "```swift\nlet value = 1\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n> quote\n---"
        let textView = SourceTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        textView.drawsBackground = false
        textView.string = text
        textView.liveDecorations = LivePreview.apply(
            to: textView.textStorage!,
            caret: (text as NSString).length,
            selection: NSRange(location: (text as NSString).length, length: 0),
            dark: true
        )
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let image = NSImage(size: textView.bounds.size)
        image.lockFocus()
        textView.draw(textView.bounds)
        image.unlockFocus()
        XCTAssertNotNil(image.tiffRepresentation)
        XCTAssertFalse(textView.liveDecorations.codeBlocks.isEmpty)
        XCTAssertFalse(textView.liveDecorations.tables.isEmpty)
        XCTAssertFalse(textView.liveDecorations.bars.isEmpty)
    }

    func testHoverColumnControlIsAccessibleAndMutatesThroughTheEditorDelegate() throws {
        let table = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        var changes: [String] = []
        let coordinator = SourceEditor.Coordinator(onChange: { changes.append($0) })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = SourceTextView(frame: window.contentView!.bounds)
        textView.delegate = coordinator
        textView.drawsBackground = false
        textView.string = table
        textView.liveDecorations = LivePreview.apply(
            to: textView.textStorage!,
            caret: (table as NSString).length,
            selection: NSRange(location: (table as NSString).length, length: 0),
            dark: true
        )
        window.contentView = textView
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        let width = try XCTUnwrap(textView.liveDecorations.tables.first).columnWidths.reduce(0, +)
        let point = NSPoint(
            x: textView.textContainerOrigin.x + width + 4,
            y: textView.textContainerOrigin.y + 19
        )
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: textView.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0
        ))
        textView.mouseMoved(with: event)

        let control = try XCTUnwrap(
            textView.subviews.compactMap { $0 as? NSButton }.first { !$0.isHidden }
        )
        XCTAssertEqual(control.toolTip, "Add column to the right")
        XCTAssertEqual(control.accessibilityLabel(), "Add column to the right")
        control.performClick(nil)

        XCTAssertEqual(GFM.splitTableRow(textView.string.components(separatedBy: "\n")[0]).count, 3)
        XCTAssertEqual(changes.last, textView.string)
    }

    func testTableGlyphsStayInsideTheGridBandsAndClicksClampToTheirCell() throws {
        let table = "| Alpha | Beta |\n| --- | --- |\n| one | two |"
        let textView = SourceTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        textView.textContainerInset = NSSize(width: VGTheme.documentHorizontalPadding, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = table
        textView.liveDecorations = LivePreview.apply(
            to: textView.textStorage!,
            caret: 0,
            selection: NSRange(location: 0, length: 0),
            dark: true,
            maximumTableWidth: textView.maximumTableWidth
        )
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        let decoration = try XCTUnwrap(textView.liveDecorations.tables.first)

        for row in decoration.rows {
            var bandStart = textView.textContainerOrigin.x
            for (index, cell) in row.cellRanges.enumerated() {
                let glyphs = layoutManager.glyphRange(forCharacterRange: cell, actualCharacterRange: nil)
                var glyphRect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
                glyphRect.origin.x += textView.textContainerOrigin.x
                let bandEnd = bandStart + decoration.columnWidths[index]
                XCTAssertGreaterThanOrEqual(glyphRect.minX, bandStart - 1)
                XCTAssertLessThanOrEqual(glyphRect.maxX, bandEnd + 1)
                bandStart = bandEnd
            }
        }

        let firstRow = decoration.rows[0]
        let firstBandEnd = textView.textContainerOrigin.x + decoration.columnWidths[0]
        let firstRowGlyphs = layoutManager.glyphRange(forCharacterRange: firstRow.range, actualCharacterRange: nil)
        var firstRowRect = layoutManager.boundingRect(forGlyphRange: firstRowGlyphs, in: container)
        firstRowRect.origin.y += textView.textContainerOrigin.y
        let insertion = textView.characterIndexForInsertion(
            at: NSPoint(x: firstBandEnd - 2, y: firstRowRect.midY)
        )
        XCTAssertGreaterThanOrEqual(insertion, firstRow.cellRanges[0].location)
        XCTAssertLessThanOrEqual(insertion, NSMaxRange(firstRow.cellRanges[0]))
    }

    func testMouseDragStillSelectsTextAcrossTableCells() throws {
        let table = "| Alpha | Beta |\n| --- | --- |\n| one | two |"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = SourceTextView(frame: window.contentView!.bounds)
        textView.textContainerInset = NSSize(width: VGTheme.documentHorizontalPadding, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = table
        textView.liveDecorations = LivePreview.apply(
            to: textView.textStorage!,
            caret: 0,
            selection: NSRange(location: 0, length: 0),
            dark: true,
            maximumTableWidth: textView.maximumTableWidth
        )
        window.contentView = textView
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let decoration = try XCTUnwrap(textView.liveDecorations.tables.first)
        let row = try XCTUnwrap(decoration.rows.first)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let glyphs = layoutManager.glyphRange(forCharacterRange: row.range, actualCharacterRange: nil)
        var rowRect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rowRect.origin.y += textView.textContainerOrigin.y
        let start = NSPoint(x: textView.textContainerOrigin.x + 16, y: rowRect.midY)
        let end = NSPoint(
            x: textView.textContainerOrigin.x + decoration.columnWidths[0] + 36,
            y: rowRect.midY
        )

        func event(_ type: NSEvent.EventType, at point: NSPoint, number: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: textView.convert(point, to: nil),
                modifierFlags: [],
                timestamp: TimeInterval(number) / 10,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: number,
                clickCount: type == .leftMouseDown ? 1 : 0,
                pressure: type == .leftMouseUp ? 0 : 1
            ))
        }

        let down = try event(.leftMouseDown, at: start, number: 1)
        NSApp.postEvent(try event(.leftMouseDragged, at: end, number: 2), atStart: false)
        NSApp.postEvent(try event(.leftMouseUp, at: end, number: 3), atStart: false)
        textView.mouseDown(with: down)
        XCTAssertGreaterThan(textView.selectedRange().length, 0)
    }

    func testCaretDrivenTableCommandsValidateAndMutateWithoutPointerHover() throws {
        func configuredView() -> SourceTextView {
            let table = "| A | B |\n| --- | --- |\n| 1 | 2 |"
            let view = SourceTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
            view.string = table
            view.liveDecorations = LivePreview.apply(
                to: view.textStorage!,
                caret: 3,
                selection: NSRange(location: 3, length: 0),
                dark: true,
                maximumTableWidth: view.maximumTableWidth
            )
            view.setSelectedRange(NSRange(location: 3, length: 0))
            return view
        }

        let columnView = configuredView()
        let columnItem = NSMenuItem(title: "Add Table Column", action: #selector(SourceTextView.addTableColumn(_:)), keyEquivalent: "")
        XCTAssertTrue(columnView.validateUserInterfaceItem(columnItem))
        columnView.addTableColumn(nil)
        XCTAssertEqual(GFM.splitTableRow(columnView.string.components(separatedBy: "\n")[0]).count, 3)

        let rowView = configuredView()
        let rowItem = NSMenuItem(title: "Add Table Row", action: #selector(SourceTextView.addTableRow(_:)), keyEquivalent: "")
        XCTAssertTrue(rowView.validateUserInterfaceItem(rowItem))
        rowView.addTableRow(nil)
        XCTAssertEqual(rowView.string.components(separatedBy: "\n").count, 4)

        rowView.setSelectedRange(NSRange(location: (rowView.string as NSString).length, length: 0))
        rowView.liveDecorations = .init()
        XCTAssertFalse(rowView.validateUserInterfaceItem(rowItem))
    }

    func testRowHoverControlMutatesAndLayoutIsCachedAcrossMouseMoves() throws {
        let table = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = SourceTextView(frame: window.contentView!.bounds)
        textView.string = table
        textView.liveDecorations = LivePreview.apply(
            to: textView.textStorage!,
            caret: 3,
            selection: NSRange(location: 3, length: 0),
            dark: true,
            maximumTableWidth: textView.maximumTableWidth
        )
        window.contentView = textView
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        let decoration = try XCTUnwrap(textView.liveDecorations.tables.first)
        let lastRow = try XCTUnwrap(decoration.rows.last)
        let glyphs = layoutManager.glyphRange(forCharacterRange: lastRow.range, actualCharacterRange: nil)
        var rowRect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rowRect.origin.y += textView.textContainerOrigin.y
        let point = NSPoint(
            x: textView.textContainerOrigin.x + decoration.columnWidths.reduce(0, +) / 2,
            y: rowRect.maxY + 4
        )
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: textView.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0
        ))
        textView.mouseMoved(with: event)
        let firstComputationCount = textView.tableLayoutComputationCount
        textView.mouseMoved(with: event)
        XCTAssertEqual(textView.tableLayoutComputationCount, firstComputationCount)

        let rowControl = try XCTUnwrap(textView.subviews.compactMap { $0 as? NSButton }.first { !$0.isHidden })
        XCTAssertEqual(rowControl.toolTip, "Add row below")
        rowControl.performClick(nil)
        XCTAssertEqual(textView.string.components(separatedBy: "\n").count, 4)
    }

    func testTableControlsHideWhenDecorationsDisappearAndIgnoreStaleRanges() throws {
        let table = "| A | B |\n| --- | --- |\n| 1 | 2 |"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = SourceTextView(frame: window.contentView!.bounds)
        textView.string = table
        let decorations = LivePreview.apply(
            to: textView.textStorage!,
            caret: 3,
            selection: NSRange(location: 3, length: 0),
            dark: true,
            maximumTableWidth: textView.maximumTableWidth
        )
        textView.liveDecorations = decorations
        window.contentView = textView
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let width = try XCTUnwrap(decorations.tables.first).columnWidths.reduce(0, +)
        let point = NSPoint(x: textView.textContainerOrigin.x + width + 2, y: textView.textContainerOrigin.y + 19)

        func hover() throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .mouseMoved,
                location: textView.convert(point, to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 0,
                pressure: 0
            ))
            textView.mouseMoved(with: event)
        }

        try hover()
        XCTAssertTrue(textView.subviews.contains { !$0.isHidden })
        textView.liveDecorations = .init()
        XCTAssertFalse(textView.subviews.contains { !$0.isHidden })

        textView.liveDecorations = decorations
        try hover()
        let staleControl = try XCTUnwrap(textView.subviews.compactMap { $0 as? NSButton }.first { !$0.isHidden })
        textView.string = "x"
        staleControl.performClick(nil)
        XCTAssertEqual(textView.string, "x")
    }

    func testWideTableAndControlsFitTheVisibleEditor() throws {
        let table = "| A | B | C | D | E | F |\n| --- | --- | --- | --- | --- | --- |\n| 1 | 2 | 3 | 4 | 5 | 6 |"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = SourceTextView(frame: window.contentView!.bounds)
        textView.textContainerInset = NSSize(width: VGTheme.documentHorizontalPadding, height: 8)
        textView.string = table
        textView.liveDecorations = LivePreview.apply(
            to: textView.textStorage!,
            caret: 3,
            selection: NSRange(location: 3, length: 0),
            dark: true,
            maximumTableWidth: textView.maximumTableWidth
        )
        window.contentView = textView
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let decoration = try XCTUnwrap(textView.liveDecorations.tables.first)
        let width = decoration.columnWidths.reduce(0, +)
        XCTAssertLessThanOrEqual(width, textView.maximumTableWidth + 0.01)

        let point = NSPoint(x: textView.textContainerOrigin.x + width + 2, y: textView.textContainerOrigin.y + 19)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: textView.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0
        ))
        textView.mouseMoved(with: event)
        let control = try XCTUnwrap(textView.subviews.compactMap { $0 as? NSButton }.first { !$0.isHidden })
        XCTAssertLessThanOrEqual(control.frame.maxX, textView.visibleRect.maxX + 0.01)
    }

    func testReadingPreviewRendersInLightAndDarkAppearances() {
        let markdown = "## Heading\n\n> [!TIP]\n> body\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n```swift\nlet x = 1\n```"
        for dark in [false, true] {
            let view = MarkdownPreviewView(
                text: markdown,
                noteTitles: [],
                baseURL: nil,
                dark: dark,
                loadRemoteImages: false,
                onWiki: { _ in }
            )
            .frame(width: 700, height: 600)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: 700, height: 600)
            XCTAssertNotNil(renderer.nsImage)
        }
    }

    func testReadingPreviewRendersSpanningTableDetailsAndDefinitionList() {
        let markdown = """
        <table>
        <caption>Shortcuts</caption>
        <tr><th rowspan="2">Action</th><th colspan="2">Keys</th></tr>
        <tr><td><kbd>⌘</kbd></td><td><a href="https://example.com">K</a></td></tr>
        </table>

        <details open>
        <summary>More <mark>information</mark></summary>
        ## Nested heading

        ```swift
        let x = 1
        ```

        > Nested quote

        - Nested item
        </details>

        <dl>
        <dt>Term</dt>
        <dd>Definition

        - First
        - Second</dd>
        </dl>
        """
        let view = MarkdownPreviewView(
            text: markdown,
            noteTitles: [],
            dark: false,
            onWiki: { _ in }
        )
        .frame(width: 700, height: 600)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 700, height: 600)
        XCTAssertNotNil(renderer.nsImage)
    }

    func testSpanningTableGeometryHonorsSpansWithoutOverlapAtNarrowWidths() throws {
        let cells: [GFM.HTMLTableCell] = [
            .init(row: 0, column: 0, rowSpan: 2, columnSpan: 1, content: "A", isHeader: true, alignment: .left),
            .init(row: 0, column: 1, rowSpan: 1, columnSpan: 2, content: "B", isHeader: true, alignment: .center),
            .init(row: 1, column: 1, rowSpan: 1, columnSpan: 1, content: "C", isHeader: false, alignment: .left),
            .init(row: 1, column: 2, rowSpan: 1, columnSpan: 1, content: "D", isHeader: false, alignment: .right),
        ]
        let bounds = CGRect(x: 12, y: 20, width: 180, height: 74)
        let frames = try cells.map {
            try XCTUnwrap(SpanningTableLayout.frame(
                for: $0,
                in: bounds,
                columnCount: 3,
                rowHeights: [34, 40]
            ))
        }
        XCTAssertEqual(frames[0], CGRect(x: 12, y: 20, width: 60, height: 74))
        XCTAssertEqual(frames[1], CGRect(x: 72, y: 20, width: 120, height: 34))
        XCTAssertEqual(frames[2], CGRect(x: 72, y: 54, width: 60, height: 40))
        XCTAssertEqual(frames[3], CGRect(x: 132, y: 54, width: 60, height: 40))
        for first in frames.indices {
            for second in frames.indices where second > first {
                XCTAssertFalse(frames[first].intersects(frames[second]))
            }
        }
    }

    func testReadingPreviewTableHeaderIsDistinctAndCellsFillTheirRows() async throws {
        let headerColor = NSColor(MarkdownPreviewTableStyle.background(dark: false, isHeader: true))
        let bodyColor = NSColor(MarkdownPreviewTableStyle.background(dark: false, isHeader: false))
        XCTAssertNotEqual(headerColor, bodyColor)

        let renderedView = MarkdownPreviewView(
            text: "| Header One | Header Two |\n| --- | --- |\n| Body One | Body Two |",
            noteTitles: [],
            dark: false,
            onWiki: { _ in }
        )
        .frame(width: 400, height: 120, alignment: .topLeading)
        .background(Color.white)
        let renderedHostingView = NSHostingView(rootView: renderedView)
        renderedHostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        renderedHostingView.layoutSubtreeIfNeeded()
        renderedHostingView.displayIfNeeded()
        let bitmap = try XCTUnwrap(renderedHostingView.bitmapImageRepForCachingDisplay(in: renderedHostingView.bounds))
        renderedHostingView.cacheDisplay(in: renderedHostingView.bounds, to: bitmap)
        var headerBackgroundPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.90,
                   color.redComponent < 0.995,
                   abs(color.redComponent - color.greenComponent) < 0.01,
                   abs(color.redComponent - color.blueComponent) < 0.01 {
                    headerBackgroundPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(headerBackgroundPixels, 500)

        let metrics = try await readingPreviewTableMetrics(
            markdown: "| #tag | Plain |\n| --- | --- |\n| Body | [^1] |",
            paneWidth: 500
        )
        let rows = Dictionary(grouping: metrics, by: \.row)
        XCTAssertEqual(rows.count, 2)
        for cells in rows.values {
            XCTAssertEqual(cells.count, 2)
            let expectedHeight = try XCTUnwrap(cells.first?.size.height)
            for cell in cells.dropFirst() {
                XCTAssertEqual(cell.size.height, expectedHeight, accuracy: 0.5)
            }
        }
    }

    func testReadingPreviewFillsWideAndNarrowPanesWhileCappingItsColumn() async throws {
        for paneWidth: CGFloat in [1_000, 600, 100] {
            let metrics = try await readingPreviewMetrics(paneWidth: paneWidth)
            let scrollWidth = try XCTUnwrap(metrics.scrollSurfaceSize?.width)
            let columnWidth = try XCTUnwrap(metrics.readingColumnSize?.width)
            XCTAssertEqual(scrollWidth, paneWidth, accuracy: 1)
            XCTAssertEqual(
                columnWidth,
                VGTheme.readingColumnWidth(paneWidth: paneWidth),
                accuracy: 1
            )
        }
    }

    func testNoteEditorFillsItsPaneInReadingAndSourceModes() async throws {
        let paneSize = CGSize(width: 1_000, height: 600)
        for mode in [EditorMode.preview, .source] {
            let size = try await noteEditorSize(mode: mode, paneSize: paneSize)
            XCTAssertEqual(size.width, paneSize.width, accuracy: 1, "Mode: \(mode)")
            XCTAssertEqual(size.height, paneSize.height, accuracy: 1, "Mode: \(mode)")
        }
    }

    func testDocumentLeadingEdgeStaysAlignedWhenSwitchingFromPreviewToSource() async throws {
        for paneWidth: CGFloat in [600, 1_000] {
            let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
            let path = "/tmp/VulkanGlass-leading-inset-test-\(Int(paneWidth)).md"
            model.tabs = [
                NoteTab(
                    path: path,
                    title: "Aligned Title",
                    content: "Body",
                    originalContent: "Body",
                    isStandalone: true
                )
            ]
            model.activeTabID = path
            model.editorMode = .preview

            let titleReported = expectation(description: "Title leading edge at \(paneWidth)")
            let previewReported = expectation(description: "Preview leading edge at \(paneWidth)")
            let sourceReported = expectation(description: "Source leading edge at \(paneWidth)")
            var titleLeading: CGFloat?
            var previewLeading: CGFloat?
            var sourceLeading: CGFloat?

            let view = NoteEditorView(onDocumentLeading: { element, leading in
                switch element {
                case .title where titleLeading == nil:
                    titleLeading = leading
                    titleReported.fulfill()
                case .previewBody where previewLeading == nil:
                    previewLeading = leading
                    previewReported.fulfill()
                case .sourceBody where sourceLeading == nil:
                    sourceLeading = leading
                    sourceReported.fulfill()
                default:
                    break
                }
            })
                .environment(model)
                .frame(width: paneWidth, height: 400, alignment: .topLeading)
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(x: 0, y: 0, width: paneWidth, height: 400)
            hostingView.layoutSubtreeIfNeeded()

            await fulfillment(of: [titleReported, previewReported], timeout: 2)
            let resolvedTitleLeading = try XCTUnwrap(titleLeading)
            XCTAssertEqual(
                resolvedTitleLeading,
                VGTheme.documentHorizontalPadding,
                accuracy: 1,
                "Pane width: \(paneWidth)"
            )
            XCTAssertEqual(
                try XCTUnwrap(previewLeading),
                resolvedTitleLeading,
                accuracy: 1,
                "Pane width: \(paneWidth)"
            )

            model.editorMode = .source
            await fulfillment(of: [sourceReported], timeout: 2)
            hostingView.layoutSubtreeIfNeeded()
            let resolvedSourceLeading = try XCTUnwrap(sourceLeading)
            XCTAssertEqual(
                resolvedSourceLeading,
                resolvedTitleLeading,
                accuracy: 1,
                "Pane width: \(paneWidth)"
            )
            let textView = try XCTUnwrap(firstSubview(of: NSTextView.self, in: hostingView))
            let actualSourceLeading = textView.convert(textView.textContainerOrigin, to: hostingView).x
            XCTAssertEqual(
                actualSourceLeading,
                resolvedSourceLeading,
                accuracy: 1,
                "Pane width: \(paneWidth)"
            )
            withExtendedLifetime(hostingView) {}
        }
    }

    func testTitleGlyphLeadingEdgeStaysAlignedWhileRenaming() async throws {
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        let path = "/tmp/VulkanGlass-title-rename-leading-test.md"
        model.tabs = [
            NoteTab(
                path: path,
                title: "Aligned Title",
                content: "Body",
                originalContent: "Body",
                isStandalone: true
            )
        ]
        model.activeTabID = path
        model.editorMode = .source
        model.beginEditingTitle(for: path)

        let titleReported = expectation(description: "Editing title leading edge")
        let sourceReported = expectation(description: "Source leading edge while renaming")
        var titleLeading: CGFloat?
        var sourceLeading: CGFloat?
        let view = NoteEditorView(onDocumentLeading: { element, leading in
            switch element {
            case .title where titleLeading == nil:
                titleLeading = leading
                titleReported.fulfill()
            case .sourceBody where sourceLeading == nil:
                sourceLeading = leading
                sourceReported.fulfill()
            default:
                break
            }
        })
            .environment(model)
            .frame(width: 600, height: 400, alignment: .topLeading)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        hostingView.layoutSubtreeIfNeeded()

        await fulfillment(of: [titleReported, sourceReported], timeout: 2)
        hostingView.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(firstSubview(of: InlineRenameNSTextField.self, in: hostingView))
        let titleRect = try XCTUnwrap(field.cell?.titleRect(forBounds: field.bounds))
        let actualTitleLeading = field.convert(titleRect.origin, to: hostingView).x
        let resolvedTitleLeading = try XCTUnwrap(titleLeading)
        XCTAssertEqual(actualTitleLeading, resolvedTitleLeading, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(sourceLeading), resolvedTitleLeading, accuracy: 1)
        withExtendedLifetime(hostingView) {}
    }

    private func readingPreviewMetrics(paneWidth: CGFloat) async throws -> MarkdownPreviewLayoutMetrics {
        let reported = expectation(description: "Preview reports layout at \(paneWidth) points")
        var result: MarkdownPreviewLayoutMetrics?
        var fulfilled = false
        let view = MarkdownPreviewView(
            text: "Body",
            noteTitles: [],
            onLayout: { metrics in
                result = metrics
                if !fulfilled {
                    fulfilled = true
                    reported.fulfill()
                }
            },
            onWiki: { _ in }
        )
        .frame(width: paneWidth, height: 600, alignment: .topLeading)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: paneWidth, height: 600)
        hostingView.layoutSubtreeIfNeeded()

        await fulfillment(of: [reported], timeout: 2)
        withExtendedLifetime(hostingView) {}
        return try XCTUnwrap(result)
    }

    private func readingPreviewTableMetrics(
        markdown: String,
        paneWidth: CGFloat
    ) async throws -> [MarkdownPreviewTableCellLayout] {
        let reported = expectation(description: "Preview reports table-cell layout")
        var result: [MarkdownPreviewTableCellLayout] = []
        var fulfilled = false
        let view = MarkdownPreviewView(
            text: markdown,
            noteTitles: [],
            onLayout: { metrics in
                result = metrics.tableCells
                if result.count == 4, !fulfilled {
                    fulfilled = true
                    reported.fulfill()
                }
            },
            onWiki: { _ in }
        )
        .frame(width: paneWidth, height: 300, alignment: .topLeading)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: paneWidth, height: 300)
        hostingView.layoutSubtreeIfNeeded()

        await fulfillment(of: [reported], timeout: 2)
        withExtendedLifetime(hostingView) {}
        return result
    }

    private func noteEditorSize(mode: EditorMode, paneSize: CGSize) async throws -> CGSize {
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        let path = "/tmp/VulkanGlass-layout-test.md"
        model.tabs = [
            NoteTab(
                path: path,
                title: "Layout Test",
                content: "Body",
                originalContent: "Body",
                isStandalone: true
            )
        ]
        model.activeTabID = path
        model.editorMode = mode

        let reported = expectation(description: "Note editor reports \(mode) layout")
        var result: CGSize?
        var fulfilled = false
        let view = NoteEditorView(onLayout: { size in
            result = size
            if !fulfilled {
                fulfilled = true
                reported.fulfill()
            }
        })
        .environment(model)
        .frame(width: paneSize.width, height: paneSize.height, alignment: .topLeading)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: paneSize)
        hostingView.layoutSubtreeIfNeeded()

        await fulfillment(of: [reported], timeout: 2)
        withExtendedLifetime(hostingView) {}
        return try XCTUnwrap(result)
    }

    private func firstSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    func testKeyboardNavigationConfirmsSelectedWikiSuggestion() {
        let coordinator = SourceEditor.Coordinator(onChange: { _ in })
        let textView = SourceTextView()
        textView.delegate = coordinator
        textView.wikiHandler = coordinator
        textView.string = "[["
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.textView = textView
        coordinator.notes = [note("Alpha.md", "Alpha"), note("Beta.md", "Beta")]

        coordinator.refreshWikiPopup()
        XCTAssertTrue(coordinator.isPopupVisible)
        XCTAssertTrue(coordinator.handleCommand(#selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(coordinator.selectedSuggestionIndex, 1)
        XCTAssertTrue(coordinator.handleCommand(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(textView.string, "[[Beta]]")
        XCTAssertFalse(coordinator.isPopupVisible)
    }

    func testEscapeSuppressesPopupUntilQueryChanges() {
        let coordinator = SourceEditor.Coordinator(onChange: { _ in })
        let textView = SourceTextView()
        textView.string = "[["
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.textView = textView
        coordinator.notes = [note("Alpha.md", "Alpha")]

        coordinator.refreshWikiPopup()
        XCTAssertTrue(coordinator.handleCommand(#selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(coordinator.isPopupVisible)
        coordinator.refreshWikiPopup()
        XCTAssertFalse(coordinator.isPopupVisible)

        textView.string = "[[A"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        coordinator.refreshWikiPopup()
        XCTAssertTrue(coordinator.isPopupVisible)
        coordinator.dismissPopup()
    }

    func testSelectionClampsWhenSuggestionsShrinkAndTabCompletesFallback() {
        let coordinator = SourceEditor.Coordinator(onChange: { _ in })
        let textView = SourceTextView()
        textView.string = "[["
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.textView = textView
        coordinator.notes = [note("Alpha.md", "Alpha"), note("Beta.md", "Beta")]
        coordinator.refreshWikiPopup()
        XCTAssertTrue(coordinator.handleCommand(#selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(coordinator.selectedSuggestionIndex, 1)

        textView.string = "[[A"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        coordinator.refreshWikiPopup()
        XCTAssertEqual(coordinator.selectedSuggestionIndex, 0)

        textView.string = "[[Unknown"
        textView.setSelectedRange(NSRange(location: 9, length: 0))
        coordinator.refreshWikiPopup()
        XCTAssertTrue(coordinator.handleCommand(#selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(textView.string, "[[Unknown]]")
        XCTAssertFalse(coordinator.isPopupVisible)
    }

    func testDismantleDisconnectsEditorAndDismissesPopup() {
        let coordinator = SourceEditor.Coordinator(onChange: { _ in })
        let textView = SourceTextView()
        let scroll = NSScrollView()
        scroll.documentView = textView
        textView.delegate = coordinator
        textView.wikiHandler = coordinator
        textView.string = "[["
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.textView = textView
        coordinator.notes = [note("Alpha.md", "Alpha")]
        coordinator.refreshWikiPopup()
        XCTAssertTrue(coordinator.isPopupVisible)

        SourceEditor.dismantleNSView(scroll, coordinator: coordinator)

        XCTAssertNil(textView.delegate)
        XCTAssertNil(textView.wikiHandler)
        XCTAssertNil(coordinator.textView)
        XCTAssertFalse(coordinator.isPopupVisible)
    }

    func testWindowChromeViewDoesNotRetainItselfWhileUnattached() {
        weak var weakView: WindowChromeView?
        autoreleasepool {
            let view = WindowChromeView()
            weakView = view
        }
        XCTAssertNil(weakView)
    }

    func testWindowChromeConfiguresWindowOnAttachment() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let view = WindowChromeView()
        window.contentView = view

        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertNil(window.toolbar)
        XCTAssertEqual(
            WindowChromeConfigurator.trafficLightY(buttonHeight: 12, containerHeight: 28, flipped: false),
            0
        )
        XCTAssertEqual(
            WindowChromeConfigurator.trafficLightY(buttonHeight: 12, containerHeight: VGTheme.titleBarHeight, flipped: false),
            (VGTheme.titleBarHeight - 12) / 2
        )
        XCTAssertEqual(
            WindowChromeConfigurator.trafficLightY(buttonHeight: 12, containerHeight: VGTheme.titleBarHeight, flipped: true),
            (VGTheme.titleBarHeight - 12) / 2
        )
    }

    func testCancelledToastDelayDoesNotRequestDismissal() async {
        let task = Task { await ErrorToastView.shouldAutoDismiss(after: .seconds(5)) }
        task.cancel()
        let cancelledResult = await task.value
        let completedResult = await ErrorToastView.shouldAutoDismiss(after: .milliseconds(1))
        XCTAssertFalse(cancelledResult)
        XCTAssertTrue(completedResult)
    }

    private func note(_ relative: String, _ title: String) -> NoteMeta {
        NoteMeta(
            path: "/vault/\(relative)",
            relativePath: relative,
            title: title,
            content: "",
            tags: [],
            wikiLinks: [],
            headings: []
        )
    }

    private func sourceEditorHTML(for text: String) -> String {
        let rows = text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { line in
                guard !line.isEmpty else { return "<div><br></div>" }
                let escaped = String(line)
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                return "<div><span>\(escaped)</span></div>"
            }
            .joined()
        return #"<meta charset="utf-8"><div style="font-family: 'FiraCode Nerd Font', Menlo, monospace; font-size: 12px; line-height: 18px; white-space: pre;">"#
            + rows
            + "</div>"
    }

}
