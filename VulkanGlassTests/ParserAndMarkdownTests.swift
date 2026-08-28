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
