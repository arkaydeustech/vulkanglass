import XCTest
import AppKit
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
