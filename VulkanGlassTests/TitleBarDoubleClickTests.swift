import AppKit
import SwiftUI
import XCTest
@testable import VulkanGlass

@MainActor
final class TitleBarDoubleClickTests: XCTestCase {
    func testActionFollowsTheSystemTitleBarDoubleClickSetting() throws {
        XCTAssertEqual(TitleBarDoubleClickAction(preference: "Maximize"), .zoom)
        XCTAssertEqual(TitleBarDoubleClickAction(preference: "Fill"), .fill)
        XCTAssertEqual(TitleBarDoubleClickAction(preference: "Zoom"), .zoom)
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

    func testWorkspaceSidebarAndRibbonHeadersHaveEmptyTitleBarSpace() async throws {
        let model = try modelWithTabs()
        model.leftOpen = true
        model.rightOpen = true
        let host = NSHostingView(rootView: WorkspaceView().environment(model).ignoresSafeArea(.container, edges: .top))
        let window = try await hostedWindow(host)
        defer { window.orderOut(nil) }

        let y = window.frame.height - VGTheme.titleBarHeight / 2
        let leftEnd = VGTheme.ribbonWidth + model.settings.leftSidebarWidth
        let rightStart = host.bounds.width - model.settings.rightSidebarWidth
        for (name, range) in [
            ("ribbon", 0..<Int(VGTheme.ribbonWidth)),
            ("left sidebar", Int(VGTheme.ribbonWidth)..<Int(leftEnd)),
            ("right sidebar", Int(rightStart)..<Int(host.bounds.width)),
        ] {
            let emptyPoint = stride(from: range.lowerBound, to: range.upperBound, by: 2)
                .map { NSPoint(x: CGFloat($0) + 1, y: y) }
                .first { TitleBarDoubleClick.isEmptyTitleBarSpace(at: $0, in: window) }
            XCTAssertNotNil(emptyPoint, "\(name) header has an exposed drag region")
        }
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
        XCTAssertTrue(window.isZoomed, "a double-click uses AppKit's zoom action")
        XCTAssertNotEqual(window.frame, originalFrame)
        TitleBarDoubleClick.perform(.zoom, on: window)
        XCTAssertFalse(window.isZoomed, "a second double-click restores it")
        XCTAssertEqual(window.frame, originalFrame)
    }

    func testFillUsesTheVisibleScreenFrameAndRestoresThePreviousFrame() async throws {
        let host = NSHostingView(rootView: WelcomeView().environment(AppModel(settings: .default(), bootstrapOnLaunch: false)))
        let window = try await hostedWindow(host)
        defer { window.orderOut(nil) }
        let originalFrame = window.frame
        let visibleFrame = try XCTUnwrap(window.screen?.visibleFrame)

        TitleBarDoubleClick.perform(.fill, on: window)
        XCTAssertEqual(window.frame, visibleFrame)
        TitleBarDoubleClick.perform(.fill, on: window)
        XCTAssertEqual(window.frame, originalFrame)
    }

    func testMinimizeActionReachesTheWindow() async throws {
        let host = NSHostingView(rootView: WelcomeView().environment(AppModel(settings: .default(), bootstrapOnLaunch: false)))
        let window = RecordingWindow(
            contentRect: NSRect(x: 80, y: 80, width: 900, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        let region = try XCTUnwrap(descendants(of: host).compactMap { $0 as? WindowDragRegionView }.first)
        let frame = region.convert(region.bounds, to: nil)
        let event = try click(at: NSPoint(x: frame.midX, y: frame.midY), count: 2, in: window)
        XCTAssertTrue(TitleBarDoubleClick.handle(event, in: window, action: .minimize))
        XCTAssertTrue(window.didMiniaturize)
    }

    func testChromeMonitorInterceptsDoubleClickAndTearsDownOnReattachment() async throws {
        let model = try modelWithTabs()
        let host = NSHostingView(rootView: TabGroupsView().environment(model))
        let window = try await hostedWindow(host)
        defer { window.orderOut(nil) }
        let chrome = WindowChromeView(frame: .zero)
        chrome.doubleClickAction = { .fill }
        host.addSubview(chrome)
        XCTAssertTrue(chrome.isMonitoringDoubleClicks)
        chrome.viewDidMoveToWindow()
        XCTAssertTrue(chrome.isMonitoringDoubleClicks)

        let tab = try XCTUnwrap(descendants(of: host).compactMap { $0 as? TabDragSourceView }.first)
        let tabFrame = tab.convert(tab.bounds, to: nil)
        let empty = NSPoint(x: tabFrame.maxX + 300, y: tabFrame.midY)
        let originalFrame = window.frame
        let visibleFrame = try XCTUnwrap(window.screen?.visibleFrame)
        let event = try click(at: empty, count: 2, in: window)
        sendThroughApp(event)
        XCTAssertEqual(window.frame, visibleFrame, "the installed monitor handles the event before AppKit dispatch")

        window.setFrame(originalFrame, display: true)
        chrome.removeFromSuperview()
        XCTAssertFalse(chrome.isMonitoringDoubleClicks)
        sendThroughApp(event)
        XCTAssertEqual(window.frame, originalFrame, "detaching removes the event monitor")

        host.addSubview(chrome)
        XCTAssertTrue(chrome.isMonitoringDoubleClicks)
        WindowChromeConfigurator.dismantleNSView(chrome, coordinator: ())
        XCTAssertFalse(chrome.isMonitoringDoubleClicks)
        sendThroughApp(event)
        XCTAssertEqual(window.frame, originalFrame, "dismantling removes the event monitor")
        chrome.removeFromSuperview()
    }

    func testNativeTabDropOnEmptyTitleBarStripAppendsTheTab() async throws {
        let model = try modelWithTabs()
        let sourceGroup = model.tabGroupLayout.focusedGroupID
        let movedID = model.tabs[0].id
        let destinationID = model.tabs[1].id
        model.dropTab(destinationID, on: sourceGroup, zone: .trailing)
        let destinationGroup = model.tabGroupLayout.focusedGroupID
        let host = NSHostingView(rootView: TabGroupsView().environment(model))
        let window = try await hostedWindow(host)
        defer { window.orderOut(nil) }

        let tabs = descendants(of: host).compactMap { $0 as? TabDragSourceView }
        let source = try XCTUnwrap(tabs.first { $0.tabID == movedID })
        let destination = try XCTUnwrap(tabs.first { $0.tabID == destinationID })
        let start = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
        let destinationFrame = destination.convert(destination.bounds, to: nil)
        let end = NSPoint(x: destinationFrame.maxX + 60, y: destinationFrame.midY)
        XCTAssertTrue(TitleBarDoubleClick.isEmptyTitleBarSpace(at: end, in: window))

        let down = try click(at: start, count: 1, in: window)
        let begin = try mouseEvent(.leftMouseDragged, at: NSPoint(x: start.x + 10, y: start.y), in: window)
        let travel = try mouseEvent(.leftMouseDragged, at: end, in: window)
        let up = try mouseEvent(.leftMouseUp, at: end, in: window)
        source.mouseDown(with: down)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NSApp.postEvent(travel, atStart: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.postEvent(up, atStart: false) }
        source.mouseDragged(with: begin)

        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while ContinuousClock().now < deadline,
              model.tabGroupLayout.groupID(containing: movedID) != destinationGroup
        {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.tabGroupLayout.groupID(containing: movedID), destinationGroup)
        XCTAssertEqual(model.tabs(inGroup: destinationGroup).map(\.title), ["Two", "One"])
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

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func sendThroughApp(_ event: NSEvent) {
        NSApp.postEvent(event, atStart: true)
        if let received = NSApp.nextEvent(matching: .leftMouseDown, until: .now.addingTimeInterval(1), inMode: .default, dequeue: true) {
            NSApp.sendEvent(received)
        }
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

@MainActor
private final class RecordingWindow: NSWindow {
    private(set) var didMiniaturize = false

    override func miniaturize(_ sender: Any?) {
        didMiniaturize = true
    }
}
