import XCTest
@testable import VulkanGlass

@MainActor
final class AppModelTests: XCTestCase {
    func testAutosavePersistsTheEditedTabAfterSwitching() async throws {
        let root = try temporaryDirectory()
        let a = root.appendingPathComponent("A.md")
        let b = root.appendingPathComponent("B.md")
        try "a".write(to: a, atomically: true, encoding: .utf8)
        try "b".write(to: b, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.tabs = [
            NoteTab(path: a.path, title: "A", content: "a", originalContent: "a", isStandalone: true),
            NoteTab(path: b.path, title: "B", content: "b", originalContent: "b", isStandalone: true)
        ]
        model.activeTabID = a.path

        model.updateContent(a.path, "edited a")
        model.setActiveTab(b.path)
        model.updateContent(b.path, "edited b")
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(try FileService.read(a), "edited a")
        XCTAssertEqual(try FileService.read(b), "edited b")
    }

    func testClosingDirtyTabFlushesIt() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("Note.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.tabs = [NoteTab(path: file.path, title: "Note", content: "new", originalContent: "old", isStandalone: true)]
        model.activeTabID = file.path

        await model.closeTab(file.path)

        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(try FileService.read(file), "new")
    }

    func testFailedSaveRemainsDirtyAndPublishesError() async {
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        let path = "/dev/null/Note.md"
        model.tabs = [NoteTab(path: path, title: "Note", content: "new", originalContent: "old", isStandalone: true)]
        model.activeTabID = path

        let saved = await model.save(id: path, sync: false)
        XCTAssertFalse(saved)
        XCTAssertTrue(model.tabs[0].dirty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testRefreshReconcilesCleanTabAndPreservesDirtyConflict() async throws {
        let root = try temporaryDirectory()
        let clean = root.appendingPathComponent("Clean.md")
        let dirty = root.appendingPathComponent("Dirty.md")
        try "remote clean".write(to: clean, atomically: true, encoding: .utf8)
        try "remote dirty".write(to: dirty, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        model.tabs = [
            NoteTab(path: clean.path, title: "Clean", content: "old", originalContent: "old", isStandalone: false),
            NoteTab(path: dirty.path, title: "Dirty", content: "local edit", originalContent: "old", isStandalone: false)
        ]

        await model.refreshVault(reconcileTabs: true)

        XCTAssertEqual(model.tabs[0].content, "remote clean")
        XCTAssertEqual(model.tabs[1].content, "local edit")
        XCTAssertNotNil(model.errorMessage)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
