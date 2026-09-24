import XCTest
import AppKit
import SwiftUI
@testable import VulkanGlass

/// Each window has its own `AppModel`; windows share one `AppSession`.
@MainActor
final class MultiWindowTests: XCTestCase {
    func testWindowsOpenDifferentVaultsIndependently() async throws {
        let session = AppSession(settings: .default())
        let first = try vault(named: "First", note: "Alpha")
        let second = try vault(named: "Second", note: "Beta")
        let firstWindow = window(in: session)
        let secondWindow = window(in: session)

        await firstWindow.openVault(path: first.path)
        await secondWindow.openVault(path: second.path)

        XCTAssertEqual(firstWindow.vault?.path, first.path)
        XCTAssertEqual(secondWindow.vault?.path, second.path)
        XCTAssertEqual(firstWindow.tabs.map(\.title), ["Alpha"])
        XCTAssertEqual(secondWindow.tabs.map(\.title), ["Beta"])
        XCTAssertEqual(firstWindow.notes.map(\.title), ["Alpha"])
        XCTAssertEqual(secondWindow.notes.map(\.title), ["Beta"])

        await secondWindow.closeVault()
        XCTAssertNil(secondWindow.vault)
        XCTAssertEqual(firstWindow.vault?.path, first.path)
        XCTAssertEqual(firstWindow.tabs.map(\.title), ["Alpha"])
    }

    func testOpeningAVaultShownInAnotherWindowFocusesThatWindow() async throws {
        let session = AppSession(settings: .default())
        let root = try vault(named: "Shared", note: "Alpha")
        let firstWindow = window(in: session)
        let secondWindow = window(in: session)
        await firstWindow.openVault(path: root.path)
        XCTAssertTrue(session.activeModel === secondWindow)

        await secondWindow.openVault(path: root.path)

        XCTAssertNil(secondWindow.vault)
        XCTAssertTrue(secondWindow.tabs.isEmpty)
        XCTAssertNil(secondWindow.busyMessage)
        XCTAssertTrue(session.activeModel === firstWindow)
        XCTAssertEqual(firstWindow.vault?.path, root.path)
    }

    func testReopeningTheSameVaultInItsOwnWindowStillWorks() async throws {
        let session = AppSession(settings: .default())
        let root = try vault(named: "Mine", note: "Alpha")
        let model = window(in: session)
        await model.openVault(path: root.path)

        await model.openVault(path: root.path)

        XCTAssertEqual(model.vault?.path, root.path)
        XCTAssertEqual(model.tabs.map(\.title), ["Alpha"])
    }

    func testFinderOpenUsesTheWindowOwningTheFileAndKeepsTheOtherVault() async throws {
        let session = AppSession(settings: .default())
        let first = try vault(named: "FinderFirst", note: "Alpha")
        let second = try vault(named: "FinderSecond", note: "Beta")
        let firstWindow = window(in: session)
        let secondWindow = window(in: session)
        await firstWindow.openVault(path: first.path)
        await secondWindow.openVault(path: second.path)
        session.activate(firstWindow)
        let delegate = VulkanGlassAppDelegate()
        delegate.session = session

        delegate.application(.shared, open: [second.appendingPathComponent("Beta.md")])
        await delegate.externalOpenTask?.value

        XCTAssertEqual(firstWindow.vault?.path, first.path)
        XCTAssertEqual(secondWindow.vault?.path, second.path)
        XCTAssertEqual(secondWindow.activeTab?.title, "Beta")
        XCTAssertTrue(session.activeModel === secondWindow)
    }

    func testStandaloneOpenAndRecentFocusTheExistingWindow() async throws {
        let session = AppSession(settings: .default())
        let file = try temporaryDirectory().appendingPathComponent("Shared.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let first = window(in: session)
        let second = window(in: session)
        await first.openStandalone(url: file)
        await second.openStandalone(url: file)
        XCTAssertTrue(second.tabs.isEmpty)
        XCTAssertTrue(session.activeModel === first)

        session.activate(second)
        guard let recent = session.settings.recentFiles.first else {
            return XCTFail("The standalone file should be in recents")
        }
        await second.openRecent(.file(recent))
        XCTAssertTrue(second.tabs.isEmpty)
        XCTAssertTrue(session.activeModel === first)
    }

    func testStandaloneOpenFocusesVaultWindowOwningTheFile() async throws {
        let session = AppSession(settings: .default())
        let root = try vault(named: "Owner", note: "Alpha")
        let owner = window(in: session)
        let other = window(in: session)
        await owner.openVault(path: root.path)

        await other.openStandalone(url: root.appendingPathComponent("Alpha.md"))

        XCTAssertNil(other.vault)
        XCTAssertTrue(other.tabs.isEmpty)
        XCTAssertTrue(session.activeModel === owner)
    }

    func testSimultaneousVaultOpensReserveTheCanonicalPath() async throws {
        let session = AppSession(settings: .default())
        let root = try vault(named: "Racing", note: "Alpha")
        var resumeInspect: CheckedContinuation<VaultInfo, Never>?
        var dependencies = disabledAuthDependencies()
        dependencies.inspectVault = { path in
            await withCheckedContinuation { continuation in resumeInspect = continuation }
        }
        let first = AppModel(session: session, bootstrapOnLaunch: false, dependencies: dependencies)
        let second = window(in: session)
        session.register(first)
        let firstOpen = Task { await first.openVault(path: root.path) }
        await waitUntil { resumeInspect != nil }
        XCTAssertNotNil(resumeInspect)

        await second.openVault(path: root.appendingPathComponent("../Racing").path)
        XCTAssertNil(second.vault)
        XCTAssertTrue(session.activeModel === first)

        resumeInspect?.resume(returning: GitService.inspect(path: root.path))
        await firstOpen.value
        XCTAssertEqual(first.vault?.path, root.path)
        XCTAssertNil(second.vault)
    }

    func testSymlinkedVaultAndFilePathsFocusTheirOwners() async throws {
        let session = AppSession(settings: .default())
        let root = try vault(named: "Real", note: "Alpha")
        let alias = root.deletingLastPathComponent().appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let owner = window(in: session)
        let other = window(in: session)
        await owner.openVault(path: root.path)

        await other.openVault(path: alias.path)
        await other.openStandalone(url: alias.appendingPathComponent("Alpha.md"))

        XCTAssertNil(other.vault)
        XCTAssertTrue(other.tabs.isEmpty)
        XCTAssertTrue(session.activeModel === owner)
    }

    func testWindowsShareSettingsAndRecents() async throws {
        let session = AppSession(settings: .default())
        let root = try vault(named: "Recent", note: "Alpha")
        let firstWindow = window(in: session)
        let secondWindow = window(in: session)

        firstWindow.settings.appearanceMode = .dark
        XCTAssertEqual(secondWindow.settings.appearanceMode, .dark)
        XCTAssertTrue(secondWindow.dark)

        await firstWindow.openVault(path: root.path)
        XCTAssertEqual(secondWindow.settings.recentVaults.map(\.path), [root.path])

        secondWindow.clearRecents()
        XCTAssertTrue(firstWindow.settings.recentVaults.isEmpty)
    }

    func testWindowsShareTheGitHubConnection() async {
        let session = AppSession(settings: .default())
        var dependencies = AppModelDependencies(
            githubCLIStatus: { _ in GitHubCLIStatus() },
            githubUser: { _ in GitHubUser(login: "octocat", name: nil, avatarURL: "") },
            githubRepos: { _ in [] },
            loadKeychainToken: { "saved-token" },
            saveKeychainToken: { _ in }
        )
        dependencies.gitExecutablePath = { "/usr/bin/git" }
        let firstWindow = AppModel(session: session, bootstrapOnLaunch: false, dependencies: dependencies)
        let secondWindow = AppModel(session: session, bootstrapOnLaunch: false, dependencies: dependencies)

        await firstWindow.connectGitHub()

        XCTAssertEqual(secondWindow.githubUser?.login, "octocat")
        XCTAssertEqual(secondWindow.token, "saved-token")
        XCTAssertEqual(secondWindow.githubAuthSource, .personalAccessToken)
    }

    func testOnlyTheFirstWindowRunsLaunchWork() async {
        let session = AppSession(settings: .default())
        var gitChecks = 0
        var dependencies = disabledAuthDependencies()
        dependencies.gitExecutablePath = {
            gitChecks += 1
            return nil
        }
        let firstWindow = AppModel(session: session, bootstrapOnLaunch: false, dependencies: dependencies)
        let secondWindow = AppModel(session: session, bootstrapOnLaunch: false, dependencies: dependencies)

        await firstWindow.bootstrap()
        await secondWindow.bootstrap()

        XCTAssertEqual(gitChecks, 1)
        XCTAssertTrue(firstWindow.gitMissingWarningOpen)
        XCTAssertFalse(secondWindow.gitMissingWarningOpen)
    }

    func testLaunchVaultMovesToAWindowRegisteredDuringBootstrap() async throws {
        let session = AppSession(settings: .default())
        let root = try vault(named: "Launch", note: "Alpha")
        session.pendingLaunchVaultPath = root.path
        var resumeGitCheck: CheckedContinuation<String?, Never>?
        var dependencies = disabledAuthDependencies()
        dependencies.gitExecutablePath = {
            await withCheckedContinuation { continuation in resumeGitCheck = continuation }
        }
        let first = AppModel(session: session, bootstrapOnLaunch: false, dependencies: dependencies)
        session.register(first)
        let bootstrap = Task { await first.bootstrap() }
        await waitUntil { resumeGitCheck != nil }
        XCTAssertFalse(session.hasBootstrapped)
        session.unregister(first)
        let second = window(in: session)

        resumeGitCheck?.resume(returning: "/usr/bin/git")
        await bootstrap.value

        XCTAssertTrue(session.hasBootstrapped)
        XCTAssertNil(first.vault)
        XCTAssertEqual(second.vault?.path, root.path)
    }

    func testSessionTracksWindowsMostRecentlyFocusedFirst() {
        let session = AppSession(settings: .default())
        let first = window(in: session)
        let second = window(in: session)
        XCTAssertEqual(session.models.map(ObjectIdentifier.init), [second, first].map(ObjectIdentifier.init))

        session.activate(first)
        XCTAssertTrue(session.activeModel === first)
        XCTAssertEqual(session.models.count, 2)

        session.unregister(first)
        XCTAssertTrue(session.activeModel === second)
        session.unregister(second)
        XCTAssertNil(session.activeModel)
    }

    func testSessionDoesNotKeepClosedWindowsAlive() {
        let session = AppSession(settings: .default())
        weak var released: AppModel?
        do {
            let model = window(in: session)
            released = model
        }
        XCTAssertNil(released)
        XCTAssertTrue(session.models.isEmpty)
    }

    func testTerminationSettlesEveryWindowAndStopsAtCancel() async throws {
        let session = AppSession(settings: .default())
        let prompts = UnsavedPrompts(decision: .cancel)
        let firstFile = try temporaryDirectory().appendingPathComponent("First.md")
        let secondFile = try temporaryDirectory().appendingPathComponent("Second.md")
        try "old".write(to: firstFile, atomically: true, encoding: .utf8)
        try "old".write(to: secondFile, atomically: true, encoding: .utf8)
        let firstWindow = manualSaveWindow(in: session, prompts: prompts)
        let secondWindow = manualSaveWindow(in: session, prompts: prompts)
        firstWindow.tabs = [standaloneTab(firstFile, edited: "first")]
        secondWindow.tabs = [standaloneTab(secondFile, edited: "second")]
        let delegate = VulkanGlassAppDelegate()
        delegate.session = session

        let cancelled = expectation(description: "termination cancelled")
        delegate.replyToTermination = { _, ready in
            XCTAssertFalse(ready)
            cancelled.fulfill()
        }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(prompts.asked.count, 1)

        prompts.decision = .save
        let accepted = expectation(description: "termination accepted")
        delegate.replyToTermination = { _, ready in
            XCTAssertTrue(ready)
            accepted.fulfill()
        }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        await fulfillment(of: [accepted], timeout: 2)
        XCTAssertEqual(Set(prompts.asked.suffix(2).flatMap { $0 }), ["First", "Second"])
        XCTAssertEqual(try FileService.read(firstFile), "first")
        XCTAssertEqual(try FileService.read(secondFile), "second")
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateNow)
    }

    func testTerminationCommitsTitleEditingOnAnOtherwiseCleanWindow() async throws {
        let session = AppSession(settings: .default())
        let root = try vault(named: "RenameOnQuit", note: "Alpha")
        let model = window(in: session)
        await model.openVault(path: root.path)
        guard let tabID = model.activeTabID else { return XCTFail("Expected a vault tab") }
        model.beginEditingTitle(for: tabID)
        model.updateTitleDraft(for: tabID, draft: "Beta")
        XCTAssertTrue(model.needsPreparationBeforeClosing)
        XCTAssertFalse(model.tabs.contains { $0.dirty })
        let delegate = VulkanGlassAppDelegate()
        delegate.session = session
        let accepted = expectation(description: "quit after rename")
        delegate.replyToTermination = { _, ready in
            XCTAssertTrue(ready)
            accepted.fulfill()
        }

        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        await fulfillment(of: [accepted], timeout: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Beta.md").path))
    }

    func testTerminationWaitsForAPendingMoveWithoutDirtyTabs() async throws {
        let session = AppSession(settings: .default())
        let root = try vault(named: "MoveOnQuit", note: "Alpha")
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var resumeMove: CheckedContinuation<URL, Error>?
        var dependencies = disabledAuthDependencies()
        dependencies.moveFile = { _, _, _ in
            try await withCheckedThrowingContinuation { continuation in resumeMove = continuation }
        }
        let model = AppModel(session: session, bootstrapOnLaunch: false, dependencies: dependencies)
        session.register(model)
        await model.openVault(path: root.path)
        let source = root.appendingPathComponent("Alpha.md")
        let move = Task { await model.moveNote(path: source.path, toFolder: folder.path) }
        await waitUntil { resumeMove != nil }
        XCTAssertTrue(model.needsPreparationBeforeClosing)
        XCTAssertFalse(model.tabs.contains { $0.dirty })
        let delegate = VulkanGlassAppDelegate()
        delegate.session = session
        let accepted = expectation(description: "quit after move")
        delegate.replyToTermination = { _, ready in
            XCTAssertTrue(ready)
            accepted.fulfill()
        }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        let moved = try FileService.move(source, into: folder, root: root)
        resumeMove?.resume(returning: moved)
        await move.value
        await fulfillment(of: [accepted], timeout: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }

    func testFinderOpenRaisesAnOrderedOutReceivingWindow() async throws {
        let session = AppSession(settings: .default())
        let file = try temporaryDirectory().appendingPathComponent("Visible.md")
        try "visible".write(to: file, atomically: true, encoding: .utf8)
        let model = window(in: session)
        let host = testWindow()
        defer { host.orderOut(nil) }
        session.attach(host, to: model)
        host.orderOut(nil)
        XCTAssertFalse(host.isVisible)
        let delegate = VulkanGlassAppDelegate()
        delegate.session = session

        delegate.application(.shared, open: [file])
        await delegate.externalOpenTask?.value

        XCTAssertTrue(host.isVisible)
        XCTAssertEqual(model.activeTab?.title, "Visible")
    }

    func testWindowBridgeAttachesAndRestoresAHostedWindowDelegate() async {
        let session = AppSession(settings: .default())
        let model = window(in: session)
        let host = testWindow()
        let original = RecordingWindowDelegate()
        host.delegate = original
        let content = NSHostingView(rootView: AnyView(
            Color.clear.background(WindowSessionBridge(session: session, model: model))
        ))
        host.contentView = content
        defer { host.orderOut(nil) }
        await waitUntil { host.delegate is WindowCloseGuard }
        XCTAssertTrue(session.window(for: model) === host)
        guard let guardDelegate = host.delegate as? WindowCloseGuard else {
            return XCTFail("Expected the close guard on a hosted window")
        }
        XCTAssertTrue(guardDelegate.original === original)

        let replacement = RecordingWindowDelegate()
        host.delegate = replacement
        func bridgeView(in view: NSView?) -> WindowSessionView? {
            guard let view else { return nil }
            if let bridge = view as? WindowSessionView { return bridge }
            return view.subviews.lazy.compactMap { bridgeView(in: $0) }.first
        }
        bridgeView(in: host.contentView)?.installCloseGuard()
        XCTAssertTrue((host.delegate as? WindowCloseGuard)?.original === replacement)

        content.rootView = AnyView(Color.clear)
        await waitUntil { host.delegate === replacement }
        XCTAssertTrue(host.delegate === replacement)
    }

    func testHostedAppWindowsCreateIndependentModels() async {
        let session = AppSession(settings: .default())
        session.hasBootstrapped = true
        let delegate = VulkanGlassAppDelegate()
        delegate.session = session
        let updater = AppUpdater(disabled: true)
        let firstHost = testWindow()
        let secondHost = testWindow()
        defer {
            firstHost.close()
            secondHost.close()
        }
        firstHost.contentView = NSHostingView(rootView: AppWindow(
            session: session, updater: updater, appDelegate: delegate
        ))
        secondHost.contentView = NSHostingView(rootView: AppWindow(
            session: session, updater: updater, appDelegate: delegate
        ))
        await waitUntil { session.models.count == 2 }

        XCTAssertEqual(AppWindow.sceneID, "main")
        XCTAssertEqual(session.models.count, 2)
        XCTAssertFalse(session.models[0] === session.models[1])
        XCTAssertTrue(session.window(for: session.models[0]) != nil)
        XCTAssertTrue(session.window(for: session.models[1]) != nil)
        guard let firstModel = session.models.first(where: { session.window(for: $0) === firstHost }) else {
            return XCTFail("Expected the first hosted model")
        }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: firstHost)
        XCTAssertTrue(session.activeModel === firstModel)
    }

    func testNewWindowAndNewNoteMenuShortcuts() {
        func menuItem(_ title: String, in menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            for item in menu.items {
                if item.title == title { return item }
                if let nested = menuItem(title, in: item.submenu) { return nested }
            }
            return nil
        }

        let newWindow = menuItem("New Window", in: NSApp.mainMenu)
        let newNote = menuItem("New note", in: NSApp.mainMenu)
        XCTAssertEqual(newWindow?.keyEquivalent, "n")
        XCTAssertEqual(newNote?.keyEquivalent, "t")
        XCTAssertEqual(newWindow?.keyEquivalentModifierMask, .command)
        XCTAssertEqual(newNote?.keyEquivalentModifierMask, .command)
    }

    func testCloseGuardRetainsTheOriginalDelegateUntilRestored() {
        let model = window(in: AppSession(settings: .default()))
        let host = testWindow()
        defer { host.orderOut(nil) }
        var original: RecordingWindowDelegate? = RecordingWindowDelegate()
        weak var retained = original
        let guardDelegate = WindowCloseGuard(original: original, model: model)
        host.delegate = guardDelegate
        original = nil

        XCTAssertNotNil(retained)
        host.close()
        XCTAssertEqual(retained?.willCloseCalls, 1)
    }

    func testAppLaunchDisablesAutomaticWindowTabbing() {
        NSWindow.allowsAutomaticWindowTabbing = true
        let delegate = VulkanGlassAppDelegate()
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
    }

    func testClosingAWindowWritesItsPendingAutosaves() async throws {
        let root = try vault(named: "Close", note: "Alpha")
        let model = window(in: AppSession(settings: .default()))
        await model.openVault(path: root.path)
        let note = root.appendingPathComponent("Alpha.md")
        XCTAssertFalse(model.needsPreparationBeforeClosing)

        model.updateContent(note.path, "edited before close")
        XCTAssertTrue(model.needsPreparationBeforeClosing)
        let ready = await model.prepareToCloseWindow()

        XCTAssertTrue(ready)
        XCTAssertEqual(try FileService.read(note), "edited before close")
        XCTAssertFalse(model.needsPreparationBeforeClosing)
    }

    func testClosingAWindowCanBeCancelledForUnsavedStandaloneFiles() async throws {
        let file = try temporaryDirectory().appendingPathComponent("Loose.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let prompts = UnsavedPrompts(decision: .cancel)
        let model = manualSaveWindow(in: AppSession(settings: .default()), prompts: prompts)
        model.tabs = [standaloneTab(file, edited: "edited")]

        let cancelled = await model.prepareToCloseWindow()
        XCTAssertFalse(cancelled)
        XCTAssertEqual(try FileService.read(file), "old")

        prompts.decision = .save
        let saved = await model.prepareToCloseWindow()
        XCTAssertTrue(saved)
        XCTAssertEqual(try FileService.read(file), "edited")
    }

    func testCloseGuardHoldsTheWindowOpenUntilEditsAreSettled() async throws {
        let file = try temporaryDirectory().appendingPathComponent("Loose.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let prompts = UnsavedPrompts(decision: .cancel)
        let model = manualSaveWindow(in: AppSession(settings: .default()), prompts: prompts)
        model.tabs = [standaloneTab(file, edited: "edited")]
        let original = RecordingWindowDelegate()
        let window = testWindow()
        defer { window.orderOut(nil) }
        let closeGuard = WindowCloseGuard(original: original, model: model)
        window.delegate = closeGuard

        window.performClose(nil)
        await waitUntil { !prompts.asked.isEmpty }
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(original.shouldCloseCalls, 1)

        prompts.decision = .discard
        window.performClose(nil)
        await waitUntil { !window.isVisible }
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(prompts.asked.count, 2)
        XCTAssertEqual(original.willCloseCalls, 1)
        XCTAssertEqual(try FileService.read(file), "old")
    }

    func testCloseGuardClosesCleanWindowsImmediatelyAndRespectsTheOriginalDelegate() throws {
        let model = window(in: AppSession(settings: .default()))
        let original = RecordingWindowDelegate()
        let window = testWindow()
        defer { window.orderOut(nil) }
        let closeGuard = WindowCloseGuard(original: original, model: model)
        window.delegate = closeGuard

        original.allowsClose = false
        XCTAssertFalse(closeGuard.windowShouldClose(window))
        original.allowsClose = true
        XCTAssertTrue(closeGuard.windowShouldClose(window))
        XCTAssertTrue(closeGuard.responds(to: #selector(NSWindowDelegate.windowWillClose(_:))))

        window.close()
        XCTAssertEqual(original.willCloseCalls, 1)
    }

    // MARK: - Helpers

    private func window(in session: AppSession) -> AppModel {
        let model = AppModel(session: session, bootstrapOnLaunch: false, dependencies: disabledAuthDependencies())
        session.register(model)
        return model
    }

    private func manualSaveWindow(in session: AppSession, prompts: UnsavedPrompts) -> AppModel {
        var dependencies = disabledAuthDependencies()
        dependencies.confirmUnsavedChanges = { titles in
            prompts.asked.append(titles)
            return prompts.decision
        }
        let model = AppModel(session: session, bootstrapOnLaunch: false, dependencies: dependencies)
        session.register(model)
        return model
    }

    private func standaloneTab(_ url: URL, edited: String) -> NoteTab {
        NoteTab(
            path: url.path,
            title: Markdown.title(from: url.path),
            content: edited,
            originalContent: "old",
            isStandalone: true
        )
    }

    private func disabledAuthDependencies() -> AppModelDependencies {
        var dependencies = AppModelDependencies(
            githubCLIStatus: { _ in GitHubCLIStatus() },
            githubUser: { _ in throw GitHubError.noToken },
            githubRepos: { _ in [] },
            loadKeychainToken: { nil },
            saveKeychainToken: { _ in },
            authenticationDisabled: { true }
        )
        dependencies.gitExecutablePath = { "/usr/bin/git" }
        return dependencies
    }

    private func vault(named name: String, note: String) throws -> URL {
        let root = try temporaryDirectory().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# \(note)".write(to: root.appendingPathComponent("\(note).md"), atomically: true, encoding: .utf8)
        return FileService.canonicalURL(root)
    }

    private func testWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
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
private final class UnsavedPrompts {
    var decision: UnsavedChangesDecision
    var asked: [[String]] = []

    init(decision: UnsavedChangesDecision) {
        self.decision = decision
    }
}

/// Stands in for the delegate SwiftUI installs on its windows.
private final class RecordingWindowDelegate: NSObject, NSWindowDelegate {
    var allowsClose = true
    var shouldCloseCalls = 0
    var willCloseCalls = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldCloseCalls += 1
        return allowsClose
    }

    func windowWillClose(_ notification: Notification) {
        willCloseCalls += 1
    }
}
