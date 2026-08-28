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

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
