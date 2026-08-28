import XCTest
@testable import VulkanGlass

final class GraphSimTests: XCTestCase {
    func testDuplicateTitlesDoNotTrapAndResolveDeterministically() {
        let first = note(path: "/vault/A/Index.md", relative: "A/Index.md", links: ["B/Index"])
        let second = note(path: "/vault/B/Index.md", relative: "B/Index.md")
        let sim = GraphSim()
        sim.rebuild(notes: [first, second], allNotes: [first, second], linkedTitles: [])
        XCTAssertEqual(sim.nodes.count, 2)
        XCTAssertEqual(sim.edges, [SimEdge(source: first.path, target: second.path)])
    }

    func testSimulationSettles() {
        let notes = (0..<40).map {
            note(path: "/vault/\($0).md", relative: "\($0).md")
        }
        let sim = GraphSim()
        sim.rebuild(notes: notes, allNotes: notes, linkedTitles: [])
        var moving = true
        for _ in 0..<10_000 where moving { moving = sim.tick() }
        XCTAssertFalse(moving)
    }

    private func note(path: String, relative: String, links: [String] = []) -> NoteMeta {
        NoteMeta(path: path, relativePath: relative, title: Markdown.title(from: path), content: "", tags: [], wikiLinks: links, headings: [])
    }
}

final class FileServiceTests: XCTestCase {
    func testWikiAndFolderTraversalAreRejected() throws {
        let root = try temporaryDirectory()
        XCTAssertThrowsError(try FileService.createFromWiki(root: root, target: "../outside"))
        XCTAssertThrowsError(try FileService.createFromWiki(root: root, target: "../../.ssh/config"))
        XCTAssertThrowsError(try FileService.createFolder(in: root, name: ".."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("outside.md").path))
    }

    func testSymlinkEscapeIsRejectedAndIndexerDoesNotFollowIt() throws {
        let parent = try temporaryDirectory()
        let root = parent.appendingPathComponent("vault")
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "# Secret".write(to: outside.appendingPathComponent("Secret.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)

        XCTAssertThrowsError(try FileService.createFromWiki(root: root, target: "escape/New"))
        XCTAssertTrue(FileService.index(at: root).isEmpty)
    }

    func testIndexUsesAnchoredRelativePathAndSkipsUnreadableEncoding() throws {
        let parent = try temporaryDirectory()
        let root = parent.appendingPathComponent("vault")
        let nested = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "# Good".write(to: nested.appendingPathComponent("Good.md"), atomically: true, encoding: .utf8)
        try Data([0xFF, 0xFE]).write(to: root.appendingPathComponent("Bad.md"))

        XCTAssertEqual(FileService.index(at: root).map(\.relativePath), ["vault/Good.md"])
    }

    func testDirectoryExistsRejectsMissingAndFilePaths() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("Note.md")
        try "hi".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileService.directoryExists(at: root.path))
        XCTAssertFalse(FileService.directoryExists(at: file.path))
        XCTAssertFalse(FileService.directoryExists(at: root.appendingPathComponent("missing-vault").path))
    }

    func testPathQualifiedWikiLinkWinsOverDuplicateTitle() throws {
        let root = try temporaryDirectory()
        for folder in ["A", "B"] {
            let directory = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "# Index".write(to: directory.appendingPathComponent("Index.md"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(
            FileService.resolveWiki(root: root, target: "B/Index")?.path,
            FileService.canonicalURL(root.appendingPathComponent("B/Index.md")).path
        )
    }

    func testRenameMovesFileAndRejectsCollisionAndTraversal() throws {
        let root = try temporaryDirectory()
        let nested = root.appendingPathComponent("Daily")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let source = nested.appendingPathComponent("Untitled.md")
        let taken = nested.appendingPathComponent("Taken.md")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        try "taken".write(to: taken, atomically: true, encoding: .utf8)

        let renamed = try FileService.rename(source, to: "Hello", root: root)
        XCTAssertEqual(renamed.lastPathComponent, "Hello.md")
        XCTAssertEqual(try FileService.read(renamed), "hello")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            FileService.canonicalURL(renamed.deletingLastPathComponent()).path,
            FileService.canonicalURL(nested).path
        )

        XCTAssertThrowsError(try FileService.rename(renamed, to: "Taken", root: root)) { error in
            XCTAssertEqual(error as? FileServiceError, .nameTaken("Taken.md"))
        }
        XCTAssertThrowsError(try FileService.rename(renamed, to: "../Escape", root: root))
        XCTAssertThrowsError(try FileService.rename(renamed, to: "foo/bar", root: root))
        XCTAssertThrowsError(try FileService.markdownFileName(from: ""))
        XCTAssertEqual(try FileService.markdownFileName(from: "Note.md"), "Note.md")
    }

    func testRenameCanChangeOnlyCase() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("untitled.md")
        try "body".write(to: source, atomically: true, encoding: .utf8)
        let renamed = try FileService.rename(source, to: "Untitled", root: root)
        XCTAssertEqual(renamed.lastPathComponent, "Untitled.md")
        XCTAssertEqual(try FileService.read(renamed), "body")
    }

    func testStandaloneSymlinkRenameIsRejectedWithoutMovingTarget() throws {
        let parent = try temporaryDirectory()
        let sourceDirectory = parent.appendingPathComponent("source")
        let linkDirectory = parent.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        let target = sourceDirectory.appendingPathComponent("Target.md")
        let link = linkDirectory.appendingPathComponent("Linked.md")
        try "target".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try FileService.rename(link, to: "Renamed", root: nil)) { error in
            XCTAssertEqual(error as? FileServiceError, .symbolicLinkRenameUnsupported(link.path))
        }
        XCTAssertEqual(try FileService.read(target), "target")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkDirectory.appendingPathComponent("Renamed.md").path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

final class ThemeLayoutTests: XCTestCase {
    func testRightSidebarNeverExceedsEightyPercentOfTheWindow() {
        XCTAssertEqual(VGTheme.cappedSidebarWidth(windowWidth: 2000), VGTheme.sidebarWidth)
        XCTAssertEqual(VGTheme.cappedSidebarWidth(windowWidth: 200), 160, accuracy: 0.01)
        XCTAssertEqual(VGTheme.cappedSidebarWidth(windowWidth: 0), 0)
    }

    func testTitleBarIsCompactAroundItsIcons() {
        XCTAssertGreaterThanOrEqual(VGTheme.trafficLightsInset, 70)
        XCTAssertEqual(VGTheme.titleBarHeight, VGTheme.titleBarIconSize + 8)
        XCTAssertGreaterThan(VGTheme.titleBarHeight, VGTheme.titleBarIconSize)
        XCTAssertGreaterThanOrEqual(VGTheme.titleBarIconSize, 26)
    }

    func testLeftSidebarWidthClampsToAUsableRange() {
        XCTAssertEqual(
            VGTheme.clampedLeftSidebarWidth(100, windowWidth: 2000, rightSidebarVisible: true),
            VGTheme.sidebarMinWidth
        )
        XCTAssertEqual(
            VGTheme.clampedLeftSidebarWidth(900, windowWidth: 2000, rightSidebarVisible: true),
            VGTheme.sidebarMaxWidth
        )
        XCTAssertEqual(
            VGTheme.clampedLeftSidebarWidth(240, windowWidth: 2000, rightSidebarVisible: true),
            240
        )
    }

    func testBothSidebarsReserveMinimumEditorWidthAtMinimumWindowSize() {
        let windowWidth: CGFloat = 860
        let left = VGTheme.clampedLeftSidebarWidth(
            VGTheme.sidebarMaxWidth,
            windowWidth: windowWidth,
            rightSidebarVisible: true
        )
        let right = VGTheme.cappedSidebarWidth(windowWidth: windowWidth)
        let editor = windowWidth - VGTheme.ribbonWidth - left - VGTheme.splitHandleWidth - 1 - right

        XCTAssertGreaterThanOrEqual(editor, VGTheme.editorMinWidth)
        XCTAssertGreaterThanOrEqual(left, VGTheme.sidebarMinWidth)
    }

    func testCollapsedSidebarControlStartsAfterTrafficLights() {
        XCTAssertGreaterThanOrEqual(
            VGTheme.ribbonWidth + VGTheme.collapsedLeftTitleBarInset,
            VGTheme.trafficLightsInset
        )
    }
}
