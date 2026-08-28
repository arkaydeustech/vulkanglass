import AppKit
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

@MainActor
final class EditorLifecycleTests: XCTestCase {
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
