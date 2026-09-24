import AppKit
import SwiftUI
import XCTest
@testable import VulkanGlass

@MainActor
final class TitleBarDoubleClickTests: XCTestCase {
    func testActionFollowsTheSystemTitleBarDoubleClickSetting() throws {
        XCTAssertEqual(TitleBarDoubleClickAction(preference: "Maximize"), .zoom)
        XCTAssertEqual(TitleBarDoubleClickAction(preference: "Fill"), .zoom)
        XCTAssertEqual(TitleBarDoubleClickAction(preference: "Minimize"), .minimize)
        XCTAssertEqual(TitleBarDoubleClickAction(preference: "None"), .none)
        XCTAssertEqual(TitleBarDoubleClickAction(preference: nil), .zoom)
        XCTAssertEqual(TitleBarDoubleClickAction(preference: nil, legacyMinimize: true), .minimize)
        XCTAssertEqual(TitleBarDoubleClickAction(preference: "Maximize", legacyMinimize: true), .zoom)

        let suite = "VulkanGlassTitleBarDoubleClick-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        defaults.set("Minimize", forKey: "AppleActionOnDoubleClick")
        XCTAssertEqual(TitleBarDoubleClickAction.current(defaults: defaults), .minimize)
    }

    func testOnlyEmptyTabStripSpaceCountsAsEmptyTitleBar() async throws {
        let model = try modelWithTabs()
        let host = NSHostingView(rootView: TabGroupsView().environment(model))
        let window = try await hostedWindow(host)
        defer { window.orderOut(nil) }

        let tabs = descendants(of: host).compactMap { $0 as? TabDragSourceView }
        XCTAssertEqual(tabs.count, 2)
        let lastTab = try XCTUnwrap(tabs.map { $0.convert($0.bounds, to: nil) }.max { $0.maxX < $1.maxX })
        let midY = lastTab.midY

        for tab in tabs {
            let frame = tab.convert(tab.bounds, to: nil)
            XCTAssertFalse(
                TitleBarDoubleClick.isEmptyTitleBarSpace(at: NSPoint(x: frame.midX, y: midY), in: window),
                "a tab is not empty title bar"
            )
        }
        XCTAssertTrue(
            TitleBarDoubleClick.isEmptyTitleBarSpace(at: NSPoint(x: lastTab.maxX + 60, y: midY), in: window),
            "space past the last tab is empty title bar"
        )
        let editButtonX = host.bounds.width - VGTheme.paneDividerInset - VGTheme.titleBarIconSize / 2
        XCTAssertFalse(
            TitleBarDoubleClick.isEmptyTitleBarSpace(at: NSPoint(x: editButtonX, y: midY), in: window),
            "a title-bar button is not empty title bar"
        )
        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let closeFrame = closeButton.convert(closeButton.bounds, to: nil)
        XCTAssertFalse(
            TitleBarDoubleClick.isEmptyTitleBarSpace(at: NSPoint(x: closeFrame.midX, y: closeFrame.midY), in: window),
            "the traffic lights are not empty title bar"
        )
        XCTAssertFalse(
            TitleBarDoubleClick.isEmptyTitleBarSpace(at: NSPoint(x: host.bounds.midX, y: 100), in: window),
            "the editor below the title bar is not title bar"
        )
    }

    func testWelcomeScreenTitleBarCountsAsEmpty() async throws {
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        let host = NSHostingView(rootView: WelcomeView().environment(model).ignoresSafeArea(.container, edges: .top))
        let window = try await hostedWindow(host)
        defer { window.orderOut(nil) }

        let top = window.frame.height - VGTheme.titleBarHeight / 2
        XCTAssertTrue(TitleBarDoubleClick.isEmptyTitleBarSpace(at: NSPoint(x: host.bounds.midX, y: top), in: window))
    }

    func testDoubleClickOnEmptyTitleBarPerformsTheActionAndSingleClicksPassThrough() async throws {
        let model = try modelWithTabs()
        let host = NSHostingView(rootView: TabGroupsView().environment(model))
        let window = try await hostedWindow(host)
        defer { window.orderOut(nil) }

        let tab = try XCTUnwrap(descendants(of: host).compactMap { $0 as? TabDragSourceView }.first)
        let tabFrame = tab.convert(tab.bounds, to: nil)
        let empty = NSPoint(x: tabFrame.maxX + 300, y: tabFrame.midY)
        let onTab = NSPoint(x: tabFrame.midX, y: tabFrame.midY)
        let originalFrame = window.frame

        XCTAssertFalse(TitleBarDoubleClick.handle(try click(at: empty, count: 1, in: window), in: window, action: .none))
        XCTAssertFalse(TitleBarDoubleClick.handle(try click(at: onTab, count: 2, in: window), in: window, action: .none))
        XCTAssertTrue(TitleBarDoubleClick.handle(try click(at: empty, count: 2, in: window), in: window, action: .none))
        XCTAssertEqual(window.frame, originalFrame)

        XCTAssertFalse(window.isZoomed)
        XCTAssertTrue(TitleBarDoubleClick.handle(try click(at: empty, count: 2, in: window), in: window, action: .zoom))
        XCTAssertTrue(window.isZoomed, "a double-click expands the window to fill the screen")
        XCTAssertNotEqual(window.frame, originalFrame)
        TitleBarDoubleClick.perform(.zoom, on: window)
        XCTAssertFalse(window.isZoomed, "a second double-click restores it")
        XCTAssertEqual(window.frame, originalFrame)
    }

    private func click(at point: NSPoint, count: Int, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: count,
            pressure: 1
        ))
    }

    private func hostedWindow(_ host: NSView) async throws -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 900, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        return window
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func modelWithTabs() throws -> AppModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VulkanGlassTitleBar-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.tabs = try ["One", "Two"].map { title in
            let url = root.appendingPathComponent("\(title).md")
            try title.write(to: url, atomically: true, encoding: .utf8)
            return NoteTab(path: url.path, title: title, content: title, originalContent: title, isStandalone: true)
        }
        return model
    }
}
