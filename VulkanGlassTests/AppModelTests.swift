import XCTest
import AppKit
import SwiftUI
@testable import VulkanGlass

@MainActor
final class AppModelTests: XCTestCase {
    func testDefaultAppearanceInheritsDarkSystemMode() {
        let model = AppModel(
            settings: .default(),
            systemDarkMode: true,
            bootstrapOnLaunch: false
        )

        XCTAssertEqual(model.settings.appearanceMode, .inherit)
        XCTAssertTrue(model.dark)
    }

    func testDefaultAppearanceInheritsLightSystemMode() {
        let model = AppModel(
            settings: .default(),
            systemDarkMode: false,
            bootstrapOnLaunch: false
        )

        XCTAssertEqual(model.settings.appearanceMode, .inherit)
        XCTAssertFalse(model.dark)
    }

    func testExplicitAppearanceIgnoresSystemMode() {
        var settings = AppSettings.default()
        settings.appearanceMode = .light
        let model = AppModel(
            settings: settings,
            systemDarkMode: true,
            bootstrapOnLaunch: false
        )
        XCTAssertFalse(model.dark)

        model.settings.appearanceMode = .dark
        model.updateSystemDarkMode(false)
        XCTAssertTrue(model.dark)
    }

    func testDefaultAppearanceUsesSystemValueBeforeRootViewAppears() {
        let feed = SystemAppearanceFeed(currentDarkMode: true)
        let model = AppModel(
            settings: .default(),
            bootstrapOnLaunch: false,
            systemAppearanceProvider: feed.provider
        )

        XCTAssertTrue(model.systemDarkMode)
        XCTAssertTrue(model.dark)
        XCTAssertNotNil(feed.handler)
    }

    func testSystemAppearanceKeepsTrackingWhileExplicitOverrideIsActive() {
        let feed = SystemAppearanceFeed(currentDarkMode: false)
        let model = AppModel(
            settings: .default(),
            bootstrapOnLaunch: false,
            systemAppearanceProvider: feed.provider
        )
        model.settings.appearanceMode = .dark

        feed.send(isDark: true)
        XCTAssertTrue(model.dark)

        model.settings.appearanceMode = .inherit
        XCTAssertTrue(model.dark)

        feed.send(isDark: false)
        XCTAssertFalse(model.dark)
    }

    func testSystemAppearanceProviderClassifiesAquaAppearances() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertFalse(SystemAppearanceProvider.isDark(light))
        XCTAssertTrue(SystemAppearanceProvider.isDark(dark))
    }

    func testRootViewAppearancePreferenceMapsEveryMode() {
        XCTAssertNil(AppearanceMode.inherit.preferredColorScheme)
        XCTAssertEqual(AppearanceMode.light.preferredColorScheme, ColorScheme.light)
        XCTAssertEqual(AppearanceMode.dark.preferredColorScheme, ColorScheme.dark)
    }

    func testDevelopmentAuthenticationCanBeDisabledForAutomatedLaunches() {
        XCTAssertTrue(DevelopmentAuthentication.isDisabled(environment: [:], arguments: ["VulkanGlass", "--disable-auth"]))
        XCTAssertTrue(DevelopmentAuthentication.isDisabled(environment: ["VULKANGLASS_DISABLE_AUTH": "yes"], arguments: []))
        XCTAssertFalse(DevelopmentAuthentication.isDisabled(environment: ["VULKANGLASS_DISABLE_AUTH": "0"], arguments: []))
    }

    func testDevelopmentAuthenticationTrimsValuesAndRejectsUnrecognizedOnes() {
        XCTAssertTrue(DevelopmentAuthentication.isDisabled(environment: ["VULKANGLASS_DISABLE_AUTH": " 1 "], arguments: []))
        XCTAssertTrue(DevelopmentAuthentication.isDisabled(environment: ["VULKANGLASS_DISABLE_AUTH": "\tTRUE\n"], arguments: []))
        XCTAssertFalse(DevelopmentAuthentication.isDisabled(environment: ["VULKANGLASS_DISABLE_AUTH": ""], arguments: []))
        XCTAssertFalse(DevelopmentAuthentication.isDisabled(environment: ["VULKANGLASS_DISABLE_AUTH": "   "], arguments: []))
        XCTAssertFalse(DevelopmentAuthentication.isDisabled(environment: ["VULKANGLASS_DISABLE_AUTH": "maybe"], arguments: []))
        XCTAssertFalse(DevelopmentAuthentication.isDisabled(environment: [:], arguments: ["VulkanGlass", "--disable-authentication"]))
    }

    func testRunningUnderXCTestDisablesAuthenticationInTheHostApp() {
        // VulkanGlassTests is hosted by VulkanGlass.app, so `xcodebuild test` launches the real
        // app and runs AppModel.bootstrap(). Without this, that bootstrap reads the Keychain and
        // macOS shows an unlock prompt during every test run.
        XCTAssertTrue(DevelopmentAuthentication.isRunningTests())
        XCTAssertTrue(DevelopmentAuthentication.isDisabledForThisProcess)
        let liveModel = AppModel(settings: .default(), bootstrapOnLaunch: false)
        XCTAssertTrue(liveModel.authenticationDisabled)
    }

    func testTestEnvironmentDetectionLooksAtXCTestKeysOnly() {
        XCTAssertTrue(DevelopmentAuthentication.isRunningTests(environment: ["XCTestConfigurationFilePath": "/tmp/x.plist"]))
        XCTAssertTrue(DevelopmentAuthentication.isRunningTests(environment: ["XCTestBundlePath": "/tmp/x.xctest"]))
        XCTAssertTrue(DevelopmentAuthentication.isRunningTests(environment: ["XCTestSessionIdentifier": "abc"]))
        XCTAssertFalse(DevelopmentAuthentication.isRunningTests(environment: [:]))
        XCTAssertFalse(DevelopmentAuthentication.isRunningTests(environment: ["PATH": "/usr/bin"]))
        XCTAssertTrue(DevelopmentAuthentication.isDisabled(environment: ["XCTestBundlePath": "/tmp/x.xctest"], arguments: []))
    }

    func testDisabledAuthenticationDoesNotTouchCredentialSources() async {
        final class Calls {
            var cli = 0
            var keychain = 0
        }
        let calls = Calls()
        let dependencies = AppModelDependencies(
            githubCLIStatus: { _ in
                calls.cli += 1
                return GitHubCLIStatus(executablePath: "/usr/local/bin/gh", token: "cli")
            },
            githubUser: { token in GitHubUser(login: token, name: nil, avatarURL: "") },
            githubRepos: { _ in [] },
            loadKeychainToken: {
                calls.keychain += 1
                return "pat"
            },
            saveKeychainToken: { _ in },
            authenticationDisabled: { true }
        )
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)

        await model.connectGitHub()

        XCTAssertEqual(calls.cli, 0)
        XCTAssertEqual(calls.keychain, 0)
        XCTAssertNil(model.token)
        XCTAssertNil(model.githubAuthSource)
        XCTAssertTrue(model.authenticationDisabled)
    }

    func testDisabledAuthenticationRefusesToWriteAPersonalAccessToken() async {
        final class Calls {
            var saved: [String] = []
        }
        let calls = Calls()
        let model = AppModel(
            settings: .default(),
            bootstrapOnLaunch: false,
            dependencies: disabledAuthDependencies(onSave: { calls.saved.append($0) })
        )

        await model.saveToken("ghp_realtoken")

        XCTAssertTrue(calls.saved.isEmpty)
        XCTAssertNil(model.token)
        XCTAssertEqual(model.errorMessage, "GitHub authentication is disabled for this development launch.")
    }

    func testDisabledAuthenticationSkipsSyncAndReportsLocalOnly() async throws {
        let root = try temporaryDirectory()
        let model = AppModel(
            settings: .default(),
            bootstrapOnLaunch: false,
            dependencies: disabledAuthDependencies()
        )
        // Not a git repository: if the guard were missing, GitService.sync would fail outright.
        model.vault = VaultInfo(
            name: "vault",
            path: root.path,
            remote: "https://github.com/owner/repo.git",
            branch: "main",
            isGitHub: true
        )

        await model.syncNow()

        XCTAssertEqual(model.gitStatus?.state, .idle)
        XCTAssertEqual(model.gitStatus?.message, "Local only — GitHub auth disabled for development")
        XCTAssertEqual(model.gitStatus?.branch, "main")
        XCTAssertEqual(model.gitStatus?.remote, "https://github.com/owner/repo.git")
        XCTAssertNil(model.errorMessage)
    }

    func testDisabledAuthenticationOpensRemoteVaultWithoutPulling() async throws {
        let original = SettingsStore.load()
        defer { SettingsStore.save(original) }
        let root = try temporaryDirectory()
        try "# Welcome".write(to: root.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)
        let model = AppModel(
            settings: .default(),
            bootstrapOnLaunch: false,
            dependencies: disabledAuthDependencies()
        )
        let info = VaultInfo(
            name: root.lastPathComponent,
            path: root.path,
            remote: "https://github.com/owner/repo.git",
            branch: "main",
            isGitHub: true
        )

        await model.openVault(info)

        XCTAssertEqual(model.vault?.path, root.path)
        XCTAssertEqual(model.gitStatus?.message, "Local only — GitHub auth disabled for development")
        XCTAssertNotEqual(model.gitStatus?.state, .error)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.busyMessage)
        XCTAssertEqual(model.tabs.first?.title, "Welcome")
    }

    func testConnectGitHubFallsBackToPATWhenCLIIsRejected() async {
        let dependencies = AppModelDependencies(
            githubCLIStatus: { _ in GitHubCLIStatus(executablePath: "/usr/local/bin/gh", token: "cli") },
            githubUser: { token in
                if token == "cli" { throw GitHubError.api("CLI rejected") }
                return GitHubUser(login: "pat-user", name: nil, avatarURL: "")
            },
            githubRepos: { _ in [] },
            loadKeychainToken: { "pat" },
            saveKeychainToken: { _ in }
        )
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)

        await model.connectGitHub()

        XCTAssertEqual(model.githubAuthSource, .personalAccessToken)
        XCTAssertEqual(model.githubUser?.login, "pat-user")
        XCTAssertEqual(model.gitCredential, .personalAccessToken("pat"))
        XCTAssertNil(model.errorMessage)
    }

    func testNewerGitHubConnectionWinsWhenCLISettingChanges() async throws {
        let dependencies = AppModelDependencies(
            githubCLIStatus: { includeToken in
                if includeToken {
                    try? await Task.sleep(for: .milliseconds(150))
                    return GitHubCLIStatus(executablePath: "/usr/local/bin/gh", token: "cli")
                }
                return GitHubCLIStatus(executablePath: "/usr/local/bin/gh", token: nil)
            },
            githubUser: { token in GitHubUser(login: token, name: nil, avatarURL: "") },
            githubRepos: { _ in [] },
            loadKeychainToken: { "pat" },
            saveKeychainToken: { _ in }
        )
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)

        let staleConnection = Task { await model.connectGitHub() }
        try await Task.sleep(for: .milliseconds(20))
        model.settings.useGitHubCLI = false
        await model.connectGitHub()
        await staleConnection.value

        XCTAssertEqual(model.githubAuthSource, .personalAccessToken)
        XCTAssertEqual(model.githubUser?.login, "pat")
        XCTAssertEqual(model.gitCredential, .personalAccessToken("pat"))
    }

    func testConnectGitHubClearsStateWhenAllCandidatesFail() async {
        final class State {
            var shouldFail = false
        }
        let state = State()
        let dependencies = AppModelDependencies(
            githubCLIStatus: { _ in GitHubCLIStatus(executablePath: nil, token: nil) },
            githubUser: { token in
                if state.shouldFail { throw GitHubError.api("Rejected") }
                return GitHubUser(login: token, name: nil, avatarURL: "")
            },
            githubRepos: { _ in [] },
            loadKeychainToken: { "pat" },
            saveKeychainToken: { _ in }
        )
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)
        await model.connectGitHub()
        XCTAssertNotNil(model.githubUser)

        state.shouldFail = true
        await model.connectGitHub()

        XCTAssertNil(model.githubUser)
        XCTAssertTrue(model.githubRepos.isEmpty)
        XCTAssertNil(model.githubAuthSource)
        XCTAssertNil(model.token)
        XCTAssertEqual(model.errorMessage, "Rejected")
    }

    func testSaveTokenValidatesPATBeforePersistingEvenWhenCLIIsValid() async {
        final class Store {
            var saved: [String] = []
        }
        let store = Store()
        let dependencies = AppModelDependencies(
            githubCLIStatus: { _ in GitHubCLIStatus(executablePath: "/usr/local/bin/gh", token: "cli") },
            githubUser: { token in
                if token == "invalid" { throw GitHubError.api("Invalid PAT") }
                return GitHubUser(login: token, name: nil, avatarURL: "")
            },
            githubRepos: { token in
                if token == "invalid" { throw GitHubError.api("Invalid PAT") }
                return []
            },
            loadKeychainToken: { store.saved.last },
            saveKeychainToken: { store.saved.append($0) }
        )
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)

        await model.saveToken("invalid")
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(model.errorMessage, "Invalid PAT")

        await model.saveToken("valid-pat")
        XCTAssertEqual(store.saved, ["valid-pat"])
        XCTAssertEqual(model.githubAuthSource, .gitHubCLI)
        XCTAssertEqual(model.gitCredential, .gitHubCLI(executablePath: "/usr/local/bin/gh"))
        XCTAssertNil(model.errorMessage)
    }

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
        await model.setActiveTab(b.path)
        model.updateContent(b.path, "edited b")
        await model.awaitPendingSaves()

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

    func testNewVaultNoteOpensInSourceModeWithDocumentFocusRequested() async throws {
        let root = try temporaryDirectory()
        var settings = AppSettings.default()
        settings.autoSync = false
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)
        model.vault = VaultInfo(
            name: "vault",
            path: root.path,
            remote: nil,
            branch: nil,
            isGitHub: false
        )
        model.editorMode = .preview

        await model.newNote()

        let tab = try XCTUnwrap(model.activeTab)
        XCTAssertEqual(tab.title, "Untitled")
        XCTAssertNil(model.titleEditingTabID)
        XCTAssertEqual(model.editorMode, .source)
        XCTAssertEqual(model.centerView, .editor)
        XCTAssertEqual(model.editorFocusRequest?.tabID, tab.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tab.path))

        let focusRequestID = try XCTUnwrap(model.editorFocusRequest?.id)
        await model.renameNote(path: tab.path, newName: "Project Notes")

        let renamed = FileService.canonicalURL(root.appendingPathComponent("Project Notes.md"))
        XCTAssertNil(model.titleEditingTabID)
        XCTAssertEqual(model.editorFocusRequest?.id, focusRequestID)
        XCTAssertEqual(model.editorFocusRequest?.tabID, renamed.path)
        XCTAssertEqual(model.activeTab?.title, "Project Notes")
        XCTAssertEqual(
            model.activeTab.map { FileService.canonicalURL(URL(fileURLWithPath: $0.path)).path },
            renamed.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tab.path))
    }

    func testFolderDraftCapturesSubmittedNameBeforeClearingAndRefreshesFileTree() async throws {
        let root = try temporaryDirectory()
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.vault = VaultInfo(
            name: "vault",
            path: root.path,
            remote: nil,
            branch: nil,
            isGitHub: false
        )
        let draft = FolderCreationDraft()
        draft.name = "Project Notes"

        let submission = draft.submit(into: model)

        XCTAssertEqual(draft.name, "")
        await submission.value

        let folder = root.appendingPathComponent("Project Notes", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(model.fileTree.map(\.name), ["Project Notes"])
        XCTAssertNil(model.errorMessage)
    }

    func testFolderDraftIsEmptyWheneverCreationBeginsOrIsCancelled() {
        let draft = FolderCreationDraft()
        draft.name = "Abandoned"

        draft.cancel()
        XCTAssertEqual(draft.name, "")

        draft.name = "Stale"
        draft.begin()
        XCTAssertEqual(draft.name, "")
    }

    func testCreateFolderReportsExistingName() async throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Existing"),
            withIntermediateDirectories: false
        )
        let model = modelWithVault(at: root)

        await model.createFolder(name: "Existing")

        XCTAssertEqual(model.errorMessage, FileServiceError.nameTaken("Existing").localizedDescription)
        XCTAssertEqual(model.fileTree.map(\.name), [])
    }

    func testCreateFolderRejectsWhitespaceOnlyNameWithFeedback() async throws {
        let root = try temporaryDirectory()
        let model = modelWithVault(at: root)

        await model.createFolder(name: "  \n ")

        XCTAssertEqual(model.errorMessage, FileServiceError.emptyName.localizedDescription)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testCreateFolderRejectsPathSeparator() async throws {
        let root = try temporaryDirectory()
        let model = modelWithVault(at: root)

        await model.createFolder(name: "Nested/Folder")

        XCTAssertEqual(
            model.errorMessage,
            FileServiceError.invalidRelativePath("Nested/Folder").localizedDescription
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Nested").path))
    }

    func testBackToBackNewNotesKeepFocusTargetAndEditorModesScopedPerTab() async throws {
        let root = try temporaryDirectory()
        let existing = root.appendingPathComponent("Existing.md")
        try "existing".write(to: existing, atomically: true, encoding: .utf8)
        var settings = AppSettings.default()
        settings.autoSync = false
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)
        model.vault = VaultInfo(
            name: "vault",
            path: root.path,
            remote: nil,
            branch: nil,
            isGitHub: false
        )
        await model.openTab(path: existing.path)
        model.editorMode = .preview

        await model.newNote()
        let firstNewTab = try XCTUnwrap(model.activeTab)
        XCTAssertEqual(firstNewTab.editorMode, .source)

        await model.newNote()
        let secondNewTab = try XCTUnwrap(model.activeTab)

        XCTAssertNotEqual(
            firstNewTab.path,
            secondNewTab.path,
            "tabs=\(model.tabs.map(\.path)); files=\((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []); error=\(model.errorMessage ?? "nil")"
        )
        XCTAssertNil(model.titleEditingTabID)
        XCTAssertEqual(model.editorFocusRequest?.tabID, secondNewTab.id)
        XCTAssertEqual(secondNewTab.editorMode, .source)
        XCTAssertEqual(model.tabs.first(where: { $0.id == existing.path })?.editorMode, .preview)
        XCTAssertEqual(model.tabs.first(where: { $0.id == firstNewTab.id })?.editorMode, .source)

        await model.setActiveTab(existing.path)
        XCTAssertNil(model.titleEditingTabID)
        XCTAssertNil(model.editorFocusRequest)
        XCTAssertEqual(model.editorMode, .preview)

        await model.setActiveTab(firstNewTab.id)
        XCTAssertEqual(model.editorMode, .source)
    }

    func testStandaloneNewNoteUsesInjectedSaveDestinationAndRequestsEditorFocus() async throws {
        let root = try temporaryDirectory()
        let destination = root.appendingPathComponent("Untitled.md")
        var dependencies = disabledAuthDependencies()
        dependencies.chooseNewStandaloneNoteURL = { destination }
        let model = AppModel(
            settings: .default(),
            bootstrapOnLaunch: false,
            dependencies: dependencies
        )

        await model.newNote()

        let tab = try XCTUnwrap(model.activeTab)
        XCTAssertEqual(tab.path, destination.path)
        XCTAssertTrue(tab.isStandalone)
        XCTAssertEqual(tab.editorMode, .source)
        XCTAssertNil(model.titleEditingTabID)
        XCTAssertEqual(model.editorFocusRequest?.tabID, tab.id)
        XCTAssertEqual(try FileService.read(destination), "")
    }

    func testNewDailyNoteOpensInSourceModeWithDocumentFocusRequested() async throws {
        let root = try temporaryDirectory()
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        model.editorMode = .preview

        await model.dailyNote()

        let tab = try XCTUnwrap(model.activeTab)
        XCTAssertEqual(tab.title, (Markdown.dailyNoteName() as NSString).deletingPathExtension)
        XCTAssertEqual(tab.editorMode, .source)
        XCTAssertEqual(model.editorFocusRequest?.tabID, tab.id)
        XCTAssertNil(model.titleEditingTabID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tab.path))
    }

    func testExistingDailyNotePreservesItsEditorModeAndDoesNotRequestFocus() async throws {
        let root = try temporaryDirectory()
        let daily = root.appendingPathComponent("Daily").appendingPathComponent(Markdown.dailyNoteName())
        try FileService.write(daily, content: "Already here")
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        model.editorMode = .preview

        await model.dailyNote()

        XCTAssertEqual(model.activeTab?.path, daily.path)
        XCTAssertEqual(model.activeTab?.content, "Already here")
        XCTAssertEqual(model.editorMode, .preview)
        XCTAssertNil(model.editorFocusRequest)
    }

    func testMissingWikiLinkCreatesSourceTabAndRequestsDocumentFocus() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Source.md")
        try "[[Created from Wiki]]".write(to: source, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.openTab(path: source.path)
        model.editorMode = .preview

        await model.followWikiLink("Created from Wiki")

        let created = root.appendingPathComponent("Created from Wiki.md")
        XCTAssertEqual(
            model.activeTab.map { FileService.canonicalURL(URL(fileURLWithPath: $0.path)).path },
            FileService.canonicalURL(created).path
        )
        XCTAssertEqual(model.activeTab?.editorMode, .source)
        XCTAssertEqual(
            model.editorFocusRequest.map { FileService.canonicalURL(URL(fileURLWithPath: $0.tabID)).path },
            FileService.canonicalURL(created).path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
    }

    func testExistingWikiLinkPreservesModeWithoutRequestingCreationFocus() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Source.md")
        let target = root.appendingPathComponent("Existing.md")
        try "[[Existing]]".write(to: source, atomically: true, encoding: .utf8)
        try "Existing body".write(to: target, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.openTab(path: source.path)
        model.editorMode = .preview

        await model.followWikiLink("Existing")

        XCTAssertEqual(
            model.activeTab.map { FileService.canonicalURL(URL(fileURLWithPath: $0.path)).path },
            FileService.canonicalURL(target).path
        )
        XCTAssertEqual(model.activeTab?.editorMode, .preview)
        XCTAssertNil(model.editorFocusRequest)
        XCTAssertEqual(model.activeTab?.content, "Existing body")
    }

    func testFocusRequestFulfillmentIgnoresStaleIDsAndConsumesMatchingID() async throws {
        let root = try temporaryDirectory()
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.newNote()
        let request = try XCTUnwrap(model.editorFocusRequest)

        model.fulfillEditorFocusRequest(UUID())
        XCTAssertEqual(model.editorFocusRequest, request)

        model.fulfillEditorFocusRequest(request.id)
        XCTAssertNil(model.editorFocusRequest)
    }

    func testFocusRequestClearsWhenRequestingTabClosesOrIsDeleted() async throws {
        let closeRoot = try temporaryDirectory()
        let closeModel = AppModel(settings: .default(), bootstrapOnLaunch: false)
        closeModel.vault = VaultInfo(name: "close", path: closeRoot.path, remote: nil, branch: nil, isGitHub: false)
        await closeModel.newNote()
        let closeTabID = try XCTUnwrap(closeModel.editorFocusRequest?.tabID)

        await closeModel.closeTab(closeTabID)
        XCTAssertNil(closeModel.editorFocusRequest)

        let deleteRoot = try temporaryDirectory()
        let deleteModel = AppModel(settings: .default(), bootstrapOnLaunch: false)
        deleteModel.vault = VaultInfo(name: "delete", path: deleteRoot.path, remote: nil, branch: nil, isGitHub: false)
        await deleteModel.newNote()
        let deletePath = try XCTUnwrap(deleteModel.editorFocusRequest?.tabID)

        await deleteModel.deletePath(deletePath)
        XCTAssertNil(deleteModel.editorFocusRequest)
    }

    func testFocusRequestClearsWhenWorkspaceIsClosedRejectedOrReplaced() async throws {
        let closeRoot = try temporaryDirectory()
        let closeModel = AppModel(settings: .default(), bootstrapOnLaunch: false)
        closeModel.vault = VaultInfo(name: "close", path: closeRoot.path, remote: nil, branch: nil, isGitHub: false)
        await closeModel.newNote()
        XCTAssertNotNil(closeModel.editorFocusRequest)

        await closeModel.closeVault()
        XCTAssertNil(closeModel.editorFocusRequest)

        let rejectRoot = try temporaryDirectory()
        let rejectModel = AppModel(settings: .default(), bootstrapOnLaunch: false)
        rejectModel.vault = VaultInfo(name: "reject", path: rejectRoot.path, remote: nil, branch: nil, isGitHub: false)
        await rejectModel.newNote()
        XCTAssertNotNil(rejectModel.editorFocusRequest)

        let missingVault = rejectRoot.appendingPathComponent("Missing")
        rejectModel.vault = VaultInfo(name: "missing", path: missingVault.path, remote: nil, branch: nil, isGitHub: false)
        await rejectModel.openVault(path: missingVault.path)
        XCTAssertNil(rejectModel.editorFocusRequest)

        let replaceRoot = try temporaryDirectory()
        let replacement = replaceRoot.appendingPathComponent("Replacement.md")
        try "replacement".write(to: replacement, atomically: true, encoding: .utf8)
        let replaceModel = AppModel(settings: .default(), bootstrapOnLaunch: false)
        replaceModel.vault = VaultInfo(name: "replace", path: replaceRoot.path, remote: nil, branch: nil, isGitHub: false)
        await replaceModel.newNote()
        XCTAssertNotNil(replaceModel.editorFocusRequest)

        await replaceModel.openStandalone(url: replacement)
        XCTAssertNil(replaceModel.editorFocusRequest)
    }

    func testOpenTabCommitsTitleAndClearsEditingBeforeNavigation() async throws {
        let root = try temporaryDirectory()
        let first = root.appendingPathComponent("First.md")
        let second = root.appendingPathComponent("Second.md")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        await model.openTab(path: first.path, standalone: true)
        model.beginEditingTitle(for: first.path)
        model.updateTitleDraft(for: first.path, draft: "Committed First")

        await model.openTab(path: second.path, standalone: true)

        let renamed = root.appendingPathComponent("Committed First.md")
        XCTAssertNil(model.titleEditingTabID)
        XCTAssertEqual(model.activeTabID, second.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testStandaloneReplacementCommitsTitleBeforeReplacingTabs() async throws {
        let root = try temporaryDirectory()
        let first = root.appendingPathComponent("First.md")
        let replacement = root.appendingPathComponent("Replacement.md")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "replacement".write(to: replacement, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        await model.openTab(path: first.path, standalone: true)
        model.beginEditingTitle(for: first.path)
        model.updateTitleDraft(for: first.path, draft: "Saved Before Replace")

        await model.openStandalone(url: replacement)

        XCTAssertNil(model.titleEditingTabID)
        XCTAssertEqual(model.tabs.map(\.path), [replacement.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Saved Before Replace.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertNil(model.errorMessage)
    }

    func testCloseTabAndVaultCommitTitleBeforeTeardown() async throws {
        let root = try temporaryDirectory()
        let standalone = root.appendingPathComponent("Standalone.md")
        try "standalone".write(to: standalone, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        await model.openTab(path: standalone.path, standalone: true)
        model.beginEditingTitle(for: standalone.path)
        model.updateTitleDraft(for: standalone.path, draft: "Closed Tab")

        await model.closeTab(standalone.path)

        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Closed Tab.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: standalone.path))

        let vaultNote = root.appendingPathComponent("Vault Note.md")
        try "vault".write(to: vaultNote, atomically: true, encoding: .utf8)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.openTab(path: vaultNote.path)
        model.beginEditingTitle(for: vaultNote.path)
        model.updateTitleDraft(for: vaultNote.path, draft: "Closed Vault")

        await model.closeVault()

        XCTAssertNil(model.vault)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Closed Vault.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultNote.path))
        XCTAssertNil(model.errorMessage)
    }

    func testTitleEditingLifecycleIgnoresInvalidIDsAndClearsOnNavigationAndClose() async throws {
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

        model.beginEditingTitle(for: a.path)
        model.beginEditingTitle(for: "/missing.md")
        model.endEditingTitle(for: b.path)
        XCTAssertEqual(model.titleEditingTabID, a.path)

        await model.setActiveTab(b.path)
        XCTAssertNil(model.titleEditingTabID)

        model.beginEditingTitle(for: a.path)
        await model.closeTab(a.path)
        XCTAssertNil(model.titleEditingTabID)
        XCTAssertEqual(try FileService.read(a), "a")
    }

    func testClosingAndRejectingVaultClearTitleEditingBeforeTeardown() async throws {
        let root = try temporaryDirectory()
        let note = root.appendingPathComponent("Note.md")
        try "body".write(to: note, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        model.tabs = [NoteTab(path: note.path, title: "Note", content: "body", originalContent: "body", isStandalone: false)]
        model.activeTabID = note.path
        model.beginEditingTitle(for: note.path)

        await model.closeVault()

        XCTAssertNil(model.titleEditingTabID)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))

        let missing = root.appendingPathComponent("MissingVault")
        model.vault = VaultInfo(name: "missing", path: missing.path, remote: nil, branch: nil, isGitHub: false)
        model.tabs = [NoteTab(path: note.path, title: "Note", content: "body", originalContent: "body", isStandalone: false)]
        model.activeTabID = note.path
        model.beginEditingTitle(for: note.path)

        await model.openVault(path: missing.path)

        XCTAssertNil(model.titleEditingTabID)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.vault)
    }

    func testDeletingEditedNoteAndFolderClearsTitleEditingWithoutRenameErrors() async throws {
        let root = try temporaryDirectory()
        let note = root.appendingPathComponent("Delete Me.md")
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let child = folder.appendingPathComponent("Child.md")
        try "note".write(to: note, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try "child".write(to: child, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        model.tabs = [
            NoteTab(path: note.path, title: "Delete Me", content: "note", originalContent: "note", isStandalone: false),
            NoteTab(path: child.path, title: "Child", content: "child", originalContent: "child", isStandalone: false)
        ]
        model.activeTabID = note.path
        model.beginEditingTitle(for: note.path)

        await model.deletePath(note.path)

        XCTAssertNil(model.titleEditingTabID)
        XCTAssertFalse(model.tabs.contains(where: { $0.id == note.path }))
        XCTAssertNil(model.errorMessage)

        await model.setActiveTab(child.path)
        model.beginEditingTitle(for: child.path)
        await model.deletePath(folder.path)

        XCTAssertNil(model.titleEditingTabID)
        XCTAssertFalse(model.tabs.contains(where: { $0.id == child.path }))
        XCTAssertNil(model.errorMessage)
    }

    func testInlineRenameNativeFieldSelectsOnlyItsOwnFieldEditor() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        let filterField = NSTextField(string: "Filter text")
        filterField.frame = NSRect(x: 20, y: 70, width: 180, height: 24)
        let renameField = InlineRenameNSTextField(string: "Untitled")
        renameField.frame = NSRect(x: 20, y: 30, width: 180, height: 24)
        content.addSubview(filterField)
        content.addSubview(renameField)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)

        XCTAssertTrue(window.makeFirstResponder(filterField))
        let filterEditor = try XCTUnwrap(filterField.currentEditor() as? NSTextView)
        filterEditor.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(renameField.focusAndSelectAll())

        let renameEditor = try XCTUnwrap(renameField.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === renameEditor)
        XCTAssertEqual(renameEditor.selectedRange(), NSRange(location: 0, length: "Untitled".utf16.count))
        XCTAssertNil(filterField.currentEditor())
    }

    func testInlineRenameCommitsTextInsertedThroughActiveFieldEditor() throws {
        var draft = "Untitled"
        var committed: String?
        let representable = InlineRenameTextField(
            text: Binding(get: { draft }, set: { draft = $0 }),
            font: .systemFont(ofSize: 13),
            onCommit: { committed = $0 },
            onCancel: { XCTFail("A nonempty field-editor draft should commit") }
        )
        let coordinator = InlineRenameTextField.Coordinator(parent: representable)
        let field = InlineRenameNSTextField(string: draft)
        field.delegate = coordinator
        coordinator.attach(field)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(field.focusAndSelectAll())
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)

        editor.insertText("Typed in AppKit", replacementRange: editor.selectedRange())
        coordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )
        XCTAssertTrue(coordinator.control(
            field,
            textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))

        XCTAssertEqual(field.stringValue, "Typed in AppKit")
        XCTAssertEqual(committed, "Typed in AppKit")
    }

    func testInlineRenameEscapeAndWhitespaceCancelWithoutCommit() throws {
        var committed: String?
        var cancelCount = 0
        var draft = "Original"
        let representable = InlineRenameTextField(
            text: Binding(get: { draft }, set: { draft = $0 }),
            font: .systemFont(ofSize: 13),
            onCommit: { committed = $0 },
            onCancel: { cancelCount += 1 }
        )
        let escapeCoordinator = InlineRenameTextField.Coordinator(parent: representable)
        let escapeField = InlineRenameNSTextField(string: draft)
        escapeCoordinator.textField = escapeField
        let editor = NSTextView()

        XCTAssertTrue(escapeCoordinator.control(
            escapeField,
            textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))
        XCTAssertNil(committed)
        XCTAssertEqual(cancelCount, 1)

        let whitespaceRepresentable = InlineRenameTextField(
            text: Binding(get: { draft }, set: { draft = $0 }),
            font: .systemFont(ofSize: 13),
            commitOnDismantle: true,
            onCommit: { committed = $0 },
            onCancel: { cancelCount += 1 }
        )
        let whitespaceCoordinator = InlineRenameTextField.Coordinator(parent: whitespaceRepresentable)
        let whitespaceField = InlineRenameNSTextField(string: "   \n")
        whitespaceCoordinator.textField = whitespaceField
        whitespaceCoordinator.prepareForDismantle()

        XCTAssertNil(committed)
        XCTAssertEqual(cancelCount, 2)
    }

    func testRenderedNewNoteFocusesDocumentWithCaretReadyToType() async throws {
        let root = try temporaryDirectory()
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.newNote()
        XCTAssertNotNil(model.activeTab)
        let hostingView = NSHostingView(
            rootView: NoteEditorView()
                .environment(model)
                .frame(width: 700, height: 400)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        for _ in 0..<20 where !(window.firstResponder is SourceTextView) {
            await Task.yield()
            hostingView.layoutSubtreeIfNeeded()
        }

        let editor = try XCTUnwrap(firstDescendant(of: SourceTextView.self, in: hostingView))
        XCTAssertEqual(model.editorMode, .source)
        XCTAssertEqual(model.centerView, .editor)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertNil(model.editorFocusRequest)
        XCTAssertNil(model.titleEditingTabID)
        XCTAssertEqual(model.activeTab?.content, "")
        XCTAssertEqual(editor.string, "")
    }

    func testDailyNoteFocusWinsAfterCommandPaletteFieldDismisses() async throws {
        let root = try temporaryDirectory()
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        model.commandOpen = true
        let hostingView = NSHostingView(
            rootView: FocusContentionEditorView()
                .environment(model)
                .frame(width: 700, height: 400)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)

        var paletteField: NSTextField?
        for _ in 0..<50 where paletteField == nil {
            hostingView.layoutSubtreeIfNeeded()
            if let field = firstDescendant(of: NSTextField.self, in: hostingView) {
                paletteField = field
            } else {
                await Task.yield()
            }
        }
        let field = try XCTUnwrap(paletteField)
        XCTAssertTrue(window.makeFirstResponder(field))
        let paletteEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === paletteEditor)

        let dailyNote = Task { await model.dailyNote() }
        model.commandOpen = false
        await dailyNote.value
        for _ in 0..<50 where !(window.firstResponder is SourceTextView) {
            await Task.yield()
            hostingView.layoutSubtreeIfNeeded()
        }

        let editor = try XCTUnwrap(firstDescendant(of: SourceTextView.self, in: hostingView))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertNil(model.editorFocusRequest)
        XCTAssertFalse(model.commandOpen)
    }

    func testSourceEditorFocusRequestIsSingleFlightAndPlacesCaretAtEnd() async {
        let requestID = UUID()
        var focusAttempts = 0
        var fulfilled: [UUID] = []
        let coordinator = SourceEditor.Coordinator(
            onChange: { _ in },
            focus: { _ in
                focusAttempts += 1
                return true
            }
        )
        let editor = SourceTextView()
        editor.string = "Existing body"
        coordinator.textView = editor
        coordinator.onFocusRequestFulfilled = { fulfilled.append($0) }

        coordinator.updateFocusRequest(requestID)
        coordinator.updateFocusRequest(requestID)
        await drainMainQueue()

        XCTAssertEqual(focusAttempts, 1)
        XCTAssertEqual(fulfilled, [requestID])
        XCTAssertEqual(editor.selectedRange(), NSRange(location: "Existing body".utf16.count, length: 0))

        coordinator.updateFocusRequest(requestID)
        await drainMainQueue()
        XCTAssertEqual(focusAttempts, 1)
        XCTAssertEqual(fulfilled, [requestID])
    }

    func testSourceEditorFocusRequestRetriesAndStopsAfterExhaustion() async {
        var retryAttempts = 0
        let retryFulfilled = expectation(description: "Third focus attempt succeeds")
        let retryCoordinator = SourceEditor.Coordinator(
            onChange: { _ in },
            focus: { _ in
                retryAttempts += 1
                return retryAttempts == 3
            }
        )
        let retryEditor = SourceTextView()
        retryCoordinator.textView = retryEditor
        retryCoordinator.onFocusRequestFulfilled = { _ in retryFulfilled.fulfill() }
        retryCoordinator.updateFocusRequest(UUID())

        await fulfillment(of: [retryFulfilled], timeout: 1)
        XCTAssertEqual(retryAttempts, 3)

        var exhaustedAttempts = 0
        var exhaustedFulfilled = false
        let exhaustedCoordinator = SourceEditor.Coordinator(
            onChange: { _ in },
            focus: { _ in
                exhaustedAttempts += 1
                return false
            }
        )
        let exhaustedEditor = SourceTextView()
        exhaustedCoordinator.textView = exhaustedEditor
        exhaustedCoordinator.onFocusRequestFulfilled = { _ in exhaustedFulfilled = true }
        exhaustedCoordinator.updateFocusRequest(UUID())
        for _ in 0..<8 { await drainMainQueue() }

        XCTAssertEqual(exhaustedAttempts, 8)
        XCTAssertFalse(exhaustedFulfilled)
    }

    func testSourceEditorFocusRequestSupersedesPendingRequest() async {
        let first = UUID()
        let second = UUID()
        var attempts = 0
        var fulfilled: [UUID] = []
        let coordinator = SourceEditor.Coordinator(
            onChange: { _ in },
            focus: { _ in
                attempts += 1
                return true
            }
        )
        let editor = SourceTextView()
        coordinator.textView = editor
        coordinator.onFocusRequestFulfilled = { fulfilled.append($0) }

        coordinator.updateFocusRequest(first)
        coordinator.updateFocusRequest(second)
        await drainMainQueue()

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(fulfilled, [second])
    }

    func testSourceEditorPendingFocusIsAbandonedWhenClearedOrDismantled() async {
        var clearedAttempts = 0
        let clearedCoordinator = SourceEditor.Coordinator(
            onChange: { _ in },
            focus: { _ in
                clearedAttempts += 1
                return true
            }
        )
        let clearedEditor = SourceTextView()
        clearedCoordinator.textView = clearedEditor
        clearedCoordinator.updateFocusRequest(UUID())
        clearedCoordinator.updateFocusRequest(nil)
        await drainMainQueue()
        XCTAssertEqual(clearedAttempts, 0)

        var dismantledAttempts = 0
        let dismantledCoordinator = SourceEditor.Coordinator(
            onChange: { _ in },
            focus: { _ in
                dismantledAttempts += 1
                return true
            }
        )
        let dismantledEditor = SourceTextView()
        dismantledCoordinator.textView = dismantledEditor
        dismantledCoordinator.updateFocusRequest(UUID())
        dismantledCoordinator.prepareForDismantle()
        await drainMainQueue()
        XCTAssertEqual(dismantledAttempts, 0)
    }

    func testInlineRenameFocusRequestIsSingleFlight() async {
        var focusAttempts = 0
        let coordinator = InlineRenameTextField.Coordinator(
            parent: inlineRenameRepresentable(),
            focus: { _ in
                focusAttempts += 1
                return true
            }
        )
        let field = InlineRenameNSTextField(string: "Draft")
        coordinator.textField = field

        coordinator.requestFocus()
        coordinator.requestFocus()
        await drainMainQueue()

        XCTAssertEqual(focusAttempts, 1)
        XCTAssertFalse(coordinator.focusRequestPending)
    }

    func testInlineRenameFocusRequestRetriesAfterFailure() async {
        let attemptedFocus = expectation(description: "Focus retried until it succeeded")
        attemptedFocus.expectedFulfillmentCount = 3
        attemptedFocus.assertForOverFulfill = true
        var focusAttempts = 0
        let coordinator = InlineRenameTextField.Coordinator(
            parent: inlineRenameRepresentable(),
            focus: { _ in
                focusAttempts += 1
                attemptedFocus.fulfill()
                return focusAttempts == 3
            }
        )
        let field = InlineRenameNSTextField(string: "Draft")
        coordinator.textField = field

        coordinator.requestFocus(remainingAttempts: 3)
        await fulfillment(of: [attemptedFocus], timeout: 1)
        await drainMainQueue()

        XCTAssertEqual(focusAttempts, 3)
        XCTAssertFalse(coordinator.focusRequestPending)
    }

    func testInlineRenamePendingFocusIsAbandonedDuringDismantle() async {
        var focusAttempts = 0
        let coordinator = InlineRenameTextField.Coordinator(
            parent: inlineRenameRepresentable(),
            focus: { _ in
                focusAttempts += 1
                return true
            }
        )
        let field = InlineRenameNSTextField(string: "Draft")
        coordinator.textField = field

        coordinator.requestFocus()
        coordinator.prepareForDismantle()
        await drainMainQueue()

        XCTAssertEqual(focusAttempts, 0)
        XCTAssertFalse(coordinator.focusRequestPending)
    }

    func testInlineRenamePendingFocusIsAbandonedAfterCompletion() async {
        var committed: String?
        var focusAttempts = 0
        let coordinator = InlineRenameTextField.Coordinator(
            parent: inlineRenameRepresentable(onCommit: { committed = $0 }),
            focus: { _ in
                focusAttempts += 1
                return true
            }
        )
        let field = InlineRenameNSTextField(string: "Draft")
        coordinator.textField = field

        coordinator.requestFocus()
        XCTAssertTrue(coordinator.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        await drainMainQueue()

        XCTAssertEqual(committed, "Draft")
        XCTAssertEqual(focusAttempts, 0)
        XCTAssertFalse(coordinator.focusRequestPending)
    }

    func testEnteringTitleRenameAfterRenderingKeepsTheFieldEditing() async throws {
        let root = try temporaryDirectory()
        let note = root.appendingPathComponent("Existing Note.md")
        try "body".write(to: note, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        await model.openTab(path: note.path, standalone: true)
        let tab = try XCTUnwrap(model.activeTab)
        let hostingView = NSHostingView(
            rootView: NoteEditorView()
                .environment(model)
                .frame(width: 700, height: 400)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()

        model.beginEditingTitle(for: tab.id)
        guard let (field, editor) = await waitForInlineRenameEditor(in: hostingView) else {
            XCTFail("The title rename field did not install its field editor within one second")
            return
        }
        // Let any focus work queued by the same SwiftUI update finish before checking that the
        // editing session survived. The regression enqueued a second request that ended editing.
        await drainMainQueue()
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(model.titleEditingTabID, tab.id)
        XCTAssertTrue(window.firstResponder === editor)

        editor.insertText("Renamed", replacementRange: editor.selectedRange())
        XCTAssertEqual(field.stringValue, "Renamed")
        XCTAssertEqual(model.titleEditingDraft, "Renamed")
        XCTAssertEqual(model.titleEditingTabID, tab.id)
    }

    func testInlineRenameDismantleDoesNotCommitDraft() async {
        var draft = "Half typed"
        var committed: String?
        var cancelled = false
        let representable = InlineRenameTextField(
            text: Binding(get: { draft }, set: { draft = $0 }),
            font: .systemFont(ofSize: 13),
            onCommit: { committed = $0 },
            onCancel: { cancelled = true }
        )
        let coordinator = InlineRenameTextField.Coordinator(parent: representable)
        let field = InlineRenameNSTextField(string: draft)
        coordinator.textField = field
        coordinator.prepareForDismantle()

        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        await Task.yield()

        XCTAssertNil(committed)
        XCTAssertFalse(cancelled)
    }

    func testDocumentTitleDismantleCommitsDraft() {
        var draft = "Renamed on tab switch"
        var committed: String?
        let representable = InlineRenameTextField(
            text: Binding(get: { draft }, set: { draft = $0 }),
            font: .systemFont(ofSize: 34, weight: .bold),
            commitOnDismantle: true,
            onCommit: { committed = $0 },
            onCancel: { XCTFail("A nonempty document title should commit") }
        )
        let coordinator = InlineRenameTextField.Coordinator(parent: representable)
        let field = InlineRenameNSTextField(string: draft)
        coordinator.textField = field

        coordinator.prepareForDismantle()

        XCTAssertEqual(committed, "Renamed on tab switch")
    }

    func testInlineRenameBlurCommitsWhileFieldRemainsAttached() async {
        var draft = "Renamed"
        var committed: String?
        let representable = InlineRenameTextField(
            text: Binding(get: { draft }, set: { draft = $0 }),
            font: .systemFont(ofSize: 13),
            onCommit: { committed = $0 },
            onCancel: { XCTFail("A nonempty draft should commit") }
        )
        let coordinator = InlineRenameTextField.Coordinator(parent: representable)
        let field = InlineRenameNSTextField(string: draft)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView?.addSubview(field)
        coordinator.textField = field

        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        await Task.yield()

        XCTAssertEqual(committed, "Renamed")
    }

    func testSwitchingTabsCommitsTitleAndGivesNextEditFreshState() async throws {
        let root = try temporaryDirectory()
        let firstURL = root.appendingPathComponent("First Untitled.md")
        let secondURL = root.appendingPathComponent("Second Untitled.md")
        try "first".write(to: firstURL, atomically: true, encoding: .utf8)
        try "second".write(to: secondURL, atomically: true, encoding: .utf8)
        let firstPath = firstURL.path
        let secondPath = secondURL.path
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.tabs = [
            NoteTab(path: firstPath, title: "Untitled", content: "", originalContent: "", isStandalone: true),
            NoteTab(path: secondPath, title: "Untitled 1", content: "", originalContent: "", isStandalone: true)
        ]
        model.activeTabID = firstPath
        model.beginEditingTitle(for: firstPath)
        let hostingView = NSHostingView(
            rootView: NoteEditorView()
                .environment(model)
                .frame(width: 700, height: 400)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()

        let firstField = try XCTUnwrap(firstDescendant(of: InlineRenameNSTextField.self, in: hostingView))
        firstField.stringValue = "First draft"
        (firstField.delegate as? InlineRenameTextField.Coordinator)?.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: firstField)
        )

        await model.setActiveTab(secondPath)
        model.beginEditingTitle(for: secondPath)
        hostingView.layoutSubtreeIfNeeded()
        await Task.yield()
        hostingView.layoutSubtreeIfNeeded()

        let secondField = try XCTUnwrap(firstDescendant(of: InlineRenameNSTextField.self, in: hostingView))
        XCTAssertFalse(firstField === secondField)
        XCTAssertEqual(secondField.stringValue, "Untitled 1")

        let renamedURL = root.appendingPathComponent("First draft.md")
        for _ in 0..<50 where !model.tabs.contains(where: { $0.title == "First draft" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath))
        XCTAssertEqual(model.tabs.first(where: { $0.title == "First draft" })?.path, renamedURL.path)
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

    func testOpeningMissingVaultStaysOnWelcomeAndForgetsRecent() async {
        let original = SettingsStore.load()
        defer { SettingsStore.save(original) }
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SampleVault-\(UUID().uuidString)")
        var settings = AppSettings.default()
        settings.recentVaults = [
            RecentVault(name: "SampleVault", path: missing.path, remote: nil, lastOpened: 0),
            RecentVault(name: "KeepMe", path: "/tmp/keep-me", remote: nil, lastOpened: 0)
        ]
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)

        await model.openVault(path: missing.path)

        XCTAssertNil(model.vault)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertFalse(model.inWorkspace)
        XCTAssertNil(model.busyMessage)
        XCTAssertEqual(model.errorMessage, FileServiceError.missingVault(missing.lastPathComponent).localizedDescription)
        XCTAssertEqual(model.settings.recentVaults.map(\.name), ["KeepMe"])
    }

    func testOpeningExistingFolderEntersWorkspace() async throws {
        let original = SettingsStore.load()
        defer { SettingsStore.save(original) }
        let root = try temporaryDirectory()
        try "# Welcome".write(to: root.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)

        await model.openVault(path: root.path)

        XCTAssertEqual(model.vault?.path, root.path)
        XCTAssertTrue(model.inWorkspace)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.tabs.first?.title, "Welcome")
    }

    func testRenameUpdatesOpenTabAndPreservesDirtyContent() async throws {
        let original = SettingsStore.load()
        defer { SettingsStore.save(original) }
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Untitled.md")
        try "draft".write(to: source, atomically: true, encoding: .utf8)
        var settings = AppSettings.default()
        settings.autoSync = false
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        model.tabs = [
            NoteTab(path: source.path, title: "Untitled", content: "edited", originalContent: "draft", isStandalone: false)
        ]
        model.activeTabID = source.path
        model.beginEditingTitle(for: source.path)

        await model.renameNote(path: source.path, newName: "Hello")

        let dest = FileService.canonicalURL(root.appendingPathComponent("Hello.md"))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(
            model.activeTabID.map { FileService.canonicalURL(URL(fileURLWithPath: $0)).path },
            dest.path
        )
        XCTAssertEqual(model.tabs.first?.title, "Hello")
        XCTAssertEqual(model.titleEditingTabID, dest.path)
        XCTAssertEqual(
            model.tabs.first.map { FileService.canonicalURL(URL(fileURLWithPath: $0.path)).path },
            dest.path
        )
        XCTAssertEqual(try FileService.read(dest), "edited")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testRenameStandaloneFileRetargetsTheOpenTab() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Solo.md")
        try "body".write(to: source, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.tabs = [NoteTab(path: source.path, title: "Solo", content: "body", originalContent: "body", isStandalone: true)]
        model.activeTabID = source.path

        await model.renameNote(path: source.path, newName: "Renamed")

        let destination = root.appendingPathComponent("Renamed.md")
        XCTAssertEqual(model.activeTabID, destination.path)
        XCTAssertEqual(model.tabs.first?.path, destination.path)
        XCTAssertEqual(model.tabs.first?.title, "Renamed")
        XCTAssertEqual(try FileService.read(destination), "body")
    }

    func testRenameCollisionPublishesErrorAndKeepsOriginalTab() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Source.md")
        let taken = root.appendingPathComponent("Taken.md")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "taken".write(to: taken, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.tabs = [NoteTab(path: source.path, title: "Source", content: "source", originalContent: "source", isStandalone: true)]
        model.activeTabID = source.path

        await model.renameNote(path: source.path, newName: "Taken")

        XCTAssertEqual(model.activeTabID, source.path)
        XCTAssertEqual(model.tabs.first?.path, source.path)
        XCTAssertEqual(model.errorMessage, FileServiceError.nameTaken("Taken.md").localizedDescription)
        XCTAssertEqual(try FileService.read(source), "source")
    }

    func testRenameStopsWhenDirtyTabCannotBeSaved() async {
        let source = "/dev/null/Unsaved.md"
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.tabs = [NoteTab(path: source, title: "Unsaved", content: "new", originalContent: "old", isStandalone: true)]
        model.activeTabID = source

        await model.renameNote(path: source, newName: "Renamed")

        XCTAssertEqual(model.activeTabID, source)
        XCTAssertEqual(model.tabs.first?.path, source)
        XCTAssertTrue(model.tabs.first?.dirty == true)
        XCTAssertNotNil(model.errorMessage)
    }

    func testRenameIgnoresEmptyAndUnchangedNames() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Same.md")
        try "body".write(to: source, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.tabs = [NoteTab(path: source.path, title: "Same", content: "body", originalContent: "body", isStandalone: true)]

        await model.renameNote(path: source.path, newName: "   ")
        await model.renameNote(path: source.path, newName: "Same.md")

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(model.tabs.first?.path, source.path)
        XCTAssertNil(model.errorMessage)
    }

    private func disabledAuthDependencies(
        onSave: @escaping (String) -> Void = { _ in }
    ) -> AppModelDependencies {
        AppModelDependencies(
            githubCLIStatus: { _ in
                XCTFail("gh must not be invoked while authentication is disabled")
                return GitHubCLIStatus()
            },
            githubUser: { _ in
                XCTFail("GitHub must not be contacted while authentication is disabled")
                throw GitHubError.noToken
            },
            githubRepos: { _ in
                XCTFail("GitHub must not be contacted while authentication is disabled")
                throw GitHubError.noToken
            },
            loadKeychainToken: {
                XCTFail("the Keychain must not be read while authentication is disabled")
                return nil
            },
            saveKeychainToken: { onSave($0) },
            authenticationDisabled: { true }
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func modelWithVault(at root: URL) -> AppModel {
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.vault = VaultInfo(
            name: "vault",
            path: root.path,
            remote: nil,
            branch: nil,
            isGitHub: false
        )
        return model
    }

    private func inlineRenameRepresentable(
        onCommit: @escaping (String) -> Void = { _ in }
    ) -> InlineRenameTextField {
        return InlineRenameTextField(
            text: .constant("Draft"),
            font: .systemFont(ofSize: 13),
            onCommit: onCommit,
            onCancel: {}
        )
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func waitForInlineRenameEditor(
        in root: NSView,
        timeout: Duration = .seconds(1)
    ) async -> (InlineRenameNSTextField, NSTextView)? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            root.layoutSubtreeIfNeeded()
            if let field = firstDescendant(of: InlineRenameNSTextField.self, in: root),
               let editor = field.currentEditor() as? NSTextView {
                return (field, editor)
            }
            await Task.yield()
        } while clock.now < deadline
        return nil
    }
}

@MainActor
private final class SystemAppearanceFeed {
    var currentDarkMode: Bool
    var handler: (@MainActor @Sendable (Bool) -> Void)?

    init(currentDarkMode: Bool) {
        self.currentDarkMode = currentDarkMode
    }

    var provider: SystemAppearanceProvider {
        SystemAppearanceProvider(
            currentDarkMode: { [unowned self] in currentDarkMode },
            observeDarkMode: { [unowned self] handler in
                self.handler = handler
                return nil
            }
        )
    }

    func send(isDark: Bool) {
        currentDarkMode = isDark
        handler?(isDark)
    }
}

private struct FocusContentionEditorView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var paletteFocused: Bool
    @State private var query = ""

    var body: some View {
        ZStack {
            NoteEditorView()
            if model.commandOpen {
                TextField("Command", text: $query)
                    .focused($paletteFocused)
                    .frame(width: 240)
                    .onAppear { paletteFocused = true }
            }
        }
    }
}

private func firstDescendant<View: NSView>(of type: View.Type, in root: NSView) -> View? {
    if let match = root as? View { return match }
    for subview in root.subviews {
        if let match = firstDescendant(of: type, in: subview) { return match }
    }
    return nil
}
