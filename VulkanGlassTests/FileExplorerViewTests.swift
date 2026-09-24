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

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
