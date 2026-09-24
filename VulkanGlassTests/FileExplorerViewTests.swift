import AppKit
import SwiftUI
import XCTest
@testable import VulkanGlass

@MainActor
final class FileExplorerViewTests: XCTestCase {
    func testFolderContextMenuButtonCreatesNoteAndExpandsFolder() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        var open = false
        let binding = Binding(get: { open }, set: { open = $0 })
        let host = NSHostingView(rootView: FolderContextMenu(path: folder.path, open: binding).environment(model))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()

        let location = host.convert(NSPoint(x: 100, y: 20), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 0
            ))
            window.sendEvent(event)
        }

        let created = FileService.canonicalURL(folder.appendingPathComponent("Untitled.md"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline, model.activeTab == nil {
            await Task.yield()
        }
        XCTAssertTrue(open)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Untitled.md").path))
        XCTAssertEqual(model.activeTab?.path, created.path)
        XCTAssertEqual(model.titleEditingTabID, created.path)
    }

    func testVisibleRowsHideCollapsedFoldersAndArrowsStepOverFolders() {
        let tree = [
            FileNode(name: "Ideas", path: "/v/Ideas", isDirectory: true, children: [
                FileNode(name: "Deep", path: "/v/Ideas/Deep", isDirectory: true, children: [
                    FileNode(name: "C.md", path: "/v/Ideas/Deep/C.md", isDirectory: false),
                ]),
                FileNode(name: "B.md", path: "/v/Ideas/B.md", isDirectory: false),
            ]),
            FileNode(name: "A.md", path: "/v/A.md", isDirectory: false),
        ]

        let expanded = FileTreeState.visibleRows(tree, collapsed: [])
        XCTAssertEqual(expanded.map(\.id), ["/v/Ideas", "/v/Ideas/Deep", "/v/Ideas/Deep/C.md", "/v/Ideas/B.md", "/v/A.md"])
        XCTAssertEqual(expanded.map(\.depth), [0, 1, 2, 1, 0])
        XCTAssertEqual(FileTreeState.note(1, from: "/v/Ideas/Deep/C.md", in: expanded), "/v/Ideas/B.md")
        XCTAssertEqual(FileTreeState.note(1, from: "/v/Ideas/B.md", in: expanded), "/v/A.md")
        XCTAssertEqual(FileTreeState.note(-2, from: "/v/A.md", in: expanded), "/v/Ideas/Deep/C.md")
        XCTAssertNil(FileTreeState.note(-1, from: "/v/Ideas/Deep/C.md", in: expanded), "stops at the top")
        XCTAssertNil(FileTreeState.note(1, from: "/v/A.md", in: expanded), "stops at the bottom")
        XCTAssertNil(FileTreeState.note(1, from: "/v/Missing.md", in: expanded))

        let collapsed = FileTreeState.visibleRows(tree, collapsed: ["/v/Ideas/Deep"])
        XCTAssertEqual(collapsed.map(\.id), ["/v/Ideas", "/v/Ideas/Deep", "/v/Ideas/B.md", "/v/A.md"])
        XCTAssertNil(FileTreeState.note(-1, from: "/v/Ideas/B.md", in: collapsed), "hidden notes are skipped")
        XCTAssertEqual(FileTreeState.visibleRows(tree, collapsed: ["/v/Ideas"]).map(\.id), ["/v/Ideas", "/v/A.md"])
    }

    func testSelectionFollowsTheKeyboardThenFallsBackToTheActiveTab() {
        let state = FileTreeState()
        let rows = FileTreeState.visibleRows([
            FileNode(name: "A.md", path: "/v/A.md", isDirectory: false),
            FileNode(name: "B.md", path: "/v/B.md", isDirectory: false),
        ], collapsed: [])
        XCTAssertEqual(state.selection(activeTabID: "/v/A.md"), "/v/A.md")

        state.focusChanged("/v/A.md", focused: true)
        XCTAssertEqual(state.moveSelection(1, from: "/v/A.md", in: rows), "/v/B.md")
        XCTAssertEqual(state.focusRequestPath, "/v/B.md")
        XCTAssertEqual(state.selection(activeTabID: "/v/A.md"), "/v/B.md", "the selection moves before focus lands")
        XCTAssertNil(state.moveSelection(1, from: "/v/A.md", in: rows), "a repeated arrow starts at the pending row")
        XCTAssertNil(state.moveSelection(1, from: "/v/B.md", in: rows))
        XCTAssertEqual(state.focusRequestPath, "/v/B.md", "moving past the end keeps the selection")

        state.focusChanged("/v/A.md", focused: false)
        state.focusChanged("/v/B.md", focused: true)
        XCTAssertNil(state.focusRequestPath)
        XCTAssertEqual(state.focusedPath, "/v/B.md")
        XCTAssertEqual(state.selection(activeTabID: "/v/A.md"), "/v/B.md")

        state.focusChanged("/v/A.md", focused: false)
        XCTAssertEqual(state.focusedPath, "/v/B.md", "a stale resign does not clear the focused row")
        state.focusChanged("/v/B.md", focused: false)
        XCTAssertEqual(state.selection(activeTabID: "/v/A.md"), "/v/A.md")

        XCTAssertTrue(state.isOpen("/v/Ideas"))
        state.setOpen(false, folder: "/v/Ideas")
        XCTAssertFalse(state.isOpen("/v/Ideas"))
        state.setOpen(true, folder: "/v/Ideas")
        XCTAssertTrue(state.isOpen("/v/Ideas"))
    }

    func testPendingSelectionChainsAndRemovedRowsRecoverToAVisibleNote() {
        let state = FileTreeState()
        let rows = FileTreeState.visibleRows([
            FileNode(name: "A.md", path: "/v/A.md", isDirectory: false),
            FileNode(name: "Folder", path: "/v/Folder", isDirectory: true, children: [
                FileNode(name: "B.md", path: "/v/Folder/B.md", isDirectory: false),
            ]),
            FileNode(name: "C.md", path: "/v/C.md", isDirectory: false),
        ], collapsed: [])
        state.focusChanged("/v/A.md", focused: true)
        XCTAssertEqual(state.moveSelection(1, from: "/v/A.md", in: rows), "/v/Folder/B.md")
        XCTAssertEqual(state.moveSelection(1, from: "/v/A.md", in: rows), "/v/C.md")
        state.focusChanged("/v/Folder/B.md", focused: true)
        XCTAssertEqual(state.focusRequestPath, "/v/C.md", "a late focus callback must preserve the newer request")
        state.focusChanged("/v/C.md", focused: true)
        XCTAssertNil(state.focusRequestPath)

        state.focusChanged("/v/Folder/B.md", focused: true)
        state.setOpen(false, folder: "/v/Folder")
        state.reconcileVisibleRows(FileTreeState.visibleRows([
            FileNode(name: "A.md", path: "/v/A.md", isDirectory: false),
            FileNode(name: "Folder", path: "/v/Folder", isDirectory: true, children: [
                FileNode(name: "B.md", path: "/v/Folder/B.md", isDirectory: false),
            ]),
            FileNode(name: "C.md", path: "/v/C.md", isDirectory: false),
        ], collapsed: state.collapsedFolders), activeTabID: "/v/A.md")
        XCTAssertNil(state.focusedPath)
        XCTAssertEqual(state.focusRequestPath, "/v/A.md")
        state.focusChanged("/v/Folder/B.md", focused: false)
        XCTAssertEqual(state.selection(activeTabID: "/v/A.md"), "/v/A.md")

        state.reconcileVisibleRows([rows[3]], activeTabID: "/v/Folder/B.md")
        XCTAssertNil(state.focusedPath)
        XCTAssertEqual(state.focusRequestPath, "/v/C.md", "a removed pending row falls back to a visible note")
    }

    func testRemovingTheFocusedDragSourceReportsLostFocus() async {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let row = FileDragSourceView(frame: container.bounds)
        var focusChanges: [Bool] = []
        row.onFocusChange = { focusChanges.append($0) }
        container.addSubview(row)
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(row))
        row.removeFromSuperview()
        await drainMainQueue()
        XCTAssertEqual(focusChanges, [true, false])
    }

    func testClickingANoteKeepsFocusInTheTreeAndArrowKeysMoveTheSelection() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Ideas", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for (name, url) in [("A", root), ("B", folder), ("C", root)] {
            try name.write(to: url.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }
        var settings = AppSettings.default()
        settings.autoSync = false
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.refreshVault()
        model.editorMode = .source
        let notes = FileTreeState.visibleRows(model.fileTree, collapsed: [])
            .filter { !$0.node.isDirectory }
            .map(\.node.path)
        XCTAssertEqual(notes.count, 3)

        let host = NSHostingView(rootView: FileExplorerView().environment(model).frame(width: 260, height: 360))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 360)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        func settle() async {
            for _ in 0..<10 {
                host.layoutSubtreeIfNeeded()
                await Task.yield()
                await drainMainQueue()
            }
        }
        func row(_ path: String) throws -> FileDragSourceView {
            try XCTUnwrap(descendants(of: host).compactMap { $0 as? FileDragSourceView }.first { $0.path == path })
        }
        func focusedRow() -> String? {
            (window.firstResponder as? FileDragSourceView)?.path
        }
        func press(_ key: NSEvent.SpecialKey?, characters: String, keyCode: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ))
            if let key { XCTAssertEqual(event.specialKey, key) }
            window.sendEvent(event)
        }
        await settle()

        let first = try row(notes[0])
        let location = first.convert(NSPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )))
        }
        for _ in 0..<50 where model.activeTabID != notes[0] { await settle() }
        XCTAssertEqual(model.activeTabID, notes[0])
        XCTAssertNil(model.editorFocusRequest, "a click leaves keyboard focus in the tree")
        XCTAssertEqual(focusedRow(), notes[0])

        let arrowDown = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let arrowUp = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        try press(.downArrow, characters: arrowDown, keyCode: 125)
        try press(.downArrow, characters: arrowDown, keyCode: 125)
        for _ in 0..<50 where focusedRow() != notes[2] { await settle() }
        XCTAssertEqual(focusedRow(), notes[2], "rapid arrows advance twice before the focus handoff")
        try press(.downArrow, characters: arrowDown, keyCode: 125)
        XCTAssertEqual(focusedRow(), notes[2], "stops at the bottom")
        try press(.upArrow, characters: arrowUp, keyCode: 126)
        for _ in 0..<50 where focusedRow() != notes[1] { await settle() }
        XCTAssertEqual(focusedRow(), notes[1])
        XCTAssertEqual(model.activeTabID, notes[0], "moving the selection does not open notes")

        try press(.downArrow, characters: arrowDown, keyCode: 125)
        try press(nil, characters: " ", keyCode: 49)
        for _ in 0..<50 where model.activeTabID != notes[2] { await settle() }
        XCTAssertEqual(model.activeTabID, notes[2], "Space opens the pending selection")
        XCTAssertNil(model.editorFocusRequest)
        for _ in 0..<50 where focusedRow() != notes[2] { await settle() }
        XCTAssertEqual(focusedRow(), notes[2])

        try press(.upArrow, characters: arrowUp, keyCode: 126)
        try press(.carriageReturn, characters: "\r", keyCode: 36)
        for _ in 0..<50 where model.activeTabID != notes[1] { await settle() }
        XCTAssertEqual(model.activeTabID, notes[1])
        XCTAssertEqual(model.editorFocusRequest?.tabID, notes[1], "Return takes the note into the editor")
    }

    func testCollapsingTheFocusedFolderRestoresFocusToTheActiveVisibleNote() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let first = root.appendingPathComponent("A.md")
        let hidden = folder.appendingPathComponent("B.md")
        let last = root.appendingPathComponent("C.md")
        let firstPath = FileService.canonicalURL(first).path
        let hiddenPath = FileService.canonicalURL(hidden).path
        let lastPath = FileService.canonicalURL(last).path
        let folderPath = FileService.canonicalURL(folder).path
        for note in [first, hidden, last] {
            try "note".write(to: note, atomically: true, encoding: .utf8)
        }
        var settings = AppSettings.default()
        settings.autoSync = false
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.refreshVault()
        await model.openTab(path: first.path, focusEditor: false)
        let tree = FileTreeState()
        let host = NSHostingView(rootView: FileExplorerView(tree: tree).environment(model).frame(width: 260, height: 360))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 360)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); await drainMainQueue() }
        let renderedRows = descendants(of: host).compactMap { $0 as? FileDragSourceView }
        let hiddenRow = try XCTUnwrap(renderedRows.first { $0.path == hiddenPath })
        XCTAssertTrue(window.makeFirstResponder(hiddenRow))
        XCTAssertEqual(tree.focusedPath, hiddenPath)

        tree.setOpen(false, folder: folderPath)
        for _ in 0..<50 where (window.firstResponder as? FileDragSourceView)?.path != firstPath {
            host.layoutSubtreeIfNeeded()
            await drainMainQueue()
        }
        XCTAssertNotEqual(tree.focusedPath, hiddenPath)
        XCTAssertEqual(tree.selection(activeTabID: model.activeTabID), firstPath)
        XCTAssertEqual((window.firstResponder as? FileDragSourceView)?.path, firstPath)

        let arrowDown = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: arrowDown,
            charactersIgnoringModifiers: arrowDown, isARepeat: false, keyCode: 125
        ))
        window.sendEvent(event)
        for _ in 0..<50 where (window.firstResponder as? FileDragSourceView)?.path != lastPath {
            host.layoutSubtreeIfNeeded()
            await drainMainQueue()
        }
        XCTAssertEqual((window.firstResponder as? FileDragSourceView)?.path, lastPath)
    }

    func testRapidArrowsScrollToAndFocusAnInitiallyOffscreenNote() async throws {
        let root = try temporaryDirectory()
        for index in 0..<24 {
            try "note".write(
                to: root.appendingPathComponent(String(format: "%02d.md", index)),
                atomically: true, encoding: .utf8
            )
        }
        var settings = AppSettings.default()
        settings.autoSync = false
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.refreshVault()
        let notes = FileTreeState.visibleRows(model.fileTree, collapsed: []).map(\.node.path)
        XCTAssertEqual(notes.count, 24)
        let host = NSHostingView(rootView: FileExplorerView().environment(model).frame(width: 240, height: 100))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); await drainMainQueue() }
        let rows = descendants(of: host).compactMap { $0 as? FileDragSourceView }
        let first = try XCTUnwrap(rows.first { $0.path == notes[0] })
        XCTAssertFalse(rows.contains { $0.path == notes[23] }, "the destination starts outside the lazy viewport")
        XCTAssertTrue(window.makeFirstResponder(first))
        let arrowDown = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: arrowDown,
            charactersIgnoringModifiers: arrowDown, isARepeat: true, keyCode: 125
        ))
        for _ in 1..<notes.count { window.sendEvent(event) }
        for _ in 0..<100 where (window.firstResponder as? FileDragSourceView)?.path != notes[23] {
            host.layoutSubtreeIfNeeded()
            await drainMainQueue()
        }
        XCTAssertEqual((window.firstResponder as? FileDragSourceView)?.path, notes[23])
    }

    func testOpeningATabWithoutEditorFocusLeavesFocusAlone() async throws {
        let root = try temporaryDirectory()
        let note = root.appendingPathComponent("Note.md")
        try "note".write(to: note, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.editorMode = .source

        await model.openTab(path: note.path, focusEditor: false)
        XCTAssertEqual(model.activeTab?.path, note.path)
        XCTAssertNil(model.editorFocusRequest)
        await model.openTab(path: note.path, focusEditor: false)
        XCTAssertNil(model.editorFocusRequest)
        await model.openTab(path: note.path)
        XCTAssertEqual(model.editorFocusRequest?.tabID, note.path)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
