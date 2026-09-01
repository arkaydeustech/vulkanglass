import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import VulkanGlass

final class QuickLookPreviewTests: XCTestCase {
    func testLoadsUTF8MarkdownAndUsesContainingDirectoryAsResourceBase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("Preview.md")
        let markdown = "# Preview\n\n![Glass](images/glass.png)"
        try Data(markdown.utf8).write(to: file)

        let document = try QuickLookPreviewDocument.load(from: file)

        XCTAssertEqual(document.text, markdown)
        XCTAssertEqual(document.baseURL, directory)
        XCTAssertEqual(document.blocks, [.heading(1, "Preview"), .lines(["![Glass](images/glass.png)"])])
    }

    func testRejectsMarkdownThatIsNotUTF8() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).md")
        try Data([0xff, 0xfe, 0x00]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertThrowsError(try QuickLookPreviewDocument.load(from: file)) { error in
            XCTAssertEqual(error as? QuickLookPreviewError, .invalidTextEncoding)
        }
    }

    func testRejectsMarkdownAboveThePreviewLimitWithoutReadingTheWholeFile() throws {
        let file = temporaryFileURL()
        try Data(repeating: 0x61, count: 65).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertThrowsError(
            try QuickLookPreviewDocument.load(from: file, maximumByteCount: 64)
        ) { error in
            XCTAssertEqual(error as? QuickLookPreviewError, .fileTooLarge(maximumBytes: 64))
        }
    }

    func testLoadsAnEmptyMarkdownFile() throws {
        let file = temporaryFileURL()
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let document = try QuickLookPreviewDocument.load(from: file)

        XCTAssertEqual(document.text, "")
        XCTAssertEqual(document.blocks, [])
    }

    func testMissingFilePropagatesTheFileSystemError() {
        let missing = temporaryFileURL()

        XCTAssertThrowsError(try QuickLookPreviewDocument.load(from: missing)) { error in
            XCTAssertNil(error as? QuickLookPreviewError)
        }
    }

    func testDirectoryCannotBeLoadedAsMarkdown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try QuickLookPreviewDocument.load(from: directory)) { error in
            XCTAssertNil(error as? QuickLookPreviewError)
        }
    }

    func testLeadingTitleVisibilityIsExplicitlyConfigurable() {
        let markdown = "# Visible title\n\nBody"
        let hidden = MarkdownPreviewView(text: markdown, noteTitles: [], onWiki: { _ in })
        let visible = MarkdownPreviewView(
            text: markdown,
            noteTitles: [],
            hidesLeadingTitle: false,
            onWiki: { _ in }
        )

        XCTAssertEqual(hidden.displayBlocks, [.lines(["Body"])])
        XCTAssertEqual(visible.displayBlocks, [.heading(1, "Visible title"), .lines(["Body"])])
    }

    @MainActor
    func testQuickLookViewUsesItsSecurityAndTitleConfigurationInBothAppearances() throws {
        let file = temporaryFileURL()
        try Data("# Preview\n\n![Glass](images/glass.png)".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let document = try QuickLookPreviewDocument.load(from: file)
        let quickLookView = QuickLookMarkdownView(document: document)

        XCTAssertFalse(QuickLookMarkdownView.isDark(colorScheme: .light))
        XCTAssertTrue(QuickLookMarkdownView.isDark(colorScheme: .dark))

        let configured = quickLookView.markdownPreview(dark: false)
        XCTAssertEqual(configured.text, document.text)
        XCTAssertEqual(configured.baseURL, document.baseURL)
        XCTAssertFalse(configured.dark)
        XCTAssertFalse(configured.loadLocalImages)
        XCTAssertFalse(configured.loadRemoteImages)
        XCTAssertFalse(configured.hidesLeadingTitle)
        XCTAssertEqual(configured.displayBlocks.first, .heading(1, "Preview"))

        for colorScheme in [ColorScheme.light, .dark] {
            let rendered = quickLookView
                .environment(\.colorScheme, colorScheme)
                .frame(width: 500, height: 400)
            let renderer = ImageRenderer(content: rendered)
            renderer.proposedSize = ProposedViewSize(width: 500, height: 400)
            XCTAssertNotNil(renderer.nsImage)
        }
    }

    @MainActor
    func testPreviewControllerInstallsAndReplacesHostedContent() async throws {
        let firstFile = temporaryFileURL()
        let secondFile = temporaryFileURL()
        try Data("# First".utf8).write(to: firstFile)
        try Data("# Second".utf8).write(to: secondFile)
        defer {
            try? FileManager.default.removeItem(at: firstFile)
            try? FileManager.default.removeItem(at: secondFile)
        }

        let controller = PreviewViewController()
        _ = controller.view
        try await controller.preparePreviewOfFile(at: firstFile)

        let firstChild = try XCTUnwrap(controller.children.first)
        XCTAssertEqual(controller.children.count, 1)
        XCTAssertEqual(controller.view.subviews, [firstChild.view])
        XCTAssertFalse(firstChild.view.translatesAutoresizingMaskIntoConstraints)
        XCTAssertEqual(constraintsAttaching(firstChild.view, to: controller.view).count, 4)

        try await controller.preparePreviewOfFile(at: secondFile)

        let secondChild = try XCTUnwrap(controller.children.first)
        XCTAssertEqual(controller.children.count, 1)
        XCTAssertEqual(controller.view.subviews, [secondChild.view])
        XCTAssertFalse(firstChild === secondChild)
        XCTAssertNil(firstChild.parent)
        XCTAssertNil(firstChild.view.superview)
    }

    @MainActor
    func testPreviewControllerPropagatesLoadErrorsWithoutInstallingContent() async {
        let controller = PreviewViewController()
        _ = controller.view

        do {
            try await controller.preparePreviewOfFile(at: temporaryFileURL())
            XCTFail("Expected the missing-file error to be propagated")
        } catch {
            XCTAssertNil(error as? QuickLookPreviewError)
        }
        XCTAssertTrue(controller.children.isEmpty)
        XCTAssertTrue(controller.view.subviews.isEmpty)
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).md")
    }

    @MainActor
    private func constraintsAttaching(_ child: NSView, to parent: NSView) -> [NSLayoutConstraint] {
        parent.constraints.filter { constraint in
            (constraint.firstItem as? NSView) === child
                || (constraint.secondItem as? NSView) === child
        }
    }
}
