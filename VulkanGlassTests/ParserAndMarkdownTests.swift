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
            [.table([["A", "B"], ["1", "2"]], [.left, .left])]
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
        XCTAssertEqual(decorations.tables.map { $0.rowRanges.count }, [3, 3])
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
        XCTAssertTrue(decorations.tables[0].collapsed)
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

    private func isHidden(_ storage: NSTextStorage, at location: Int) -> Bool {
        let font = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        return (font?.pointSize ?? 16) < 1
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

        XCTAssertTrue(textView.pastePlainText(from: pasteboard))
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

        XCTAssertTrue(textView.pastePlainText(from: pasteboard))
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

        XCTAssertFalse(textView.pastePlainText(from: pasteboard))
        XCTAssertEqual(textView.string, "Unchanged")
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
        let view = NoteEditorView { size in
            result = size
            if !fulfilled {
                fulfilled = true
                reported.fulfill()
            }
        }
        .environment(model)
        .frame(width: paneSize.width, height: paneSize.height, alignment: .topLeading)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: paneSize)
        hostingView.layoutSubtreeIfNeeded()

        await fulfillment(of: [reported], timeout: 2)
        withExtendedLifetime(hostingView) {}
        return try XCTUnwrap(result)
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

}
