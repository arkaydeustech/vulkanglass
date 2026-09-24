import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import VulkanGlass

final class FileMoveServiceTests: XCTestCase {
    func testMoveIntoFolderKeepsNameAndCanMoveBackToRoot() throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Ideas")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Loose.md")
        try "loose".write(to: source, atomically: true, encoding: .utf8)

        let moved = try FileService.move(source, into: folder, root: root)

        XCTAssertEqual(moved.path, FileService.canonicalURL(folder.appendingPathComponent("Loose.md")).path)
        XCTAssertEqual(try FileService.read(moved), "loose")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

        let back = try FileService.move(moved, into: root, root: root)
        XCTAssertEqual(back.path, FileService.canonicalURL(source).path)
        XCTAssertEqual(try FileService.read(source), "loose")
    }

    func testMoveIntoTheCurrentFolderLeavesTheNoteInPlace() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Same.md")
        try "same".write(to: source, atomically: true, encoding: .utf8)

        XCTAssertEqual(try FileService.move(source, into: root, root: root), source.standardizedFileURL)
        XCTAssertEqual(try FileService.read(source), "same")
    }

    func testMoveRejectsCollisionsEscapesAndNonFolders() throws {
        let parent = try temporaryDirectory()
        let root = parent.appendingPathComponent("vault")
        let folder = root.appendingPathComponent("Ideas")
        let outside = parent.appendingPathComponent("outside")
        for directory in [folder, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let source = root.appendingPathComponent("Note.md")
        let other = root.appendingPathComponent("Other.md")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "other".write(to: other, atomically: true, encoding: .utf8)
        try "taken".write(to: folder.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try FileService.move(source, into: folder, root: root)) { error in
            XCTAssertEqual(error as? FileServiceError, .nameTaken("Note.md"))
        }
        XCTAssertThrowsError(try FileService.move(source, into: outside, root: root)) { error in
            guard case .outsideRoot = error as? FileServiceError else {
                return XCTFail("Expected outsideRoot, got \(error)")
            }
        }
        XCTAssertThrowsError(try FileService.move(source, into: other, root: root))
        XCTAssertThrowsError(try FileService.move(source, into: root.appendingPathComponent("Missing"), root: root))
        XCTAssertThrowsError(try FileService.move(folder, into: root, root: root))
        XCTAssertEqual(try FileService.read(source), "source")
        XCTAssertEqual(try FileService.read(folder.appendingPathComponent("Note.md")), "taken")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testMoveRejectsASymlinkedNoteWithoutMovingItsTarget() throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Ideas")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("Target.md")
        let link = root.appendingPathComponent("Linked.md")
        try "target".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try FileService.move(link, into: folder, root: root))
        XCTAssertEqual(try FileService.read(target), "target")
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Linked.md").path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

@MainActor
final class FileMoveModelTests: XCTestCase {
    func testDraggingANoteOntoAFolderMovesItIntoThatFolder() async throws {
        let (model, root) = try await vaultModel()
        let source = root.appendingPathComponent("Loose.md")
        let folder = root.appendingPathComponent("Ideas")
        await model.openTab(path: source.path)
        model.draggedFilePath = source.path
        var targeted = false
        var expanded = false
        let delegate = FolderDropDelegate(
            model: model,
            folderPath: folder.path,
            targeted: Binding(get: { targeted }, set: { targeted = $0 }),
            onMove: { expanded = true }
        )

        XCTAssertTrue(delegate.updateTarget())
        XCTAssertTrue(targeted)
        let moved = try XCTUnwrap(delegate.drop())
        let succeeded = await moved.value

        let destination = FileService.canonicalURL(folder.appendingPathComponent("Loose.md")).path
        XCTAssertTrue(succeeded)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(targeted)
        XCTAssertTrue(expanded)
        XCTAssertNil(model.draggedFilePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try FileService.read(URL(fileURLWithPath: destination)), "loose")
        XCTAssertEqual(model.tabs.map { canonical($0.path) }, [destination])
        XCTAssertEqual(model.activeTabID.map(canonical), destination)
        XCTAssertEqual(model.tabs.first?.title, "Loose")
        let ideas = try XCTUnwrap(model.fileTree.first { $0.name == "Ideas" })
        XCTAssertEqual(ideas.children?.map(\.name), ["Existing.md", "Loose.md"])
        XCTAssertFalse(model.fileTree.contains { $0.name == "Loose.md" })
        XCTAssertTrue(model.notes.contains { $0.relativePath == "Ideas/Loose.md" })
    }

    func testDroppingANoteOnTheTreeBackgroundMovesItToTheVaultRoot() async throws {
        let (model, root) = try await vaultModel()
        let nested = root.appendingPathComponent("Ideas/Existing.md")
        model.draggedFilePath = nested.path
        var targeted = false
        let delegate = FolderDropDelegate(
            model: model,
            folderPath: root.path,
            targeted: Binding(get: { targeted }, set: { targeted = $0 })
        )

        let moved = try XCTUnwrap(delegate.drop())
        _ = await moved.value

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Existing.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
        XCTAssertTrue(model.fileTree.contains { $0.name == "Existing.md" })
    }

    func testAFolderRefusesANoteAlreadyInsideItOrOutsideTheVault() async throws {
        let (model, root) = try await vaultModel()
        let folder = root.appendingPathComponent("Ideas")
        let outsider = try temporaryDirectory().appendingPathComponent("Outsider.md")
        try "outsider".write(to: outsider, atomically: true, encoding: .utf8)
        var targeted = true
        let delegate = FolderDropDelegate(
            model: model,
            folderPath: folder.path,
            targeted: Binding(get: { targeted }, set: { targeted = $0 })
        )

        XCTAssertFalse(delegate.updateTarget(), "nothing is being dragged")
        XCTAssertFalse(targeted)

        model.draggedFilePath = folder.appendingPathComponent("Existing.md").path
        XCTAssertFalse(delegate.updateTarget())
        XCTAssertNil(delegate.drop())

        model.draggedFilePath = outsider.path
        XCTAssertFalse(delegate.updateTarget())
        XCTAssertNil(delegate.drop())
        XCTAssertFalse(model.canMoveNote(root.appendingPathComponent("Loose.md").path, toFolder: outsider.deletingLastPathComponent().path))

        XCTAssertTrue(FileManager.default.fileExists(atPath: outsider.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Existing.md").path))
        XCTAssertNil(model.errorMessage)
    }

    func testMovingAnEditedNoteSavesItsEditsFirst() async throws {
        let (model, root) = try await vaultModel()
        let source = root.appendingPathComponent("Loose.md")
        await model.openTab(path: source.path)
        model.updateContent(source.path, "edited")

        let moved = await model.moveNote(path: source.path, toFolder: root.appendingPathComponent("Ideas").path)

        let destination = root.appendingPathComponent("Ideas/Loose.md")
        XCTAssertTrue(moved)
        XCTAssertEqual(try FileService.read(destination), "edited")
        XCTAssertEqual(model.activeTab?.content, "edited")
        XCTAssertFalse(try XCTUnwrap(model.activeTab).dirty)
    }

    func testMoveOntoATakenNamePublishesAnErrorAndKeepsTheNote() async throws {
        let (model, root) = try await vaultModel()
        let source = root.appendingPathComponent("Existing.md")
        try "root copy".write(to: source, atomically: true, encoding: .utf8)
        await model.refreshVault()
        await model.openTab(path: source.path)

        let moved = await model.moveNote(path: source.path, toFolder: root.appendingPathComponent("Ideas").path)

        XCTAssertFalse(moved)
        XCTAssertEqual(model.errorMessage, FileServiceError.nameTaken("Existing.md").localizedDescription)
        XCTAssertEqual(model.activeTabID, source.path)
        XCTAssertEqual(try FileService.read(source), "root copy")
        XCTAssertEqual(try FileService.read(root.appendingPathComponent("Ideas/Existing.md")), "existing")
    }

    /// A vault holding `Loose.md` at its root and `Ideas/Existing.md` in a folder.
    private func vaultModel() async throws -> (AppModel, URL) {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Ideas")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "loose".write(to: root.appendingPathComponent("Loose.md"), atomically: true, encoding: .utf8)
        try "existing".write(to: folder.appendingPathComponent("Existing.md"), atomically: true, encoding: .utf8)
        var settings = AppSettings.default()
        settings.autoSync = false
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.refreshVault()
        return (model, root)
    }

    private func canonical(_ path: String) -> String {
        FileService.canonicalURL(URL(fileURLWithPath: path)).path
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

@MainActor
final class FileDragSourceTests: XCTestCase {
    func testNoteDragOffersOnlyThePrivateTypeThatNeitherEditorNorPanesAccept() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let editor = SourceTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        window.contentView?.addSubview(editor)
        editor.updateDragTypeRegistration()

        let offered = Set(FileDragSourceView.pasteboardItem(for: "/vault/Note.md").types)

        XCTAssertEqual(offered.map(\.rawValue), [UTType.vulkanGlassNote.identifier])
        XCTAssertFalse(editor.registeredDraggedTypes.isEmpty)
        XCTAssertTrue(offered.isDisjoint(with: editor.registeredDraggedTypes))
        XCTAssertFalse(offered.contains(NSPasteboard.PasteboardType(UTType.vulkanGlassNoteTab.identifier)))
    }

    func testEndingANoteDragClearsItWithoutErasingANewerOne() {
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        let source = FileDragSourceView()
        source.model = model
        source.path = "/vault/One.md"

        model.draggedFilePath = "/vault/One.md"
        source.endFileDrag()
        XCTAssertNil(model.draggedFilePath)

        model.draggedFilePath = "/vault/Two.md"
        source.endFileDrag()
        XCTAssertEqual(model.draggedFilePath, "/vault/Two.md")
    }

    func testClickingANoteRowWithoutDraggingOpensIt() throws {
        let (window, source) = hostedSource()
        defer { window.orderOut(nil) }
        var clicks = 0
        source.onClick = { clicks += 1 }

        source.mouseDown(with: try event(.leftMouseDown, in: window))
        source.mouseDragged(with: try event(.leftMouseDragged, in: window))
        source.mouseUp(with: try event(.leftMouseUp, in: window))
        XCTAssertEqual(clicks, 1, "a press that stays within the drag threshold is a click")
        source.mouseUp(with: try event(.leftMouseUp, in: window))
        XCTAssertEqual(clicks, 1, "a release without its own press does not open the note")
    }

    func testNoteRowContextMenuRunsItsItems() throws {
        let (window, source) = hostedSource()
        defer { window.orderOut(nil) }
        var chosen: [String] = []
        source.menuItems = [
            FileDragSourceView.MenuItem(title: "Rename") { chosen.append("Rename") },
            FileDragSourceView.MenuItem(title: "Move to Trash…") { chosen.append("Trash") },
        ]

        let menu = try XCTUnwrap(source.menu(for: try event(.rightMouseDown, in: window)))
        XCTAssertEqual(menu.items.map(\.title), ["Rename", "Move to Trash…"])
        for item in menu.items {
            let action = try XCTUnwrap(item.action)
            NSApp.sendAction(action, to: item.target, from: item)
        }
        XCTAssertEqual(chosen, ["Rename", "Trash"])

        source.menuItems = []
        XCTAssertNil(source.menu(for: try event(.rightMouseDown, in: window)))
    }

    private func hostedSource() -> (NSWindow, FileDragSourceView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 24),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let source = FileDragSourceView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView = source
        return (window, source)
    }

    private func event(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 50, y: 12),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
    }
}
