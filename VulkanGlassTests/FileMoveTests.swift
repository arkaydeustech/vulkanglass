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

    func testMoveResolvesASymlinkedDestinationInsideTheVault() throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Ideas")
        let link = root.appendingPathComponent("Ideas Link")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let source = root.appendingPathComponent("Note.md")
        try "note".write(to: source, atomically: true, encoding: .utf8)

        let destination = try FileService.move(source, into: link, root: root)

        XCTAssertEqual(destination.path, FileService.canonicalURL(folder.appendingPathComponent("Note.md")).path)
        XCTAssertEqual(try FileService.read(destination), "note")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testMoveRejectsASymlinkedDestinationOutsideTheVault() throws {
        let parent = try temporaryDirectory()
        let root = parent.appendingPathComponent("vault")
        let outside = parent.appendingPathComponent("outside")
        let link = root.appendingPathComponent("Outside Link")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let source = root.appendingPathComponent("Note.md")
        try "note".write(to: source, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try FileService.move(source, into: link, root: root)) { error in
            guard case .outsideRoot = error as? FileServiceError else {
                return XCTFail("Expected outsideRoot, got \(error)")
            }
        }
        XCTAssertEqual(try FileService.read(source), "note")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Note.md").path))
    }

    func testMoveReportsAMissingSourceAsMissingFile() throws {
        let root = try temporaryDirectory()
        let missing = root.appendingPathComponent("Gone.md")

        XCTAssertThrowsError(try FileService.move(missing, into: root, root: root)) { error in
            XCTAssertEqual(error as? FileServiceError, .missingFile("Gone.md"))
        }
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

    func testMoveStopsWhenThePreMoveSaveFails() async throws {
        let (model, root) = try await vaultModel()
        let source = root.appendingPathComponent("Broken.md")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        model.tabs = [NoteTab(path: source.path, title: "Broken", content: "new", originalContent: "old", isStandalone: false)]

        let moved = await model.moveNote(path: source.path, toFolder: root.appendingPathComponent("Ideas").path)

        XCTAssertFalse(moved)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.tabs[0].dirty)
        XCTAssertEqual(model.tabs[0].path, source.path)
        XCTAssertTrue(FileService.directoryExists(at: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Ideas/Broken.md").path))
    }

    func testEditsDuringPendingMoveAreSavedOnlyAtTheDestination() async throws {
        let started = expectation(description: "Move started")
        let gate = FileMoveGate()
        var dependencies = AppModelDependencies.live
        dependencies.moveFile = { source, folder, root in
            started.fulfill()
            await gate.wait()
            return try FileService.move(source, into: folder, root: root)
        }
        let (model, root) = try await vaultModel(dependencies: dependencies)
        let source = root.appendingPathComponent("Loose.md")
        let destination = root.appendingPathComponent("Ideas/Loose.md")
        await model.openTab(path: source.path)
        model.updateContent(source.path, "before move")

        let move = Task { await model.moveNote(path: source.path, toFolder: destination.deletingLastPathComponent().path) }
        await fulfillment(of: [started], timeout: 2)
        model.updateContent(source.path, "first edit")
        model.updateContent(source.path, "latest edit")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try FileService.read(source), "before move")
        gate.release()
        let moved = await move.value
        XCTAssertTrue(moved)

        await model.awaitPendingSaves()
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try FileService.read(destination), "latest edit")
        XCTAssertEqual(model.activeTab.map { canonical($0.path) }, canonical(destination.path))
        XCTAssertFalse(try XCTUnwrap(model.activeTab).dirty)
    }

    func testEditsDuringAFailedMoveStayAtTheSource() async throws {
        let started = expectation(description: "Move started")
        let gate = FileMoveGate()
        var dependencies = AppModelDependencies.live
        dependencies.moveFile = { _, _, _ in
            started.fulfill()
            await gate.wait()
            throw FileServiceError.nameTaken("Loose.md")
        }
        let (model, root) = try await vaultModel(dependencies: dependencies)
        let source = root.appendingPathComponent("Loose.md")
        let folder = root.appendingPathComponent("Ideas")
        await model.openTab(path: source.path)

        let move = Task { await model.moveNote(path: source.path, toFolder: folder.path) }
        await fulfillment(of: [started], timeout: 2)
        model.updateContent(source.path, "edit during move")
        gate.release()
        let moved = await move.value

        XCTAssertFalse(moved)
        XCTAssertEqual(model.errorMessage, FileServiceError.nameTaken("Loose.md").localizedDescription)
        XCTAssertEqual(try FileService.read(source), "edit during move")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Loose.md").path))
        XCTAssertFalse(try XCTUnwrap(model.activeTab).dirty)
        XCTAssertTrue(model.canMoveNote(source.path, toFolder: folder.path))
    }

    func testCompletedMoveDoesNotSyncAReplacedVault() async throws {
        let started = expectation(description: "Move started")
        let gate = FileMoveGate()
        var dependencies = AppModelDependencies.live
        dependencies.authenticationDisabled = { false }
        dependencies.moveFile = { source, folder, root in
            started.fulfill()
            await gate.wait()
            return try FileService.move(source, into: folder, root: root)
        }
        var syncPaths: [String] = []
        dependencies.syncGit = { path, _, _ in
            syncPaths.append(path)
            return GitStatus(state: .synced)
        }
        var settings = AppSettings.default()
        settings.autoSync = true
        let (model, root) = try await vaultModel(settings: settings, dependencies: dependencies)
        let otherRoot = try temporaryDirectory()
        let other = VaultInfo(name: "other", path: otherRoot.path, remote: nil, branch: nil, isGitHub: false)
        let source = root.appendingPathComponent("Loose.md")
        let move = Task { await model.moveNote(path: source.path, toFolder: root.appendingPathComponent("Ideas").path) }
        await fulfillment(of: [started], timeout: 2)

        // Exercise the post-await identity guard even if a caller replaces vault directly.
        model.vault = other
        model.fileTree = []
        model.notes = []
        gate.release()
        let moved = await move.value

        XCTAssertTrue(moved)
        XCTAssertTrue(syncPaths.isEmpty)
        XCTAssertEqual(model.vault, other)
        XCTAssertTrue(model.fileTree.isEmpty)
        XCTAssertTrue(model.notes.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Ideas/Loose.md").path))
    }

    func testVaultSwitchWaitsForPendingMoveAndSyncsOnlyTheOriginalVault() async throws {
        let started = expectation(description: "Move started")
        let gate = FileMoveGate()
        var dependencies = AppModelDependencies.live
        dependencies.authenticationDisabled = { false }
        dependencies.moveFile = { source, folder, root in
            started.fulfill()
            await gate.wait()
            return try FileService.move(source, into: folder, root: root)
        }
        var syncPaths: [String] = []
        dependencies.syncGit = { path, _, _ in
            syncPaths.append(path)
            return GitStatus(state: .synced)
        }
        var settings = AppSettings.default()
        settings.autoSync = true
        let (model, root) = try await vaultModel(settings: settings, dependencies: dependencies)
        let otherRoot = try temporaryDirectory()
        try "other".write(to: otherRoot.appendingPathComponent("Other.md"), atomically: true, encoding: .utf8)
        let other = VaultInfo(name: "other", path: otherRoot.path, remote: nil, branch: nil, isGitHub: false)
        let source = root.appendingPathComponent("Loose.md")

        let move = Task { await model.moveNote(path: source.path, toFolder: root.appendingPathComponent("Ideas").path) }
        await fulfillment(of: [started], timeout: 2)
        let switching = Task { await model.openVault(other) }
        await Task.yield()
        XCTAssertEqual(model.vault?.path, root.path)
        XCTAssertTrue(syncPaths.isEmpty)
        gate.release()
        let moved = await move.value
        XCTAssertTrue(moved)
        await switching.value

        XCTAssertEqual(model.vault?.path, otherRoot.path)
        XCTAssertEqual(syncPaths, [root.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Ideas/Loose.md").path))
        XCTAssertFalse(model.notes.contains { $0.relativePath == "Ideas/Loose.md" })
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

    func testMovingANoteRetargetsAnExistingRecentFile() async throws {
        let (model, root) = try await vaultModel()
        let source = root.appendingPathComponent("Loose.md")
        model.settings.recentFiles = [RecentFile(name: "Loose", path: source.path, lastOpened: 42)]

        let moved = await model.moveNote(path: source.path, toFolder: root.appendingPathComponent("Ideas").path)
        XCTAssertTrue(moved)

        let recent = try XCTUnwrap(model.settings.recentFiles.first)
        XCTAssertEqual(recent.path, canonical(root.appendingPathComponent("Ideas/Loose.md").path))
        XCTAssertEqual(recent.name, "Loose")
        XCTAssertEqual(recent.lastOpened, 42)
    }

    func testAutoSyncUsesFolderAndVaultNamesForMoves() async throws {
        var settings = AppSettings.default()
        settings.autoSync = true
        var dependencies = AppModelDependencies.live
        dependencies.authenticationDisabled = { false }
        var messages: [String] = []
        dependencies.syncGit = { _, message, _ in
            messages.append(message)
            return GitStatus(state: .synced)
        }
        let (model, root) = try await vaultModel(settings: settings, dependencies: dependencies)

        let movedToFolder = await model.moveNote(
            path: root.appendingPathComponent("Loose.md").path,
            toFolder: root.appendingPathComponent("Ideas").path
        )
        let movedToRoot = await model.moveNote(
            path: root.appendingPathComponent("Ideas/Existing.md").path,
            toFolder: root.path
        )

        XCTAssertTrue(movedToFolder)
        XCTAssertTrue(movedToRoot)
        XCTAssertEqual(messages, ["Move Loose to Ideas", "Move Existing to vault"])
    }

    func testMoveIntoNestedFolderAndRootCollision() async throws {
        let (model, root) = try await vaultModel()
        let nested = root.appendingPathComponent("Ideas/Plans")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        await model.refreshVault()

        let moved = await model.moveNote(
            path: root.appendingPathComponent("Loose.md").path,
            toFolder: nested.path
        )
        XCTAssertTrue(moved)
        XCTAssertEqual(try FileService.read(nested.appendingPathComponent("Loose.md")), "loose")
        XCTAssertTrue(model.notes.contains { $0.relativePath == "Ideas/Plans/Loose.md" })

        let rootCopy = root.appendingPathComponent("Existing.md")
        try "root copy".write(to: rootCopy, atomically: true, encoding: .utf8)
        let collided = await model.moveNote(
            path: root.appendingPathComponent("Ideas/Existing.md").path,
            toFolder: root.path
        )
        XCTAssertFalse(collided)
        XCTAssertEqual(model.errorMessage, FileServiceError.nameTaken("Existing.md").localizedDescription)
        XCTAssertEqual(try FileService.read(rootCopy), "root copy")
        XCTAssertEqual(try FileService.read(root.appendingPathComponent("Ideas/Existing.md")), "existing")
    }

    func testStandaloneModelCannotMoveANote() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Loose.md")
        try "loose".write(to: source, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)

        XCTAssertFalse(model.canMoveNote(source.path, toFolder: root.path))
        let moved = await model.moveNote(path: source.path, toFolder: root.path)
        XCTAssertFalse(moved)
        XCTAssertEqual(try FileService.read(source), "loose")
    }

    func testNativeExplorerDragRoutesFolderOwnRowRootHeaderAndBackground() async throws {
        for target in ["folder", "own row", "header", "background"] {
            let (model, root) = try await vaultModel()
            let host = NSHostingView(rootView: FileExplorerView().environment(model).frame(width: 260, height: 360))
            host.frame = NSRect(x: 0, y: 0, width: 260, height: 360)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            defer { window.orderOut(nil) }
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            let sourcePath = target == "folder"
                ? root.appendingPathComponent("Loose.md").path
                : root.appendingPathComponent("Ideas/Existing.md").path
            let source = try XCTUnwrap(descendants(of: host).compactMap { $0 as? FileDragSourceView }
                .first { canonical($0.path) == canonical(sourcePath) })
            let nestedSource = try XCTUnwrap(descendants(of: host).compactMap { $0 as? FileDragSourceView }
                .first { $0.path.hasSuffix("/Ideas/Existing.md") })
            let nestedFrame = nestedSource.convert(nestedSource.bounds, to: host)
            let start = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
            let targetInHost: NSPoint
            switch target {
            case "folder":
                targetInHost = NSPoint(x: nestedFrame.midX, y: nestedFrame.minY - 11)
            case "own row":
                targetInHost = NSPoint(x: nestedFrame.midX + 15, y: nestedFrame.midY)
            case "header":
                targetInHost = NSPoint(x: nestedFrame.midX, y: host.bounds.maxY - 40)
            default:
                targetInHost = NSPoint(x: nestedFrame.midX, y: 250)
            }
            let end = host.convert(targetInHost, to: nil)

            func event(_ type: NSEvent.EventType, at point: NSPoint, timestamp: TimeInterval) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(
                    with: type,
                    location: point,
                    modifierFlags: [],
                    timestamp: timestamp,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: Int(timestamp * 100),
                    clickCount: 1,
                    pressure: 1
                ))
            }
            let down = try event(.leftMouseDown, at: start, timestamp: 1)
            let begin = try event(.leftMouseDragged, at: NSPoint(x: start.x + 10, y: start.y), timestamp: 1.1)
            let travel = try event(.leftMouseDragged, at: end, timestamp: 1.2)
            let up = try event(.leftMouseUp, at: end, timestamp: 1.3)
            source.mouseDown(with: down)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NSApp.postEvent(travel, atStart: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.postEvent(up, atStart: false) }
            source.mouseDragged(with: begin)
            let destination = target == "folder"
                ? root.appendingPathComponent("Ideas/Loose.md")
                : root.appendingPathComponent("Existing.md")
            let shouldMove = target != "own row"
            let deadline = ContinuousClock().now.advanced(by: .seconds(2))
            while shouldMove && ContinuousClock().now < deadline,
                  !FileManager.default.fileExists(atPath: destination.path)
            {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            // AppKit finishes the session (or animates a refused drag back) after the drop;
            // a scenario that starts dragging before then never reaches a drop target.
            let sessionDeadline = ContinuousClock().now.advanced(by: .seconds(3))
            while ContinuousClock().now < sessionDeadline, source.isDragSessionActive {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(source.isDragSessionActive, target)
            XCTAssertEqual(FileManager.default.fileExists(atPath: destination.path), shouldMove, target)
            XCTAssertEqual(FileManager.default.fileExists(atPath: sourcePath), !shouldMove, target)
            XCTAssertNil(model.errorMessage, target)
            XCTAssertNil(model.draggedFilePath, target)
        }
    }

    func testRootDropAreaFillsViewportBelowMeasuredRows() {
        var measuredRows = FileTreeRowsHeightKey.defaultValue
        FileTreeRowsHeightKey.reduce(value: &measuredRows) { 96 }
        FileTreeRowsHeightKey.reduce(value: &measuredRows) { 80 }

        XCTAssertEqual(measuredRows, 96)
        XCTAssertEqual(FileExplorerView.rootDropAreaHeight(viewportHeight: 360, rowsHeight: measuredRows), 264)
        XCTAssertEqual(FileExplorerView.rootDropAreaHeight(viewportHeight: 80, rowsHeight: measuredRows), 12)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    /// A vault holding `Loose.md` at its root and `Ideas/Existing.md` in a folder.
    private func vaultModel(
        settings suppliedSettings: AppSettings? = nil,
        dependencies: AppModelDependencies = .live
    ) async throws -> (AppModel, URL) {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Ideas")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "loose".write(to: root.appendingPathComponent("Loose.md"), atomically: true, encoding: .utf8)
        try "existing".write(to: folder.appendingPathComponent("Existing.md"), atomically: true, encoding: .utf8)
        var settings = suppliedSettings ?? AppSettings.default()
        if suppliedSettings == nil { settings.autoSync = false }
        let model = AppModel(settings: settings, bootstrapOnLaunch: false, dependencies: dependencies)
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

    func testControlClickPresentsMenuWithoutOpeningTheNote() throws {
        let (window, source) = hostedSource()
        defer { window.orderOut(nil) }
        var clicks = 0
        var presented: [String] = []
        source.onClick = { clicks += 1 }
        source.menuItems = [FileDragSourceView.MenuItem(title: "Rename") {}]
        source.presentContextMenu = { menu, _, _ in presented = menu.items.map(\.title) }
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 50, y: 12),
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        source.mouseDown(with: down)
        source.mouseUp(with: try event(.leftMouseUp, in: window))

        XCTAssertEqual(presented, ["Rename"])
        XCTAssertEqual(clicks, 0)
    }

    func testRightClickPresentsMenuWithoutOpeningTheNote() throws {
        let (window, source) = hostedSource()
        defer { window.orderOut(nil) }
        var clicks = 0
        var presented: [String] = []
        source.onClick = { clicks += 1 }
        source.menuItems = [FileDragSourceView.MenuItem(title: "Rename") {}]
        source.presentContextMenu = { menu, _, _ in presented = menu.items.map(\.title) }

        source.rightMouseDown(with: try event(.rightMouseDown, in: window))

        XCTAssertEqual(presented, ["Rename"])
        XCTAssertEqual(clicks, 0)
    }

    func testKeyboardAndAccessibilityActionsOpenRenameAndTrash() throws {
        let (window, source) = hostedSource()
        defer { window.orderOut(nil) }
        source.path = "/vault/Note.md"
        var invoked: [String] = []
        source.onClick = { invoked.append("Open") }
        source.menuItems = [
            FileDragSourceView.MenuItem(title: "Rename") { invoked.append("Rename") },
            FileDragSourceView.MenuItem(title: "Move to Trash…") { invoked.append("Trash") },
        ]
        let enter = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))

        XCTAssertTrue(source.acceptsFirstResponder)
        source.keyDown(with: enter)
        XCTAssertEqual(source.accessibilityRole(), .button)
        XCTAssertEqual(source.accessibilityLabel(), "Note.md")
        XCTAssertTrue(source.accessibilityPerformPress())
        let actions = try XCTUnwrap(source.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["Rename", "Move to Trash…"])
        XCTAssertTrue(actions.allSatisfy { $0.handler?() == true })
        XCTAssertEqual(invoked, ["Open", "Open", "Rename", "Trash"])
    }

    func testArrowKeysMoveTheSelectionAndReturnActivatesTheNote() throws {
        let (window, source) = hostedSource()
        defer { window.orderOut(nil) }
        var invoked: [String] = []
        source.onClick = { invoked.append("Open") }
        source.onActivate = { invoked.append("Edit") }
        source.onMoveSelection = { invoked.append("Move \($0)") }
        func key(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ))
        }
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

        source.keyDown(with: try key(down, 125, [.function, .numericPad]))
        source.keyDown(with: try key(up, 126, [.function, .numericPad]))
        source.keyDown(with: try key(down, 125, [.function, .numericPad, .command]))
        source.keyDown(with: try key("\r", 36))
        source.keyDown(with: try key(" ", 49))
        XCTAssertEqual(invoked, ["Move 1", "Move -1", "Edit", "Open"])
    }

    func testRowFocusIsReportedAndTakenOnRequest() async throws {
        let (window, source) = hostedSource()
        defer { window.orderOut(nil) }
        let other = FileDragSourceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        source.addSubview(other)
        var changes: [Bool] = []
        source.onFocusChange = { changes.append($0) }

        source.focusRequested = true
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(window.firstResponder === source)
        window.makeFirstResponder(other)
        XCTAssertEqual(changes, [true, false])
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

@MainActor
private final class FileMoveGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
