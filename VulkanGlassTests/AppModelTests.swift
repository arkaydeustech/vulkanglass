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

    func testXCTestSettingsDirectoryIsPerProcessTemporaryStorage() {
        XCTAssertTrue(DevelopmentAuthentication.isRunningTests())
        let expected = FileManager.default.temporaryDirectory
            .appendingPathComponent("VulkanGlassTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VulkanGlass", isDirectory: true)

        XCTAssertEqual(SettingsStore.directory, expected)
        XCTAssertNotEqual(SettingsStore.directory, applicationSupport)
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

    func testMissingGitRaisesInstallWarning() async {
        var dependencies = disabledAuthDependencies()
        dependencies.gitExecutablePath = { nil }
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)

        await model.bootstrap()

        XCTAssertTrue(model.gitMissingWarningOpen)
    }

    func testInstalledGitDoesNotWarn() async {
        var dependencies = disabledAuthDependencies()
        var installed = false
        dependencies.gitExecutablePath = { installed ? "/usr/bin/git" : nil }
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)

        await model.checkGitInstalled()
        XCTAssertTrue(model.gitMissingWarningOpen)
        installed = true
        await model.checkGitInstalled()

        XCTAssertFalse(model.gitMissingWarningOpen)
    }

    func testCreateGithubVaultWithMissingGitSkipsRemoteAndLocalWrites() async throws {
        let root = try temporaryDirectory()
        var settings = AppSettings.default()
        settings.vaultsRoot = root.path
        var createCalls = 0
        var dependencies = AppModelDependencies(
            githubCLIStatus: { _ in GitHubCLIStatus() },
            githubUser: { _ in GitHubUser(login: "owner", name: nil, avatarURL: "") },
            githubRepos: { _ in [] },
            loadKeychainToken: { "test-token" },
            saveKeychainToken: { _ in }
        )
        dependencies.gitExecutablePath = { nil }
        dependencies.createGithubRepo = { _, _, _ in
            createCalls += 1
            throw GitHubError.api("Unexpected POST /user/repos")
        }
        let model = AppModel(settings: settings, bootstrapOnLaunch: false, dependencies: dependencies)
        await model.connectGitHub()
        XCTAssertNotNil(model.token)
        await model.checkGitInstalled()

        await model.createGithubVault(name: "NewVault", isPrivate: true)

        XCTAssertEqual(createCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("NewVault").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertEqual(model.errorMessage, GitServiceError.gitNotInstalled.localizedDescription)
        XCTAssertNil(model.busyMessage)
    }

    func testOpeningGitVaultWithMissingGitKeepsInstallAlertOnly() async throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)
        try "# Welcome".write(to: root.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)
        var dependencies = disabledAuthDependencies()
        dependencies.gitExecutablePath = { nil }
        dependencies.vaultGitStatus = { GitService.status(path: $0, executable: { nil }) }
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)

        await model.checkGitInstalled()
        await model.openVault(path: root.path)

        XCTAssertTrue(model.gitMissingWarningOpen)
        XCTAssertEqual(model.vault?.path, root.path)
        XCTAssertEqual(model.gitStatus?.state, .error)
        XCTAssertEqual(model.gitStatus?.message, GitServiceError.gitNotInstalled.localizedDescription)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.tabs.first?.title, "Welcome")
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

    func testRevealHeadingCountsEarlierHeadingsWithTheSameText() throws {
        let model = AppModel(settings: AppSettings.default(), bootstrapOnLaunch: false)
        let content = "# Doc\n## Notes\ntext\n### Notes\n## Notes"
        model.tabs = [NoteTab(path: "/tmp/Doc.md", title: "Doc", content: content, originalContent: content, isStandalone: true)]
        model.activeTabID = "/tmp/Doc.md"
        model.centerView = .graph

        model.revealHeading(at: 3)

        let request = try XCTUnwrap(model.headingScrollRequest)
        XCTAssertEqual(request.tabID, "/tmp/Doc.md")
        XCTAssertEqual(request.heading.line, 5)
        XCTAssertEqual(request.occurrence, 1)
        XCTAssertEqual(model.centerView, .editor)
        model.fulfillHeadingScrollRequest(UUID())
        XCTAssertNotNil(model.headingScrollRequest)
        model.fulfillHeadingScrollRequest(request.id)
        XCTAssertNil(model.headingScrollRequest)
    }

    func testRevealHeadingOccurrenceSkipsFencesAndDetails() throws {
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        let content = "# Title\n~~~\n## Notes\n~~~\n<details open>\n<summary>More</summary>\n## Notes\n</details>\n## Notes\n## Notes"
        model.tabs = [NoteTab(path: "/tmp/Title.md", title: "Title", content: content, originalContent: content, isStandalone: true)]
        model.activeTabID = "/tmp/Title.md"

        model.revealHeading(at: 2)

        let request = try XCTUnwrap(model.headingScrollRequest)
        XCTAssertEqual(request.heading.line, 10)
        XCTAssertEqual(request.occurrence, 1)
        let preview = MarkdownPreviewView(
            text: content, noteTitles: [], headingTarget: ReadingHeadingTarget(
                id: request.id, level: request.heading.level,
                text: request.heading.text, occurrence: request.occurrence
            ), onWiki: { _ in }
        )
        let rendered = ReadingAttributedDocument.make(
            blocks: preview.displayBlocks, noteTitles: [], baseURL: nil, dark: true
        )
        let target = try XCTUnwrap(preview.displayedHeadingTarget)
        let location = try XCTUnwrap(UnifiedReadingTextView.Coordinator.location(of: target, in: rendered))
        XCTAssertGreaterThan(location, 0)
        XCTAssertEqual(location, (rendered.string as NSString).range(of: "Notes", options: .backwards).location)
    }

    func testAutosavePersistsTheEditedTabAfterSwitching() async throws {
        let root = try temporaryDirectory()
        let a = root.appendingPathComponent("A.md")
        let b = root.appendingPathComponent("B.md")
        try "a".write(to: a, atomically: true, encoding: .utf8)
        try "b".write(to: b, atomically: true, encoding: .utf8)
        var settings = AppSettings.default()
        settings.autoSync = false
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        model.tabs = [
            NoteTab(path: a.path, title: "A", content: "a", originalContent: "a", isStandalone: false),
            NoteTab(path: b.path, title: "B", content: "b", originalContent: "b", isStandalone: false)
        ]
        model.activeTabID = a.path

        model.updateContent(a.path, "edited a")
        await model.setActiveTab(b.path)
        model.updateContent(b.path, "edited b")
        await model.awaitPendingSaves()

        XCTAssertEqual(try FileService.read(a), "edited a")
        XCTAssertEqual(try FileService.read(b), "edited b")
    }

    func testSwitchingTabsFlushesVaultEditsButKeepsStandaloneEditsInMemory() async throws {
        let vaultRoot = try temporaryDirectory()
        let vaultNote = vaultRoot.appendingPathComponent("Vault.md")
        let looseNote = try temporaryDirectory().appendingPathComponent("Loose.md")
        try "vault".write(to: vaultNote, atomically: true, encoding: .utf8)
        try "loose".write(to: looseNote, atomically: true, encoding: .utf8)
        let model = manualSaveModel(prompts: UnsavedChangesPrompts(decision: .cancel))
        model.vault = VaultInfo(name: "vault", path: vaultRoot.path, remote: nil, branch: nil, isGitHub: false)
        model.tabs = [
            NoteTab(path: vaultNote.path, title: "Vault", content: "vault", originalContent: "vault", isStandalone: false),
            NoteTab(path: looseNote.path, title: "Loose", content: "loose", originalContent: "loose", isStandalone: true)
        ]
        model.activeTabID = vaultNote.path

        model.updateContent(vaultNote.path, "edited vault")
        await model.setActiveTab(looseNote.path)
        await model.awaitPendingSaves()
        XCTAssertEqual(try FileService.read(vaultNote), "edited vault")

        model.updateContent(looseNote.path, "edited loose")
        await model.setActiveTab(vaultNote.path)
        await model.awaitPendingSaves()
        XCTAssertEqual(try FileService.read(looseNote), "loose")
        XCTAssertEqual(model.tabs[1].content, "edited loose")
        XCTAssertTrue(model.tabs[1].dirty)
    }

    func testClosingDirtyTabFlushesIt() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("Note.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let prompts = UnsavedChangesPrompts(decision: .cancel)
        let model = manualSaveModel(prompts: prompts)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        model.tabs = [NoteTab(path: file.path, title: "Note", content: "new", originalContent: "old", isStandalone: false)]
        model.activeTabID = file.path

        await model.closeTab(file.path)

        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(try FileService.read(file), "new")
        XCTAssertTrue(prompts.asked.isEmpty)
    }

    func testStandaloneEditsAreNotAutosavedUntilTheUserSaves() async throws {
        let root = try temporaryDirectory()
        let a = root.appendingPathComponent("A.md")
        let b = root.appendingPathComponent("B.md")
        try "a".write(to: a, atomically: true, encoding: .utf8)
        try "b".write(to: b, atomically: true, encoding: .utf8)
        let model = manualSaveModel(prompts: UnsavedChangesPrompts(decision: .cancel))
        model.tabs = [
            NoteTab(path: a.path, title: "A", content: "a", originalContent: "a", isStandalone: true),
            NoteTab(path: b.path, title: "B", content: "b", originalContent: "b", isStandalone: true)
        ]
        model.activeTabID = a.path

        model.updateContent(a.path, "edited a")
        await model.setActiveTab(b.path)
        model.updateContent(b.path, "edited b")
        await model.awaitPendingSaves()
        await model.flushDirtyTabs()

        XCTAssertEqual(try FileService.read(a), "a")
        XCTAssertEqual(try FileService.read(b), "b")
        XCTAssertTrue(model.tabs.allSatisfy(\.dirty))
        XCTAssertEqual(model.saveCommandTitle, "Save")

        await model.saveActive(sync: true)

        XCTAssertEqual(try FileService.read(b), "edited b")
        XCTAssertEqual(try FileService.read(a), "a")
        XCTAssertFalse(model.tabs[1].dirty)
        XCTAssertTrue(model.tabs[0].dirty)
    }

    func testSavingStandaloneFileBesideAVaultDoesNotSyncTheVault() async throws {
        let vaultRoot = try temporaryDirectory()
        let file = try temporaryDirectory().appendingPathComponent("Loose.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        var settings = AppSettings.default()
        settings.autoSync = true
        var dependencies = disabledAuthDependencies()
        dependencies.authenticationDisabled = { false }
        dependencies.syncGit = { _, _, _ in
            XCTFail("a standalone file is not part of the vault's repository")
            return GitStatus(state: .synced)
        }
        let model = AppModel(settings: settings, bootstrapOnLaunch: false, dependencies: dependencies)
        model.vault = VaultInfo(name: "vault", path: vaultRoot.path, remote: nil, branch: nil, isGitHub: false)
        model.tabs = [NoteTab(path: file.path, title: "Loose", content: "old", originalContent: "old", isStandalone: true)]
        model.activeTabID = file.path

        model.updateContent(file.path, "new")
        await model.awaitPendingSaves()
        XCTAssertEqual(try FileService.read(file), "old")

        await model.saveActive(sync: true)

        XCTAssertEqual(try FileService.read(file), "new")
        XCTAssertFalse(model.tabs[0].dirty)

        model.updateContent(file.path, "newer")
        let savedDirectly = await model.save(id: file.path, sync: true)
        XCTAssertTrue(savedDirectly)
        XCTAssertEqual(try FileService.read(file), "newer")
        XCTAssertFalse(model.tabs[0].dirty)
    }

    func testVaultNoteSaveCommandStillSyncs() {
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        XCTAssertEqual(model.saveCommandTitle, "Save and sync")
        model.tabs = [NoteTab(path: "/vault/Note.md", title: "Note", content: "", originalContent: "", isStandalone: false)]
        model.activeTabID = "/vault/Note.md"
        XCTAssertEqual(model.saveCommandTitle, "Save and sync")
    }

    func testClosingUnsavedStandaloneTabAsksBeforeClosing() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("Note.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let prompts = UnsavedChangesPrompts(decision: .cancel)
        let model = manualSaveModel(prompts: prompts)
        model.tabs = [NoteTab(path: file.path, title: "Note", content: "new", originalContent: "old", isStandalone: true)]
        model.activeTabID = file.path

        await model.closeTab(file.path)

        XCTAssertEqual(prompts.asked, [["Note"]])
        XCTAssertEqual(model.tabs.map(\.content), ["new"])
        XCTAssertEqual(try FileService.read(file), "old")

        prompts.decision = .discard
        await model.closeTab(file.path)

        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(try FileService.read(file), "old")
    }

    func testClosingUnsavedStandaloneTabCanSaveFirst() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("Note.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let prompts = UnsavedChangesPrompts(decision: .save)
        let model = manualSaveModel(prompts: prompts)
        model.tabs = [NoteTab(path: file.path, title: "Note", content: "new", originalContent: "old", isStandalone: true)]
        model.activeTabID = file.path

        await model.closeTab(file.path)

        XCTAssertEqual(prompts.asked, [["Note"]])
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(try FileService.read(file), "new")
    }

    func testClosingCleanStandaloneTabDoesNotAsk() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("Note.md")
        try "same".write(to: file, atomically: true, encoding: .utf8)
        let prompts = UnsavedChangesPrompts(decision: .cancel)
        let model = manualSaveModel(prompts: prompts)
        model.tabs = [NoteTab(path: file.path, title: "Note", content: "same", originalContent: "same", isStandalone: true)]
        model.activeTabID = file.path

        await model.closeTab(file.path)

        XCTAssertTrue(prompts.asked.isEmpty)
        XCTAssertTrue(model.tabs.isEmpty)
    }

    func testFailedSaveFromClosePromptKeepsTheTabOpen() async {
        let path = "/dev/null/Note.md"
        let model = manualSaveModel(prompts: UnsavedChangesPrompts(decision: .save))
        model.tabs = [NoteTab(path: path, title: "Note", content: "new", originalContent: "old", isStandalone: true)]
        model.activeTabID = path

        await model.closeTab(path)

        XCTAssertEqual(model.tabs.map(\.path), [path])
        XCTAssertTrue(model.tabs[0].dirty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testReplacingUnsavedStandaloneTabsAsksOnceForAllOfThem() async throws {
        let root = try temporaryDirectory()
        let a = root.appendingPathComponent("A.md")
        let b = root.appendingPathComponent("B.md")
        let replacement = root.appendingPathComponent("Replacement.md")
        try "a".write(to: a, atomically: true, encoding: .utf8)
        try "b".write(to: b, atomically: true, encoding: .utf8)
        try "replacement".write(to: replacement, atomically: true, encoding: .utf8)
        let prompts = UnsavedChangesPrompts(decision: .cancel)
        let model = manualSaveModel(prompts: prompts)
        model.tabs = [
            NoteTab(path: a.path, title: "A", content: "edited a", originalContent: "a", isStandalone: true),
            NoteTab(path: b.path, title: "B", content: "edited b", originalContent: "b", isStandalone: true)
        ]
        model.activeTabID = a.path

        await model.openStandalone(url: replacement)

        XCTAssertEqual(prompts.asked, [["A", "B"]])
        XCTAssertEqual(model.tabs.map(\.path), [a.path, b.path])
        XCTAssertEqual(try FileService.read(a), "a")

        prompts.decision = .save
        await model.openStandalone(url: replacement)

        XCTAssertEqual(model.tabs.map(\.path), [replacement.path])
        XCTAssertEqual(try FileService.read(a), "edited a")
        XCTAssertEqual(try FileService.read(b), "edited b")
    }

    func testReopeningDirtyStandaloneFileReadsContentAfterSavingIt() async throws {
        let file = try temporaryDirectory().appendingPathComponent("A.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let prompts = UnsavedChangesPrompts(decision: .save)
        let model = manualSaveModel(prompts: prompts)
        model.tabs = [NoteTab(path: file.path, title: "A", content: "edited", originalContent: "old", isStandalone: true)]
        model.activeTabID = file.path

        await model.openStandalone(url: file)

        XCTAssertEqual(prompts.asked, [["A"]])
        XCTAssertEqual(try FileService.read(file), "edited")
        XCTAssertEqual(model.activeTab?.content, "edited")
        XCTAssertEqual(model.activeTab?.originalContent, "edited")
        XCTAssertFalse(try XCTUnwrap(model.activeTab).dirty)
    }

    func testClosingVaultAsksAboutUnsavedStandaloneTabs() async throws {
        let root = try temporaryDirectory()
        let note = root.appendingPathComponent("Note.md")
        let loose = try temporaryDirectory().appendingPathComponent("Loose.md")
        try "note".write(to: note, atomically: true, encoding: .utf8)
        try "loose".write(to: loose, atomically: true, encoding: .utf8)
        let prompts = UnsavedChangesPrompts(decision: .cancel)
        let model = manualSaveModel(prompts: prompts)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        model.tabs = [
            NoteTab(path: note.path, title: "Note", content: "note", originalContent: "note", isStandalone: false),
            NoteTab(path: loose.path, title: "Loose", content: "edited", originalContent: "loose", isStandalone: true)
        ]
        model.activeTabID = note.path

        await model.closeVault()

        XCTAssertEqual(prompts.asked, [["Loose"]])
        XCTAssertNotNil(model.vault)
        XCTAssertEqual(model.tabs.count, 2)

        prompts.decision = .discard
        await model.closeVault()

        XCTAssertNil(model.vault)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertEqual(try FileService.read(loose), "loose")
    }

    func testQuittingFlushesVaultNotesAndAsksAboutStandaloneFiles() async throws {
        let root = try temporaryDirectory()
        let note = root.appendingPathComponent("Note.md")
        let loose = try temporaryDirectory().appendingPathComponent("Loose.md")
        try "note".write(to: note, atomically: true, encoding: .utf8)
        try "loose".write(to: loose, atomically: true, encoding: .utf8)
        let prompts = UnsavedChangesPrompts(decision: .cancel)
        let model = manualSaveModel(prompts: prompts)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        model.tabs = [
            NoteTab(path: note.path, title: "Note", content: "edited note", originalContent: "note", isStandalone: false),
            NoteTab(path: loose.path, title: "Loose", content: "edited loose", originalContent: "loose", isStandalone: true)
        ]

        let cancelled = await model.prepareToTerminate()

        XCTAssertFalse(cancelled)
        XCTAssertEqual(prompts.asked, [["Loose"]])
        XCTAssertEqual(try FileService.read(note), "edited note")
        XCTAssertEqual(try FileService.read(loose), "loose")

        prompts.decision = .save
        let saved = await model.prepareToTerminate()

        XCTAssertTrue(saved)
        XCTAssertEqual(try FileService.read(loose), "edited loose")
    }

    func testQuittingCanDiscardStandaloneChanges() async throws {
        let file = try temporaryDirectory().appendingPathComponent("Loose.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let prompts = UnsavedChangesPrompts(decision: .discard)
        let model = manualSaveModel(prompts: prompts)
        model.tabs = [NoteTab(path: file.path, title: "Loose", content: "edited", originalContent: "old", isStandalone: true)]

        let ready = await model.prepareToTerminate()
        XCTAssertTrue(ready)
        XCTAssertEqual(prompts.asked, [["Loose"]])
        XCTAssertEqual(try FileService.read(file), "old")
    }

    func testProductionUnsavedChangesAlertWordingButtonsAndResponses() {
        let single = UnsavedChangesAlert.make(titles: ["Draft.md"])
        XCTAssertEqual(single.alertStyle, .warning)
        XCTAssertTrue(single.messageText.contains("Draft.md"))
        XCTAssertTrue(single.informativeText.contains("lost"))
        XCTAssertEqual(single.buttons.map(\.title), ["Save", "Don’t Save", "Cancel"])
        XCTAssertEqual(single.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(single.buttons[1].keyEquivalent, "d")
        XCTAssertEqual(single.buttons[1].keyEquivalentModifierMask, .command)
        XCTAssertEqual(single.buttons[2].keyEquivalent, "\u{1b}")

        let multiple = UnsavedChangesAlert.make(titles: ["A.md", "B.md"])
        XCTAssertTrue(multiple.messageText.contains("2 files"))
        XCTAssertTrue(multiple.informativeText.contains("A.md, B.md"))
        XCTAssertEqual(UnsavedChangesAlert.decision(for: .alertFirstButtonReturn), .save)
        XCTAssertEqual(UnsavedChangesAlert.decision(for: .alertSecondButtonReturn), .discard)
        XCTAssertEqual(UnsavedChangesAlert.decision(for: .alertThirdButtonReturn), .cancel)
    }

    func testProductionUnsavedChangesPromptRunsAndCanBeCancelled() {
        DispatchQueue.main.async { NSApp.abortModal() }

        let decision = AppModelDependencies.live.confirmUnsavedChanges(["Draft.md"])

        XCTAssertEqual(decision, .cancel)
    }

    func testNewVaultNoteOpensInSourceModeWithPlaceholderTitleReadyToReplace() async throws {
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
        XCTAssertEqual(model.titleEditingTabID, tab.id)
        XCTAssertEqual(model.titleEditingDraft, "Untitled")
        XCTAssertEqual(model.editorMode, .source)
        XCTAssertEqual(model.centerView, .editor)
        XCTAssertNil(model.editorFocusRequest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tab.path))

        await model.submitTitleEditing(for: tab.id, draft: "Project Notes")

        let renamed = FileService.canonicalURL(root.appendingPathComponent("Project Notes.md"))
        XCTAssertNil(model.titleEditingTabID)
        XCTAssertEqual(
            model.editorFocusRequest.map { FileService.canonicalURL(URL(fileURLWithPath: $0.tabID)).path },
            renamed.path
        )
        XCTAssertEqual(model.editorFocusRequest?.tabID, model.activeTabID)
        XCTAssertEqual(model.editorFocusRequest?.placement, .start)
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

    func testFolderRenameDraftPrefillsCurrentNameAndRenamesOnSubmit() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let model = modelWithVault(at: root)
        await model.refreshVault()
        let node = try XCTUnwrap(model.fileTree.first)
        let draft = FolderRenameDraft()

        draft.begin(node)
        XCTAssertEqual(draft.name, "Drafts")
        XCTAssertEqual(draft.path, node.path)
        XCTAssertTrue(draft.isPresented)

        draft.name = "Published"
        let submission = try XCTUnwrap(draft.submit(into: model))
        XCTAssertEqual(draft.name, "")
        XCTAssertNil(draft.path)
        XCTAssertFalse(draft.isPresented)
        await submission.value

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.fileTree.map(\.name), ["Published"])
        XCTAssertTrue(FileService.directoryExists(at: root.appendingPathComponent("Published").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testFolderRenameDraftCancelDoesNotRename() async throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Keep", isDirectory: true),
            withIntermediateDirectories: false
        )
        let model = modelWithVault(at: root)
        await model.refreshVault()
        let draft = FolderRenameDraft()

        draft.begin(try XCTUnwrap(model.fileTree.first))
        draft.name = "Changed"
        draft.cancel()

        XCTAssertEqual(draft.name, "")
        XCTAssertFalse(draft.isPresented)
        XCTAssertNil(draft.submit(into: model))
        XCTAssertTrue(FileService.directoryExists(at: root.appendingPathComponent("Keep").path))
    }

    func testFolderRowContextMenuStartsRenameWithAlertState() throws {
        let root = try temporaryDirectory()
        let folder = FileNode(name: "Drafts", path: root.appendingPathComponent("Drafts").path, isDirectory: true, children: [])
        let draft = FolderRenameDraft()
        let hostingView = NSHostingView(
            rootView: TreeRow(node: folder, depth: 0, onRenameFolder: draft.begin)
                .environment(modelWithVault(at: root))
                .frame(width: 240, height: 30)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 240, height: 30)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()

        let point = NSPoint(x: 80, y: 15)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let target = hostingView.hitTest(point) ?? hostingView
        let menu = try XCTUnwrap(target.menu(for: event))
        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["New File", "Rename", "Move to Trash…"]
        )

        let renameIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == "Rename" })
        menu.performActionForItem(at: renameIndex)
        XCTAssertEqual(draft.path, folder.path)
        XCTAssertEqual(draft.name, "Drafts")
        XCTAssertTrue(draft.isPresented)
    }

    func testFileExplorerPresentsPrefilledRenameAlert() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let model = modelWithVault(at: root)
        await model.refreshVault()
        let draft = FolderRenameDraft()
        let hostingView = NSHostingView(
            rootView: FileExplorerView(renameDraft: draft)
                .environment(model)
                .frame(width: 300, height: 400)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()

        draft.begin(try XCTUnwrap(model.fileTree.first))
        for _ in 0..<50 where window.attachedSheet == nil {
            await drainMainQueue()
            hostingView.layoutSubtreeIfNeeded()
        }

        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        XCTAssertTrue(containsTextField(value: "Drafts", in: content))
        draft.name = "Published"
        try XCTUnwrap(button(titled: "Rename", in: content)).performClick(nil)
        let destination = root.appendingPathComponent("Published", isDirectory: true)
        for _ in 0..<50 where model.fileTree.map(\.name) != ["Published"] {
            await drainMainQueue()
        }
        XCTAssertTrue(FileService.directoryExists(at: destination.path))
        XCTAssertFalse(FileService.directoryExists(at: folder.path))
        XCTAssertEqual(model.fileTree.map(\.name), ["Published"])
    }

    func testFolderTrashRequestDescribesContentsAndTrashesFolderOnConfirm() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Archive", isDirectory: true)
        let nested = folder.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let child = folder.appendingPathComponent("Plan.md")
        let deep = nested.appendingPathComponent("Deep.md")
        let attachment = nested.appendingPathComponent("diagram.png")
        let outside = root.appendingPathComponent("Keep.md")
        try "plan".write(to: child, atomically: true, encoding: .utf8)
        try "deep".write(to: deep, atomically: true, encoding: .utf8)
        try Data([0x89]).write(to: attachment)
        try "keep".write(to: outside, atomically: true, encoding: .utf8)
        let model = modelWithVault(at: root)
        await model.refreshVault()
        // Tabs keep the path they were opened with, which need not be the tree's canonical path.
        model.tabs = [
            NoteTab(path: deep.path, title: "Deep", content: "edited", originalContent: "deep", isStandalone: false),
            NoteTab(
                path: FileService.canonicalURL(child).path,
                title: "Plan",
                content: "plan",
                originalContent: "plan",
                isStandalone: false
            ),
            NoteTab(path: outside.path, title: "Keep", content: "keep", originalContent: "keep", isStandalone: false)
        ]
        model.activeTabID = deep.path
        let node = try XCTUnwrap(model.fileTree.first { $0.name == "Archive" })
        let request = FolderTrashRequest()

        request.begin(node)
        await request.awaitCount()
        XCTAssertTrue(request.isPresented)
        XCTAssertEqual(request.path, node.path)
        XCTAssertEqual(request.contents?.files, 3)
        XCTAssertEqual(request.contents?.directories, 1)
        XCTAssertEqual(request.title, "Move “Archive” to Trash?")
        XCTAssertEqual(
            request.message,
            "This folder and all 3 files inside it will be moved to the Trash. You can recover it from the macOS Trash."
        )

        let confirmation = try XCTUnwrap(request.confirm(into: model))
        XCTAssertFalse(request.isPresented)
        XCTAssertNil(request.path)
        await confirmation.value

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(model.tabs.map(\.path), [outside.path])
        XCTAssertEqual(model.fileTree.map(\.name), ["Keep.md"])
        XCTAssertFalse(model.notes.contains { $0.title == "Deep" || $0.title == "Plan" })
    }

    func testFolderTrashRequestCancelKeepsFolder() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Keep", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try "note".write(to: folder.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        let model = modelWithVault(at: root)
        await model.refreshVault()
        let request = FolderTrashRequest()

        request.begin(try XCTUnwrap(model.fileTree.first))
        await request.awaitCount()
        XCTAssertEqual(
            request.message,
            "This folder and the 1 file inside it will be moved to the Trash. You can recover it from the macOS Trash."
        )
        request.cancel()

        XCTAssertFalse(request.isPresented)
        XCTAssertNil(request.path)
        XCTAssertNil(request.confirm(into: model))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Note.md").path))
    }

    func testFolderTrashRequestDescribesEmptyFolder() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let request = FolderTrashRequest()

        request.begin(FileNode(name: "Empty", path: folder.path, isDirectory: true, children: []))
        await request.awaitCount()

        XCTAssertEqual(request.contents?.files, 0)
        XCTAssertEqual(request.contents?.directories, 0)
        XCTAssertEqual(
            request.message,
            "This empty folder will be moved to the Trash. You can recover it from the macOS Trash."
        )
    }

    func testFolderTrashRequestDescribesOnlyEmptySubfolders() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Scaffold", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Nested/Empty"),
            withIntermediateDirectories: true
        )
        let request = FolderTrashRequest()

        request.begin(FileNode(name: "Scaffold", path: folder.path, isDirectory: true, children: []))
        await request.awaitCount()

        XCTAssertEqual(request.contents, FileService.FolderContents(files: 0, directories: 2))
        XCTAssertEqual(
            request.message,
            "This folder and its subfolders will be moved to the Trash. You can recover it from the macOS Trash."
        )
    }

    func testFolderTrashRequestStartsWithAccurateGenericMessageWhileCounting() throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let request = FolderTrashRequest()

        request.begin(FileNode(name: "Archive", path: folder.path, isDirectory: true, children: []))

        XCTAssertNil(request.contents)
        XCTAssertEqual(
            request.message,
            "This folder and everything inside it will be moved to the Trash. You can recover it from the macOS Trash."
        )
        request.cancel()
    }

    func testFolderTrashRequestRejectsReplacementAtSamePath() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let model = modelWithVault(at: root)
        let request = FolderTrashRequest()
        request.begin(FileNode(name: "Drafts", path: folder.path, isDirectory: true, children: []))
        let oldFolder = root.appendingPathComponent("OldDrafts", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: oldFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let replacementNote = folder.appendingPathComponent("New.md")
        try "new".write(to: replacementNote, atomically: true, encoding: .utf8)

        try await XCTUnwrap(request.confirm(into: model)).value

        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementNote.path))
        XCTAssertNotNil(model.errorMessage)
    }

    func testFolderRowContextMenuAsksToConfirmMovingFolderToTrash() throws {
        let root = try temporaryDirectory()
        let folderURL = root.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
        let folder = FileNode(name: "Drafts", path: folderURL.path, isDirectory: true, children: [])
        let request = FolderTrashRequest()
        let hostingView = NSHostingView(
            rootView: TreeRow(node: folder, depth: 0, onRenameFolder: { _ in }, onTrashFolder: request.begin)
                .environment(modelWithVault(at: root))
                .frame(width: 240, height: 30)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 240, height: 30)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()

        let point = NSPoint(x: 80, y: 15)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let target = hostingView.hitTest(point) ?? hostingView
        let menu = try XCTUnwrap(target.menu(for: event))
        let trashIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == "Move to Trash…" })
        menu.performActionForItem(at: trashIndex)

        XCTAssertTrue(request.isPresented)
        XCTAssertEqual(request.path, folder.path)
        XCTAssertEqual(request.name, "Drafts")
        XCTAssertTrue(FileService.directoryExists(at: folderURL.path))
    }

    func testFileExplorerConfirmsBeforeMovingFolderToTrash() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try "note".write(to: folder.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        let model = modelWithVault(at: root)
        await model.refreshVault()
        let request = FolderTrashRequest()
        let hostingView = NSHostingView(
            rootView: FileExplorerView(renameDraft: FolderRenameDraft(), trashRequest: request)
                .environment(model)
                .frame(width: 300, height: 400)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()

        request.begin(try XCTUnwrap(model.fileTree.first))
        for _ in 0..<50 where window.attachedSheet == nil {
            await drainMainQueue()
            hostingView.layoutSubtreeIfNeeded()
        }

        // Nothing is trashed until the prompt is confirmed.
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(FileService.directoryExists(at: folder.path))
        let content = try XCTUnwrap(sheet.contentView)
        try XCTUnwrap(button(titled: "Move to Trash", in: content)).performClick(nil)
        for _ in 0..<50 where !model.fileTree.isEmpty {
            await drainMainQueue()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(model.fileTree.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testFolderTrashSavesPendingEditsAndKeepsPrefixSiblingOpen() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Archive", isDirectory: true)
        let sibling = root.appendingPathComponent("Archive2", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        let child = folder.appendingPathComponent("Child.md")
        let siblingNote = sibling.appendingPathComponent("Keep.md")
        try "old".write(to: child, atomically: true, encoding: .utf8)
        try "keep".write(to: siblingNote, atomically: true, encoding: .utf8)
        var settings = AppSettings.default()
        settings.autoSync = false
        var dependencies = AppModelDependencies.live
        var savedBeforeTrash: String?
        dependencies.moveToTrash = { url, vaultRoot, identity in
            savedBeforeTrash = try FileService.read(child)
            try FileService.moveToTrash(url, root: vaultRoot, expectedFolderIdentity: identity)
        }
        let model = AppModel(settings: settings, bootstrapOnLaunch: false, dependencies: dependencies)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.openTab(path: child.path)
        await model.openTab(path: siblingNote.path)
        model.updateContent(child.path, "latest edit")

        await model.deletePath(folder.path)
        await model.awaitPendingSaves()

        XCTAssertEqual(savedBeforeTrash, "latest edit")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.tabs.map(\.path), [siblingNote.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingNote.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testFolderTrashSaveFailureLeavesFolderAndDirtyTabOpen() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let child = folder.appendingPathComponent("Child.md")
        try "old".write(to: child, atomically: true, encoding: .utf8)
        var settings = AppSettings.default()
        settings.autoSync = false
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.openTab(path: child.path)
        model.updateContent(child.path, "latest edit")
        try FileManager.default.removeItem(at: child)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)

        await model.deletePath(folder.path)

        XCTAssertTrue(FileService.directoryExists(at: folder.path))
        XCTAssertEqual(model.tabs.map(\.path), [child.path])
        XCTAssertTrue(try XCTUnwrap(model.tabs.first).dirty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testFolderTrashMoveFailureLeavesTabsOpenAndReportsError() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let child = folder.appendingPathComponent("Child.md")
        try "old".write(to: child, atomically: true, encoding: .utf8)
        var dependencies = AppModelDependencies.live
        dependencies.moveToTrash = { _, _, _ in throw FileServiceError.folderChanged("Archive") }
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.openTab(path: child.path)

        await model.deletePath(folder.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
        XCTAssertEqual(model.tabs.map(\.path), [child.path])
        XCTAssertNotNil(model.errorMessage)
    }

    func testRenameFolderRetargetsOpenTabsAndSavesPendingEdits() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        let nested = folder.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let child = FileService.canonicalURL(folder.appendingPathComponent("Plan.md"))
        let deep = FileService.canonicalURL(nested.appendingPathComponent("Deep.md"))
        let outside = FileService.canonicalURL(root.appendingPathComponent("Projects Old.md"))
        try "plan".write(to: child, atomically: true, encoding: .utf8)
        try "deep".write(to: deep, atomically: true, encoding: .utf8)
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        var settings = AppSettings.default()
        settings.autoSync = false
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.openTab(path: child.path)
        await model.openTab(path: deep.path)
        await model.openTab(path: outside.path)
        await model.setActiveTab(deep.path)
        model.updateContent(deep.path, "edited")

        let renamed = await model.renameFolder(path: folder.path, newName: "Archive")

        XCTAssertTrue(renamed)
        XCTAssertNil(model.errorMessage)
        let archive = FileService.canonicalURL(root.appendingPathComponent("Archive", isDirectory: true))
        let movedChild = archive.appendingPathComponent("Plan.md").path
        let movedDeep = archive.appendingPathComponent("Nested/Deep.md").path
        XCTAssertEqual(Set(model.tabs.map(\.path)), [movedChild, movedDeep, outside.path])
        XCTAssertEqual(model.activeTabID, movedDeep)
        XCTAssertEqual(model.activeTab?.content, "edited")
        XCTAssertFalse(try XCTUnwrap(model.activeTab).dirty)
        await model.awaitPendingSaves()
        XCTAssertEqual(try FileService.read(URL(fileURLWithPath: movedDeep)), "edited")
        XCTAssertEqual(try FileService.read(URL(fileURLWithPath: movedChild)), "plan")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(model.fileTree.map(\.name), ["Archive", "Projects Old.md"])
        XCTAssertTrue(model.notes.contains { $0.path == movedDeep })
    }

    func testRenameFolderCollisionPublishesErrorAndKeepsTabs() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Taken", isDirectory: true),
            withIntermediateDirectories: false
        )
        let child = FileService.canonicalURL(folder.appendingPathComponent("Child.md"))
        try "child".write(to: child, atomically: true, encoding: .utf8)
        let model = modelWithVault(at: root)
        await model.openTab(path: child.path)

        let renamed = await model.renameFolder(path: folder.path, newName: "Taken")

        XCTAssertFalse(renamed)
        XCTAssertEqual(model.errorMessage, FileServiceError.nameTaken("Taken").localizedDescription)
        XCTAssertEqual(model.tabs.map(\.path), [child.path])
        XCTAssertEqual(try FileService.read(child), "child")
    }

    func testRenameFolderRejectsSkippedNameAndKeepsNotesIndexed() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Visible", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let note = folder.appendingPathComponent("Keep.md")
        try "keep".write(to: note, atomically: true, encoding: .utf8)
        let model = modelWithVault(at: root)
        await model.refreshVault()

        for name in ["dist", "out", "node_modules"] {
            let renamed = await model.renameFolder(path: folder.path, newName: name)
            XCTAssertFalse(renamed)
            XCTAssertEqual(model.errorMessage, FileServiceError.invalidRelativePath(name).localizedDescription)
            XCTAssertEqual(model.fileTree.map(\.name), ["Visible"])
            XCTAssertEqual(model.notes.map(\.path), [FileService.canonicalURL(note).path])
            XCTAssertTrue(FileService.directoryExists(at: folder.path))
        }
    }

    func testCaseOnlyFolderRenameRetargetsOpenTab() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let note = folder.appendingPathComponent("Plan.md")
        try "plan".write(to: note, atomically: true, encoding: .utf8)
        let model = modelWithVault(at: root)
        await model.openTab(path: note.path)

        let renamed = await model.renameFolder(path: folder.path, newName: "Projects")
        XCTAssertTrue(renamed)

        let moved = FileService.canonicalURL(root.appendingPathComponent("Projects/Plan.md"))
        XCTAssertEqual(model.activeTabID, moved.path)
        XCTAssertEqual(model.tabs.map(\.path), [moved.path])
        XCTAssertEqual(model.fileTree.map(\.name), ["Projects"])
        XCTAssertEqual(model.notes.map(\.path), [moved.path])
        XCTAssertEqual(try FileService.read(moved), "plan")
    }

    func testRenameFolderStopsWhenPendingTitleCannotCommit() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try "taken".write(to: root.appendingPathComponent("Taken.md"), atomically: true, encoding: .utf8)
        let model = modelWithVault(at: root)
        await model.newNote()
        let tab = try XCTUnwrap(model.activeTab)
        model.updateTitleDraft(for: tab.id, draft: "Taken")

        let renamed = await model.renameFolder(path: folder.path, newName: "Moved")
        XCTAssertFalse(renamed)

        XCTAssertTrue(FileService.directoryExists(at: folder.path))
        XCTAssertFalse(FileService.directoryExists(at: root.appendingPathComponent("Moved").path))
        XCTAssertEqual(model.titleEditingTabID, tab.id)
        XCTAssertEqual(model.titleEditingDraft, "Taken")
    }

    func testRenameFolderStopsWhenDirtyTabCannotBeSaved() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let fileUsedAsParent = folder.appendingPathComponent("Parent.md")
        try "parent".write(to: fileUsedAsParent, atomically: true, encoding: .utf8)
        let unwritablePath = fileUsedAsParent.appendingPathComponent("Child.md").path
        let model = modelWithVault(at: root)
        model.tabs = [NoteTab(path: unwritablePath, title: "Child", content: "new", originalContent: "old", isStandalone: false)]

        let renamed = await model.renameFolder(path: folder.path, newName: "Moved")
        XCTAssertFalse(renamed)

        XCTAssertTrue(FileService.directoryExists(at: folder.path))
        XCTAssertFalse(FileService.directoryExists(at: root.appendingPathComponent("Moved").path))
        XCTAssertEqual(model.tabs.map(\.path), [unwritablePath])
        XCTAssertTrue(try XCTUnwrap(model.tabs.first).dirty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testRenameFolderSyncsTheRenamedVaultWithItsMessage() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var settings = AppSettings.default()
        settings.autoSync = true
        var calls: [(String, String)] = []
        var dependencies = AppModelDependencies.live
        dependencies.authenticationDisabled = { false }
        dependencies.syncGit = { path, message, _ in
            calls.append((path, message))
            return GitStatus(state: .idle)
        }
        let model = AppModel(settings: settings, bootstrapOnLaunch: false, dependencies: dependencies)
        model.vault = VaultInfo(name: "first", path: root.path, remote: nil, branch: nil, isGitHub: false)

        let renamed = await model.renameFolder(path: folder.path, newName: "Moved")
        XCTAssertTrue(renamed)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, root.path)
        XCTAssertEqual(calls.first?.1, "Rename folder Source to Moved")
    }

    func testRenameFolderDoesNotSyncAnotherVaultAfterRefresh() async throws {
        let firstRoot = try temporaryDirectory()
        let secondRoot = try temporaryDirectory()
        let folder = firstRoot.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let snapshotStarted = expectation(description: "Renamed vault snapshot started")
        let gate = TitleSyncGate()
        var settings = AppSettings.default()
        settings.autoSync = true
        var syncPaths: [String] = []
        var dependencies = AppModelDependencies.live
        dependencies.authenticationDisabled = { false }
        dependencies.loadVaultSnapshot = { root in
            snapshotStarted.fulfill()
            await gate.wait()
            return (FileService.tree(at: root), FileService.index(at: root))
        }
        dependencies.syncGit = { path, _, _ in
            syncPaths.append(path)
            return GitStatus(state: .idle)
        }
        let model = AppModel(settings: settings, bootstrapOnLaunch: false, dependencies: dependencies)
        model.vault = VaultInfo(name: "first", path: firstRoot.path, remote: nil, branch: nil, isGitHub: false)

        let rename = Task { await model.renameFolder(path: folder.path, newName: "Moved") }
        await fulfillment(of: [snapshotStarted], timeout: 2)
        model.vault = VaultInfo(name: "second", path: secondRoot.path, remote: nil, branch: nil, isGitHub: false)
        gate.release()

        let renamed = await rename.value
        XCTAssertTrue(renamed)
        XCTAssertTrue(syncPaths.isEmpty)
        XCTAssertEqual(model.vault?.path, secondRoot.path)
        XCTAssertTrue(FileService.directoryExists(at: firstRoot.appendingPathComponent("Moved").path))
    }

    func testRenameFolderIgnoresEmptyAndUnchangedNames() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Same", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let model = modelWithVault(at: root)

        let emptyResult = await model.renameFolder(path: folder.path, newName: "  ")
        let unchangedResult = await model.renameFolder(path: folder.path, newName: " Same ")

        XCTAssertTrue(emptyResult)
        XCTAssertTrue(unchangedResult)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(FileService.directoryExists(at: folder.path))
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

    func testNewNoteInFolderCreatesAndOpensUntitledNoteInsideThatFolder() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Projects/Active", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "taken".write(to: folder.appendingPathComponent("Untitled.md"), atomically: true, encoding: .utf8)
        let model = modelWithVault(at: root)
        model.editorMode = .preview

        await model.newNote(inFolder: folder.path)

        let created = FileService.canonicalURL(folder.appendingPathComponent("Untitled 1.md"))
        let tab = try XCTUnwrap(model.activeTab)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(FileService.canonicalURL(URL(fileURLWithPath: tab.path)).path, created.path)
        XCTAssertEqual(try FileService.read(created), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Untitled.md").path))
        XCTAssertEqual(model.titleEditingTabID, tab.id)
        XCTAssertEqual(model.titleEditingDraft, "Untitled 1")
        XCTAssertEqual(model.editorMode, .source)
        XCTAssertEqual(model.centerView, .editor)
        let projects = try XCTUnwrap(model.fileTree.first { $0.name == "Projects" })
        let active = try XCTUnwrap(projects.children?.first { $0.name == "Active" })
        XCTAssertEqual(Set(active.children?.map(\.name) ?? []), ["Untitled 1.md", "Untitled.md"])

        await model.submitTitleEditing(for: tab.id, draft: "Roadmap")

        let renamed = FileService.canonicalURL(folder.appendingPathComponent("Roadmap.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path))
        XCTAssertEqual(
            model.activeTab.map { FileService.canonicalURL(URL(fileURLWithPath: $0.path)).path },
            renamed.path
        )
    }

    func testNewNoteInFolderWorksWhenVaultIsFilesystemRoot() async throws {
        let folder = try temporaryDirectory()
        var dependencies = disabledAuthDependencies()
        // A real snapshot of / would scan the entire machine; the folder action only
        // needs the selected path to verify this containment edge case.
        dependencies.loadVaultSnapshot = { _ in ([], []) }
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)
        model.vault = VaultInfo(name: "root", path: "/", remote: nil, branch: nil, isGitHub: false)

        await model.newNote(inFolder: folder.path)

        let created = FileService.canonicalURL(folder.appendingPathComponent("Untitled.md"))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.activeTab?.path, created.path)
        XCTAssertEqual(model.titleEditingTabID, created.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
    }

    func testNewNoteInFolderOutsideVaultReportsErrorWithoutCreatingNote() async throws {
        let parent = try temporaryDirectory()
        let root = parent.appendingPathComponent("vault", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let model = modelWithVault(at: root)

        await model.newNote(inFolder: outside.path)

        XCTAssertEqual(
            model.errorMessage,
            FileServiceError.outsideRoot(FileService.canonicalURL(outside).path).localizedDescription
        )
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testNewNoteInDeletedFolderReportsMissingFolder() async throws {
        let root = try temporaryDirectory()
        let model = modelWithVault(at: root)

        await model.newNote(inFolder: root.appendingPathComponent("Gone").path)

        XCTAssertEqual(model.errorMessage, FileServiceError.missingFolder("Gone").localizedDescription)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Gone").path))
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
        XCTAssertEqual(model.titleEditingTabID, secondNewTab.id)
        XCTAssertNil(model.editorFocusRequest)
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

    func testNewNoteCommitsPendingTitleBeforeChoosingNextUntitledName() async throws {
        let root = try temporaryDirectory()
        let model = modelWithVault(at: root)
        await model.newNote()
        let first = try XCTUnwrap(model.activeTab)
        model.updateTitleDraft(for: first.id, draft: "Untitled 1")

        await model.newNote()

        XCTAssertEqual(model.activeTab?.title, "Untitled")
        XCTAssertEqual(model.titleEditingTabID, model.activeTabID)
        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Untitled 1.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Untitled.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Untitled 2.md").path))
    }

    func testFailedPendingTitleLeavesNoUnopenedCreatedNote() async throws {
        let root = try temporaryDirectory()
        try "taken".write(to: root.appendingPathComponent("Taken.md"), atomically: true, encoding: .utf8)
        let model = modelWithVault(at: root)
        await model.newNote()
        let first = try XCTUnwrap(model.activeTab)
        model.updateTitleDraft(for: first.id, draft: "Taken")

        await model.newNote()
        await model.dailyNote()
        await model.followWikiLink("Wiki Target")

        XCTAssertEqual(model.activeTabID, first.id)
        XCTAssertEqual(model.titleEditingTabID, first.id)
        XCTAssertEqual(model.titleEditingDraft, "Taken")
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Untitled 1.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Daily").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Wiki Target.md").path))
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
        await model.dailyNote()
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
        await closeModel.dailyNote()
        let closeTabID = try XCTUnwrap(closeModel.editorFocusRequest?.tabID)

        await closeModel.closeTab(closeTabID)
        XCTAssertNil(closeModel.editorFocusRequest)

        let deleteRoot = try temporaryDirectory()
        let deleteModel = AppModel(settings: .default(), bootstrapOnLaunch: false)
        deleteModel.vault = VaultInfo(name: "delete", path: deleteRoot.path, remote: nil, branch: nil, isGitHub: false)
        await deleteModel.dailyNote()
        let deletePath = try XCTUnwrap(deleteModel.editorFocusRequest?.tabID)

        await deleteModel.deletePath(deletePath)
        XCTAssertNil(deleteModel.editorFocusRequest)
    }

    func testFocusRequestClearsWhenWorkspaceIsClosedRejectedOrReplaced() async throws {
        let closeRoot = try temporaryDirectory()
        let closeModel = AppModel(settings: .default(), bootstrapOnLaunch: false)
        closeModel.vault = VaultInfo(name: "close", path: closeRoot.path, remote: nil, branch: nil, isGitHub: false)
        await closeModel.dailyNote()
        XCTAssertNotNil(closeModel.editorFocusRequest)

        await closeModel.closeVault()
        XCTAssertNil(closeModel.editorFocusRequest)

        let rejectRoot = try temporaryDirectory()
        let rejectModel = AppModel(settings: .default(), bootstrapOnLaunch: false)
        rejectModel.vault = VaultInfo(name: "reject", path: rejectRoot.path, remote: nil, branch: nil, isGitHub: false)
        await rejectModel.dailyNote()
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
        await replaceModel.dailyNote()
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

    func testRenderedNewNoteSelectsTitleSoTypingRenamesAndReturnMovesToDocument() async throws {
        let root = try temporaryDirectory()
        var settings = AppSettings.default()
        settings.autoSync = false
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.newNote()
        let created = try XCTUnwrap(model.activeTab)
        model.updateContent(created.id, "Existing body")
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

        guard let (field, titleEditor) = await waitForInlineRenameEditor(in: hostingView) else {
            return XCTFail("The new note title should take keyboard focus")
        }
        XCTAssertTrue(window.firstResponder === titleEditor)
        XCTAssertEqual(titleEditor.string, "Untitled")
        XCTAssertEqual(titleEditor.selectedRange(), NSRange(location: 0, length: "Untitled".utf16.count))
        XCTAssertEqual(model.titleEditingTabID, created.id)
        XCTAssertNil(model.editorFocusRequest)

        titleEditor.insertText("Meeting Notes", replacementRange: titleEditor.selectedRange())
        let coordinator = try XCTUnwrap(field.delegate as? InlineRenameTextField.Coordinator)
        coordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )
        XCTAssertEqual(model.titleEditingDraft, "Meeting Notes")

        XCTAssertTrue(coordinator.control(
            field,
            textView: titleEditor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        let renamed = FileService.canonicalURL(root.appendingPathComponent("Meeting Notes.md"))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline, !(window.firstResponder is SourceTextView) {
            await Task.yield()
            hostingView.layoutSubtreeIfNeeded()
        }

        let editor = try XCTUnwrap(firstDescendant(of: SourceTextView.self, in: hostingView))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, "Existing body")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertNil(model.titleEditingTabID)
        XCTAssertNil(model.editorFocusRequest)
        XCTAssertEqual(model.activeTab?.title, "Meeting Notes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path))
    }

    func testCancellingNewNoteTitleKeepsItsNameAndFocusesBody() async throws {
        let root = try temporaryDirectory()
        let model = modelWithVault(at: root)
        await model.newNote()
        let original = try XCTUnwrap(model.activeTab)
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

        for empty in [false, true] {
            if empty { await model.newNote() }
            let title = await waitForInlineRenameEditor(in: hostingView)
            let field = try XCTUnwrap(title?.0)
            let editor = try XCTUnwrap(title?.1)
            let path = try XCTUnwrap(model.activeTab?.path)
            let coordinator = try XCTUnwrap(field.delegate as? InlineRenameTextField.Coordinator)
            if empty { field.stringValue = "" }
            XCTAssertTrue(coordinator.control(
                field,
                textView: editor,
                doCommandBy: empty
                    ? #selector(NSResponder.insertNewline(_:))
                    : #selector(NSResponder.cancelOperation(_:))
            ))
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while clock.now < deadline, !(window.firstResponder is SourceTextView) {
                await Task.yield()
                hostingView.layoutSubtreeIfNeeded()
            }
            XCTAssertTrue(window.firstResponder is SourceTextView)
            XCTAssertNil(model.titleEditingTabID)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
        XCTAssertEqual(model.tabs.first?.path, original.path)
    }

    func testSubmittingTitleThatCannotBeUsedKeepsTitleEditingWithoutDocumentFocus() async throws {
        let root = try temporaryDirectory()
        try "taken".write(to: root.appendingPathComponent("Taken.md"), atomically: true, encoding: .utf8)
        var settings = AppSettings.default()
        settings.autoSync = false
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.newNote()
        let tab = try XCTUnwrap(model.activeTab)

        await model.submitTitleEditing(for: tab.id, draft: "Taken")

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.activeTabID, tab.id)
        XCTAssertEqual(model.titleEditingTabID, tab.id)
        XCTAssertEqual(model.titleEditingDraft, "Taken")
        XCTAssertNil(model.editorFocusRequest)
    }

    func testEditorModesDescribeTheirToggles() {
        XCTAssertFalse(EditorMode.preview.isEditable)
        XCTAssertTrue(EditorMode.source.isEditable)
        XCTAssertTrue(EditorMode.raw.isEditable)
        XCTAssertEqual(EditorMode.preview.label, "Reading")
        XCTAssertEqual(EditorMode.source.label, "Source")
        XCTAssertEqual(EditorMode.raw.label, "Raw")

        XCTAssertEqual(EditorMode.preview.togglingReadingView, .source)
        XCTAssertEqual(EditorMode.source.togglingReadingView, .preview)
        XCTAssertEqual(EditorMode.raw.togglingReadingView, .preview)
        XCTAssertEqual(EditorMode.preview.togglingRawMarkdown, .raw)
        XCTAssertEqual(EditorMode.source.togglingRawMarkdown, .raw)
        XCTAssertEqual(EditorMode.raw.togglingRawMarkdown, .source)
    }

    func testSubmittingTitleFocusesTheRawEditor() async throws {
        let root = try temporaryDirectory()
        let note = root.appendingPathComponent("Existing.md")
        try "Existing body".write(to: note, atomically: true, encoding: .utf8)
        var settings = AppSettings.default()
        settings.autoSync = false
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.openTab(path: note.path)
        model.editorMode = .raw

        model.beginEditingTitle(for: note.path)
        await model.submitTitleEditing(for: note.path, draft: "Existing")
        XCTAssertNil(model.titleEditingTabID)
        XCTAssertEqual(model.editorFocusRequest?.tabID, note.path)
        XCTAssertEqual(model.editorFocusRequest?.placement, .start)
        XCTAssertEqual(model.editorMode, .raw)
    }

    func testSubmittingTitleFocusesDocumentStartOnlyWhenTheSourceEditorIsShown() async throws {
        let root = try temporaryDirectory()
        let note = root.appendingPathComponent("Existing.md")
        try "Existing body".write(to: note, atomically: true, encoding: .utf8)
        var settings = AppSettings.default()
        settings.autoSync = false
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.openTab(path: note.path)
        model.editorMode = .preview

        model.beginEditingTitle(for: note.path)
        await model.submitTitleEditing(for: note.path, draft: "Existing")
        XCTAssertNil(model.titleEditingTabID)
        XCTAssertNil(model.editorFocusRequest)

        model.editorMode = .source
        model.beginEditingTitle(for: note.path)
        await model.submitTitleEditing(for: note.path, draft: "Existing")
        XCTAssertNil(model.titleEditingTabID)
        XCTAssertEqual(model.editorFocusRequest?.tabID, note.path)
        XCTAssertEqual(model.editorFocusRequest?.placement, .start)
    }

    func testTitleSubmissionFocusesBeforeDefaultAutoSyncFinishes() async throws {
        let root = try temporaryDirectory()
        let syncStarted = expectation(description: "Rename sync started")
        let syncFinished = expectation(description: "Rename sync finished")
        let gate = TitleSyncGate()
        var dependencies = AppModelDependencies.live
        dependencies.authenticationDisabled = { false }
        dependencies.syncGit = { _, _, _ in
            syncStarted.fulfill()
            await gate.wait()
            syncFinished.fulfill()
            return GitStatus(state: .idle)
        }
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.newNote()
        let original = try XCTUnwrap(model.activeTab)

        await model.submitTitleEditing(for: original.id, draft: "Renamed")
        await fulfillment(of: [syncStarted], timeout: 2)

        let request = try XCTUnwrap(model.editorFocusRequest)
        XCTAssertEqual(request.tabID, model.activeTabID)
        XCTAssertEqual(request.placement, .start)
        model.fulfillEditorFocusRequest(request.id)
        model.updateContent(request.tabID, "Typed while syncing")
        gate.release()
        await fulfillment(of: [syncFinished], timeout: 2)
        XCTAssertNil(model.editorFocusRequest)
        XCTAssertEqual(model.activeTab?.content, "Typed while syncing")
    }

    func testOverlappingTitleSubmissionsFocusOnlyTheLatestRenamedTab() async throws {
        let root = try temporaryDirectory()
        let renameStarted = expectation(description: "Rename started")
        let gate = TitleSyncGate()
        var dependencies = AppModelDependencies.live
        dependencies.renameFile = { source, name, root in
            renameStarted.fulfill()
            await gate.wait()
            return try FileService.rename(source, to: name, root: root)
        }
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.newNote()
        let original = try XCTUnwrap(model.activeTab)

        let first = Task { await model.submitTitleEditing(for: original.id, draft: "First") }
        await fulfillment(of: [renameStarted], timeout: 2)
        let second = Task { await model.submitTitleEditing(for: original.id, draft: "First") }
        await drainMainQueue()
        gate.release()
        await first.value
        await second.value

        XCTAssertEqual(model.activeTab?.title, "First")
        XCTAssertEqual(model.editorFocusRequest?.tabID, model.activeTabID)
        XCTAssertEqual(model.editorFocusRequest?.placement, .start)
        XCTAssertNil(model.titleEditingTabID)
    }

    func testTabSwitchDuringSlowTitleRenameDoesNotStealFocus() async throws {
        let root = try temporaryDirectory()
        let other = root.appendingPathComponent("Other.md")
        try "other".write(to: other, atomically: true, encoding: .utf8)
        let renameStarted = expectation(description: "Rename started")
        let gate = TitleSyncGate()
        var dependencies = AppModelDependencies.live
        dependencies.renameFile = { source, name, root in
            renameStarted.fulfill()
            await gate.wait()
            return try FileService.rename(source, to: name, root: root)
        }
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.openTab(path: other.path)
        await model.newNote()
        let original = try XCTUnwrap(model.activeTab)

        let submission = Task { await model.submitTitleEditing(for: original.id, draft: "Renamed") }
        await fulfillment(of: [renameStarted], timeout: 2)
        let navigation = Task { await model.setActiveTab(other.path) }
        await Task.yield()
        gate.release()
        await submission.value
        await navigation.value

        XCTAssertEqual(model.activeTabID, other.path)
        XCTAssertNil(model.editorFocusRequest)
        XCTAssertNil(model.titleEditingTabID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.md").path))
    }

    func testClosingTabDuringSlowTitleRenameClosesRenamedTab() async throws {
        let root = try temporaryDirectory()
        let renameStarted = expectation(description: "Rename started")
        let gate = TitleSyncGate()
        var dependencies = AppModelDependencies.live
        dependencies.renameFile = { source, name, root in
            renameStarted.fulfill()
            await gate.wait()
            return try FileService.rename(source, to: name, root: root)
        }
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)
        model.vault = VaultInfo(name: "vault", path: root.path, remote: nil, branch: nil, isGitHub: false)
        await model.newNote()
        let original = try XCTUnwrap(model.activeTab)

        let submission = Task { await model.submitTitleEditing(for: original.id, draft: "Renamed") }
        await fulfillment(of: [renameStarted], timeout: 2)
        let closing = Task { await model.closeTab(original.id) }
        await Task.yield()
        gate.release()
        await submission.value
        await closing.value

        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.activeTabID)
        XCTAssertNil(model.editorFocusRequest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed.md").path))
    }

    func testCancelledTitleAndRetargetedStartRequestKeepDocumentFocus() async throws {
        let root = try temporaryDirectory()
        let model = modelWithVault(at: root)
        await model.newNote()
        let original = try XCTUnwrap(model.activeTab)

        model.endEditingTitle(for: original.id)
        let request = try XCTUnwrap(model.editorFocusRequest)
        XCTAssertEqual(request.placement, .start)
        await model.renameNote(path: original.path, newName: "Renamed", sync: false)

        XCTAssertEqual(model.editorFocusRequest?.id, request.id)
        XCTAssertEqual(model.editorFocusRequest?.tabID, model.activeTabID)
        XCTAssertEqual(model.editorFocusRequest?.placement, .start)
    }

    func testInlineRenameReturnUsesSubmitHandlerWhileBlurStillCommits() throws {
        var committed: [String] = []
        var submitted: [String] = []
        var draft = "Untitled"
        let representable = InlineRenameTextField(
            text: Binding(get: { draft }, set: { draft = $0 }),
            font: .systemFont(ofSize: 13),
            onSubmit: { submitted.append($0) },
            onCommit: { committed.append($0) },
            onCancel: { XCTFail("A nonempty name should not cancel") }
        )
        let returnCoordinator = InlineRenameTextField.Coordinator(parent: representable)
        let returnField = InlineRenameNSTextField(string: "  Named  ")
        returnCoordinator.textField = returnField

        XCTAssertTrue(returnCoordinator.control(
            returnField,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        XCTAssertEqual(submitted, ["Named"])
        XCTAssertEqual(committed, [])

        let dismantleRepresentable = InlineRenameTextField(
            text: Binding(get: { draft }, set: { draft = $0 }),
            font: .systemFont(ofSize: 13),
            commitOnDismantle: true,
            onSubmit: { submitted.append($0) },
            onCommit: { committed.append($0) },
            onCancel: { XCTFail("A nonempty name should not cancel") }
        )
        let dismantleCoordinator = InlineRenameTextField.Coordinator(parent: dismantleRepresentable)
        let dismantleField = InlineRenameNSTextField(string: "Left Behind")
        dismantleCoordinator.textField = dismantleField
        dismantleCoordinator.prepareForDismantle()

        XCTAssertEqual(submitted, ["Named"])
        XCTAssertEqual(committed, ["Left Behind"])
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
        for _ in 0..<50 where field.currentEditor() == nil {
            await Task.yield()
            hostingView.layoutSubtreeIfNeeded()
        }
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

    func testNewNoteTitleWinsFocusAfterCommandPaletteFieldDismisses() async throws {
        let root = try temporaryDirectory()
        let model = modelWithVault(at: root)
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
        hostingView.layoutSubtreeIfNeeded()

        let palette = try XCTUnwrap(firstDescendant(of: NSTextField.self, in: hostingView))
        for _ in 0..<50 where palette.currentEditor() == nil {
            await Task.yield()
            hostingView.layoutSubtreeIfNeeded()
        }
        let paletteEditor = try XCTUnwrap(palette.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === paletteEditor)

        let creation = Task { await model.newNote() }
        model.commandOpen = false
        await creation.value
        let title = await waitForInlineRenameEditor(in: hostingView)
        let titleEditor = try XCTUnwrap(title?.1)
        XCTAssertTrue(window.firstResponder === titleEditor)
        XCTAssertEqual(titleEditor.selectedRange(), NSRange(location: 0, length: "Untitled".utf16.count))
        XCTAssertEqual(model.titleEditingTabID, model.activeTabID)
    }

    func testSourceEditorFocusRequestCanPlaceCaretAtDocumentStart() async {
        let requestID = UUID()
        var fulfilled: [UUID] = []
        let coordinator = SourceEditor.Coordinator(onChange: { _ in }, focus: { _ in true })
        let editor = SourceTextView()
        editor.string = "Existing body"
        editor.setSelectedRange(NSRange(location: 4, length: 3))
        coordinator.textView = editor
        coordinator.onFocusRequestFulfilled = { fulfilled.append($0) }

        coordinator.updateFocusRequest(requestID, placement: .start)
        await drainMainQueue()

        XCTAssertEqual(fulfilled, [requestID])
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
    }

    func testSourceEditorMouseFocusRequestPreservesMidDocumentSelection() async {
        let requestID = UUID()
        var fulfilled: [UUID] = []
        let coordinator = SourceEditor.Coordinator(onChange: { _ in }, focus: { _ in true })
        let editor = SourceTextView()
        editor.string = "Existing body"
        let selection = NSRange(location: 4, length: 3)
        editor.setSelectedRange(selection)
        coordinator.textView = editor
        coordinator.onFocusRequestFulfilled = { fulfilled.append($0) }

        coordinator.updateFocusRequest(requestID, placement: .preserveSelection)
        await drainMainQueue()

        XCTAssertEqual(fulfilled, [requestID])
        XCTAssertEqual(editor.selectedRange(), selection)
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

    func testMissingVaultKeepsDirtyStandaloneTabOnCancelAndSavesBeforeClearing() async throws {
        let file = try temporaryDirectory().appendingPathComponent("Loose.md")
        let missing = try temporaryDirectory().appendingPathComponent("MissingVault")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let prompts = UnsavedChangesPrompts(decision: .cancel)
        let model = manualSaveModel(prompts: prompts)
        model.tabs = [NoteTab(path: file.path, title: "Loose", content: "edited", originalContent: "old", isStandalone: true)]
        model.activeTabID = file.path

        await model.openVault(path: missing.path)

        XCTAssertEqual(prompts.asked, [["Loose"]])
        XCTAssertEqual(model.activeTab?.content, "edited")
        XCTAssertEqual(try FileService.read(file), "old")
        XCTAssertTrue(model.inWorkspace)

        prompts.decision = .save
        await model.openVault(VaultInfo(name: "MissingVault", path: missing.path, remote: nil, branch: nil, isGitHub: false))

        XCTAssertEqual(prompts.asked, [["Loose"], ["Loose"]])
        XCTAssertEqual(try FileService.read(file), "edited")
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.vault)
        XCTAssertFalse(model.inWorkspace)
    }

    func testSwitchingVaultKeepsDirtyStandaloneTabOpenAndUnwritten() async throws {
        let previousSettings = SettingsStore.load()
        defer { SettingsStore.save(previousSettings) }
        let firstVault = try temporaryDirectory()
        let secondVault = try temporaryDirectory()
        let loose = try temporaryDirectory().appendingPathComponent("Loose.md")
        try "old".write(to: loose, atomically: true, encoding: .utf8)
        let prompts = UnsavedChangesPrompts(decision: .cancel)
        let model = manualSaveModel(prompts: prompts)
        model.vault = VaultInfo(name: "first", path: firstVault.path, remote: nil, branch: nil, isGitHub: false)
        model.tabs = [NoteTab(path: loose.path, title: "Loose", content: "edited", originalContent: "old", isStandalone: true)]
        model.activeTabID = loose.path

        await model.openVault(VaultInfo(name: "second", path: secondVault.path, remote: nil, branch: nil, isGitHub: false))

        XCTAssertEqual(model.vault?.path, secondVault.path)
        XCTAssertEqual(model.tabs.map(\.path), [loose.path])
        XCTAssertEqual(model.activeTab?.content, "edited")
        XCTAssertTrue(try XCTUnwrap(model.activeTab).dirty)
        XCTAssertEqual(try FileService.read(loose), "old")
        XCTAssertTrue(prompts.asked.isEmpty)
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

    func testRenamingStandaloneFileKeepsUnsavedEditsUnwritten() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("Solo.md")
        try "body".write(to: source, atomically: true, encoding: .utf8)
        let model = manualSaveModel(prompts: UnsavedChangesPrompts(decision: .cancel))
        model.tabs = [NoteTab(path: source.path, title: "Solo", content: "edited", originalContent: "body", isStandalone: true)]
        model.activeTabID = source.path

        await model.renameNote(path: source.path, newName: "Renamed")

        let destination = root.appendingPathComponent("Renamed.md")
        XCTAssertEqual(model.activeTabID, destination.path)
        XCTAssertEqual(try FileService.read(destination), "body")
        XCTAssertTrue(model.activeTab?.dirty == true)

        await model.saveActive(sync: false)

        XCTAssertEqual(try FileService.read(destination), "edited")
    }

    func testRenameStopsWhenDirtyTabCannotBeSaved() async {
        let source = "/dev/null/Unsaved.md"
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        model.tabs = [NoteTab(path: source, title: "Unsaved", content: "new", originalContent: "old", isStandalone: false)]
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

    func testFinderOpenFromWelcomeLoadsFileAsStandaloneTab() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("Readme.md")
        try "# Hello from Finder".write(to: file, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        XCTAssertFalse(model.inWorkspace)

        await model.openExternalFiles([file])

        let tab = try XCTUnwrap(model.activeTab)
        XCTAssertTrue(model.inWorkspace)
        XCTAssertEqual(tab.path, FileService.canonicalURL(file).path)
        XCTAssertEqual(tab.title, "Readme")
        XCTAssertEqual(tab.content, "# Hello from Finder")
        XCTAssertTrue(tab.isStandalone)
        XCTAssertEqual(model.centerView, .editor)
        XCTAssertNil(model.errorMessage)
    }

    func testFinderOpenAddsTabsToAnExistingStandaloneSession() async throws {
        let root = try temporaryDirectory()
        let first = root.appendingPathComponent("First.md")
        let second = root.appendingPathComponent("Second.md")
        try "one".write(to: first, atomically: true, encoding: .utf8)
        try "two".write(to: second, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)

        await model.openExternalFiles([first])
        await model.openExternalFiles([second])
        await model.openExternalFiles([first])

        XCTAssertEqual(model.tabs.map(\.title), ["First", "Second"])
        XCTAssertTrue(model.tabs.allSatisfy(\.isStandalone))
        XCTAssertEqual(model.activeTab?.title, "First")
    }

    func testFinderOpenOfVaultFileOpensItInsideTheVault() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("Notes/Idea.md")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "vault note".write(to: file, atomically: true, encoding: .utf8)
        let model = modelWithVault(at: root)

        await model.openExternalFiles([file])

        XCTAssertEqual(model.vault?.path, root.path)
        let tab = try XCTUnwrap(model.activeTab)
        XCTAssertFalse(tab.isStandalone)
        XCTAssertEqual(tab.path, FileService.canonicalURL(file).path)
        XCTAssertEqual(tab.content, "vault note")
    }

    func testFinderOpenOfFileOutsideTheVaultOpensItStandalone() async throws {
        let vaultRoot = try temporaryDirectory()
        let elsewhere = try temporaryDirectory().appendingPathComponent("Loose.md")
        try "loose".write(to: elsewhere, atomically: true, encoding: .utf8)
        let model = modelWithVault(at: vaultRoot)

        await model.openExternalFiles([elsewhere])

        XCTAssertNil(model.vault)
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(model.activeTab?.content, "loose")
        XCTAssertEqual(model.activeTab?.isStandalone, true)
    }

    func testFinderOpenOfUnreadableOutsideFilePreservesActiveVault() async throws {
        let vaultRoot = try temporaryDirectory()
        let existing = vaultRoot.appendingPathComponent("Existing.md")
        let invalid = try temporaryDirectory().appendingPathComponent("Invalid.md")
        try "original".write(to: existing, atomically: true, encoding: .utf8)
        try Data([0xFF]).write(to: invalid)
        let model = modelWithVault(at: vaultRoot)
        await model.refreshVault()
        let treeNames = model.fileTree.map(\.name)
        let notePaths = model.notes.map(\.path)
        await model.openTab(path: existing.path)
        model.tabs[0].content = "unsaved"
        let originalStatus = GitStatus(state: .idle, message: "Vault status")
        model.gitStatus = originalStatus

        await model.openExternalFiles([invalid])

        XCTAssertEqual(model.vault?.path, vaultRoot.path)
        XCTAssertEqual(model.fileTree.map(\.name), treeNames)
        XCTAssertEqual(model.notes.map(\.path), notePaths)
        XCTAssertEqual(model.tabs.map(\.path), [existing.path])
        XCTAssertEqual(model.activeTabID, existing.path)
        XCTAssertEqual(model.activeTab?.content, "unsaved")
        XCTAssertTrue(model.activeTab?.dirty == true)
        XCTAssertEqual(model.gitStatus?.message, originalStatus.message)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original")
        XCTAssertNotNil(model.errorMessage)
    }

    func testStandalonePanelRouteAlsoPreservesVaultOnUnreadableFile() async throws {
        let vaultRoot = try temporaryDirectory()
        let invalid = try temporaryDirectory().appendingPathComponent("Invalid.md")
        try Data([0xFF]).write(to: invalid)
        let model = modelWithVault(at: vaultRoot)

        await model.openStandalone(url: invalid)

        XCTAssertEqual(model.vault?.path, vaultRoot.path)
        XCTAssertNotNil(model.errorMessage)
    }

    func testFinderMixedBatchKeepsVaultAndEverySelectedTab() async throws {
        let vaultRoot = try temporaryDirectory()
        let existing = vaultRoot.appendingPathComponent("Existing.md")
        let inside = vaultRoot.appendingPathComponent("Inside.md")
        let outside = try temporaryDirectory().appendingPathComponent("Outside.md")
        try "original".write(to: existing, atomically: true, encoding: .utf8)
        try "inside".write(to: inside, atomically: true, encoding: .utf8)
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        let model = modelWithVault(at: vaultRoot)
        await model.openTab(path: existing.path)
        model.tabs[0].content = "unsaved"
        let delegate = VulkanGlassAppDelegate()
        delegate.model = model

        delegate.application(NSApplication.shared, open: [inside, outside])
        await delegate.externalOpenTask?.value

        XCTAssertEqual(model.vault?.path, vaultRoot.path)
        XCTAssertEqual(model.tabs.map(\.title), ["Existing", "Inside", "Outside"])
        XCTAssertEqual(model.tabs.map(\.isStandalone), [false, false, true])
        XCTAssertEqual(model.activeTab?.title, "Outside")
        XCTAssertEqual(model.settings.recentFiles.map(\.path), [FileService.canonicalURL(outside).path])
        XCTAssertTrue(model.tabs[0].dirty)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original")

        let reversed = modelWithVault(at: vaultRoot)
        await reversed.openExternalFiles([outside, inside])
        XCTAssertEqual(reversed.vault?.path, vaultRoot.path)
        XCTAssertEqual(reversed.tabs.map(\.title), ["Outside", "Inside"])
        XCTAssertEqual(reversed.tabs.map(\.isStandalone), [true, false])
        XCTAssertEqual(reversed.settings.recentFiles.map(\.path), [FileService.canonicalURL(outside).path])
    }

    func testFinderOutsideBatchSwitchesOnceAndKeepsEverySelectedTab() async throws {
        let vaultRoot = try temporaryDirectory()
        let existing = vaultRoot.appendingPathComponent("Existing.md")
        let elsewhere = try temporaryDirectory()
        let first = elsewhere.appendingPathComponent("First.md")
        let second = elsewhere.appendingPathComponent("Second.md")
        try "original".write(to: existing, atomically: true, encoding: .utf8)
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)
        let model = modelWithVault(at: vaultRoot)
        await model.openTab(path: existing.path)
        model.tabs[0].content = "saved before switch"

        await model.openExternalFiles([first, second])

        XCTAssertNil(model.vault)
        XCTAssertEqual(model.tabs.map(\.title), ["First", "Second"])
        XCTAssertTrue(model.tabs.allSatisfy(\.isStandalone))
        XCTAssertEqual(model.activeTab?.title, "Second")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "saved before switch")
        XCTAssertNil(model.errorMessage)
    }

    func testFinderOpenIgnoresDirectoriesAndReportsUnreadableFiles() async throws {
        let root = try temporaryDirectory()
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)

        await model.openExternalFiles([root])
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.errorMessage)

        await model.openExternalFiles([root.appendingPathComponent("Missing.md")])
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testAppDelegateQueuesFinderOpensUntilTheModelIsReady() async throws {
        let root = try temporaryDirectory()
        let first = root.appendingPathComponent("Cold.md")
        let second = root.appendingPathComponent("Warm.md")
        try "cold".write(to: first, atomically: true, encoding: .utf8)
        try "warm".write(to: second, atomically: true, encoding: .utf8)
        let delegate = VulkanGlassAppDelegate()
        var windowRequests = 0
        delegate.openMainWindow = { windowRequests += 1 }

        delegate.application(NSApplication.shared, open: [first])
        XCTAssertNil(delegate.externalOpenTask)

        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        delegate.model = model
        await delegate.externalOpenTask?.value
        XCTAssertEqual(model.activeTab?.content, "cold")

        delegate.application(NSApplication.shared, open: [second])
        await delegate.externalOpenTask?.value
        XCTAssertEqual(model.tabs.map(\.title), ["Cold", "Warm"])
        XCTAssertEqual(model.activeTab?.content, "warm")
        XCTAssertEqual(windowRequests, 2)
    }

    func testAppDelegateDefersTerminationAndRepliesAfterUnsavedDecision() async throws {
        let file = try temporaryDirectory().appendingPathComponent("Loose.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let prompts = UnsavedChangesPrompts(decision: .cancel)
        let model = manualSaveModel(prompts: prompts)
        model.tabs = [NoteTab(path: file.path, title: "Loose", content: "edited", originalContent: "old", isStandalone: true)]
        let delegate = VulkanGlassAppDelegate()
        delegate.model = model
        let app = NSApplication.shared

        let cancelledReply = expectation(description: "termination cancelled")
        delegate.replyToTermination = { sender, ready in
            XCTAssertTrue(sender === app)
            XCTAssertFalse(ready)
            cancelledReply.fulfill()
        }
        XCTAssertEqual(delegate.applicationShouldTerminate(app), .terminateLater)
        await fulfillment(of: [cancelledReply], timeout: 2)
        XCTAssertEqual(try FileService.read(file), "old")

        prompts.decision = .discard
        let acceptedReply = expectation(description: "termination accepted")
        delegate.replyToTermination = { _, ready in
            XCTAssertTrue(ready)
            acceptedReply.fulfill()
        }
        XCTAssertEqual(delegate.applicationShouldTerminate(app), .terminateLater)
        await fulfillment(of: [acceptedReply], timeout: 2)
        XCTAssertEqual(prompts.asked, [["Loose"], ["Loose"]])
        XCTAssertEqual(try FileService.read(file), "old")

        model.tabs[0].originalContent = "edited"
        XCTAssertEqual(delegate.applicationShouldTerminate(app), .terminateNow)
    }

    func testAppDelegateBridgeDrainsColdOpenAndRequestsClosedWindowReopen() async throws {
        let root = try temporaryDirectory()
        let first = root.appendingPathComponent("Cold.md")
        let second = root.appendingPathComponent("Reopen.md")
        try "cold".write(to: first, atomically: true, encoding: .utf8)
        try "reopen".write(to: second, atomically: true, encoding: .utf8)
        let delegate = VulkanGlassAppDelegate()
        delegate.application(NSApplication.shared, open: [first])
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        var reopenRequests = 0
        let hostingView = NSHostingView(
            rootView: Text("Bridge")
                .modifier(AppDelegateBridge(
                    appDelegate: delegate,
                    model: model,
                    openWindowOverride: { reopenRequests += 1 }
                ))
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<20 where delegate.model == nil {
            hostingView.layoutSubtreeIfNeeded()
            await drainMainQueue()
        }

        XCTAssertTrue(delegate.model === model)
        await delegate.externalOpenTask?.value
        XCTAssertEqual(model.activeTab?.content, "cold")

        window.close()
        await drainMainQueue()
        delegate.application(NSApplication.shared, open: [second])
        await delegate.externalOpenTask?.value
        XCTAssertEqual(reopenRequests, 1)
        XCTAssertEqual(model.activeTab?.content, "reopen")
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

    func testOpeningStandaloneFileAddsItToRecents() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("Loose Note.md")
        try "loose".write(to: file, atomically: true, encoding: .utf8)
        var settings = AppSettings.default()
        settings.recentVaults = [
            RecentVault(name: "Notes", path: "/tmp/notes", remote: nil, lastOpened: 1)
        ]
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)

        await model.openStandalone(url: file)

        let canonical = FileService.canonicalURL(file).path
        XCTAssertEqual(model.settings.recentFiles.map(\.path), [canonical])
        XCTAssertEqual(model.settings.recentFiles.first?.name, "Loose Note")
        XCTAssertEqual(model.settings.recentItems.map(\.id), ["file:\(canonical)", "vault:/tmp/notes"])
    }

    func testReopeningStandaloneFileMovesItToTheTopWithoutDuplicates() async throws {
        let root = try temporaryDirectory()
        let first = root.appendingPathComponent("First.md")
        let second = root.appendingPathComponent("Second.md")
        try "one".write(to: first, atomically: true, encoding: .utf8)
        try "two".write(to: second, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)

        await model.openExternalFiles([first])
        await model.openExternalFiles([second])
        await model.openExternalFiles([first])

        XCTAssertEqual(model.settings.recentFiles.map(\.name), ["First", "Second"])
    }

    func testFocusingOpenStandaloneTabMovesItsRecentEntryToTheTop() async throws {
        let root = try temporaryDirectory()
        let first = root.appendingPathComponent("First.md")
        let second = root.appendingPathComponent("Second.md")
        try "one".write(to: first, atomically: true, encoding: .utf8)
        try "two".write(to: second, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)

        await model.openTab(path: first.path, standalone: true)
        await model.openTab(path: second.path, standalone: true)
        await model.openTab(path: first.path, standalone: true)

        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(model.activeTabID, first.path)
        XCTAssertEqual(model.settings.recentFiles.map(\.path), [
            FileService.canonicalURL(first).path,
            FileService.canonicalURL(second).path
        ])
    }

    func testRecentFilesEvictTheOldestAfterTwelveEntries() async throws {
        let root = try temporaryDirectory()
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        let files = (0..<13).map { root.appendingPathComponent("Note-\($0).md") }

        for file in files {
            try "body".write(to: file, atomically: true, encoding: .utf8)
            await model.openTab(path: file.path, standalone: true)
        }

        XCTAssertEqual(model.settings.recentFiles.count, 12)
        XCTAssertEqual(
            model.settings.recentFiles.map(\.path),
            files.dropFirst().reversed().map { FileService.canonicalURL($0).path }
        )
    }

    func testOpeningVaultNoteDoesNotAddItToRecentFiles() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("Idea.md")
        try "vault note".write(to: file, atomically: true, encoding: .utf8)
        let model = modelWithVault(at: root)

        await model.openExternalFiles([file])

        XCTAssertFalse(model.tabs.isEmpty)
        XCTAssertTrue(model.settings.recentFiles.isEmpty)
    }

    func testNewStandaloneNoteIsAddedToRecents() async throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("Fresh.md")
        var dependencies = AppModelDependencies.live
        dependencies.chooseNewStandaloneNoteURL = { url }
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false, dependencies: dependencies)

        await model.newNote()

        XCTAssertEqual(model.settings.recentFiles.map(\.path), [FileService.canonicalURL(url).path])
    }

    func testOpenRecentFileOpensItStandalone() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("Recent.md")
        try "# Recent".write(to: file, atomically: true, encoding: .utf8)
        let canonical = FileService.canonicalURL(file).path
        let recent = RecentFile(name: "Recent", path: canonical, lastOpened: 0)
        var settings = AppSettings.default()
        settings.recentFiles = [recent]
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)

        await model.openRecent(.file(recent))

        XCTAssertNil(model.vault)
        XCTAssertTrue(model.inWorkspace)
        XCTAssertEqual(model.activeTab?.content, "# Recent")
        XCTAssertEqual(model.activeTab?.isStandalone, true)
        XCTAssertGreaterThan(model.settings.recentFiles.first?.lastOpened ?? 0, 0)
    }

    func testOpenRecentOfActiveDirtyFilePreservesUnsavedEdit() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("Recent.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let prompts = UnsavedChangesPrompts(decision: .cancel)
        let model = manualSaveModel(prompts: prompts)
        await model.openStandalone(url: file)
        let recent = try XCTUnwrap(model.settings.recentFiles.first)
        model.updateContent(file.path, "new unsaved text")

        await model.openRecent(.file(recent))
        XCTAssertEqual(model.activeTab?.content, "new unsaved text")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old")
        XCTAssertTrue(try XCTUnwrap(model.activeTab).dirty)
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertTrue(prompts.asked.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testStandaloneReplacementOfSameDirtyFileReadsSavedContent() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("Draft.md")
        try "old".write(to: file, atomically: true, encoding: .utf8)
        let prompts = UnsavedChangesPrompts(decision: .save)
        let model = manualSaveModel(prompts: prompts)
        await model.openStandalone(url: file)
        model.updateContent(file.path, "new unsaved text")

        await model.openStandalone(url: file)
        XCTAssertEqual(prompts.asked, [["Draft"]])
        XCTAssertEqual(model.activeTab?.content, "new unsaved text")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new unsaved text")
    }

    func testOpenRecentFileFlushesVaultTabsBeforeSwitchingWorkspaces() async throws {
        let vaultRoot = try temporaryDirectory()
        let note = vaultRoot.appendingPathComponent("Vault.md")
        let file = try temporaryDirectory().appendingPathComponent("Recent.md")
        try "vault".write(to: note, atomically: true, encoding: .utf8)
        try "recent".write(to: file, atomically: true, encoding: .utf8)
        let model = modelWithVault(at: vaultRoot)
        await model.openTab(path: note.path)
        model.updateContent(note.path, "edited vault")
        let recent = RecentFile(name: "Recent", path: file.path, lastOpened: 0)

        await model.openRecent(.file(recent))
        await model.awaitPendingSaves()

        XCTAssertNil(model.vault)
        XCTAssertEqual(model.tabs.map(\.path), [file.path])
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "edited vault")
        XCTAssertEqual(model.activeTab?.content, "recent")
    }

    func testOpenRecentFileReplacesMultipleStandaloneTabsAfterSaving() async throws {
        let root = try temporaryDirectory()
        let first = root.appendingPathComponent("First.md")
        let second = root.appendingPathComponent("Second.md")
        let recentFile = root.appendingPathComponent("Recent.md")
        for file in [first, second, recentFile] {
            try "old".write(to: file, atomically: true, encoding: .utf8)
        }
        let prompts = UnsavedChangesPrompts(decision: .save)
        let model = manualSaveModel(prompts: prompts)
        await model.openTab(path: first.path, standalone: true)
        await model.openTab(path: second.path, standalone: true)
        model.updateContent(first.path, "edited first")
        model.updateContent(second.path, "edited second")

        await model.openRecent(.file(RecentFile(name: "Recent", path: recentFile.path, lastOpened: 0)))
        XCTAssertEqual(prompts.asked, [["First", "Second"]])
        XCTAssertEqual(model.tabs.map(\.path), [recentFile.path])
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "edited first")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "edited second")
    }

    func testOpenRecentVaultOpensTheVault() async throws {
        let root = try temporaryDirectory()
        try "# Welcome".write(to: root.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)

        await model.openRecent(.vault(RecentVault(name: "vault", path: root.path, remote: nil, lastOpened: 0)))

        XCTAssertEqual(model.vault?.path, root.path)
        XCTAssertEqual(model.settings.recentVaults.map(\.path), [root.path])
    }

    func testOpeningMissingRecentFileStaysOnWelcomeAndForgetsIt() async throws {
        let missing = try temporaryDirectory().appendingPathComponent("Gone.md")
        let gone = RecentFile(name: "Gone", path: missing.path, lastOpened: 2)
        let kept = RecentFile(name: "Kept", path: "/tmp/kept.md", lastOpened: 1)
        var settings = AppSettings.default()
        settings.recentFiles = [gone, kept]
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)

        await model.openRecent(.file(gone))

        XCTAssertFalse(model.inWorkspace)
        XCTAssertEqual(model.errorMessage, FileServiceError.missingFile("Gone").localizedDescription)
        XCTAssertEqual(model.settings.recentFiles, [kept])
    }

    func testRecentFileThatBecameDirectoryIsReportedAndForgotten() async throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("Former.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let recent = RecentFile(name: "Former", path: directory.path, lastOpened: 1)
        var settings = AppSettings.default()
        settings.recentFiles = [recent]
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)

        await model.openRecent(.file(recent))

        XCTAssertFalse(model.inWorkspace)
        XCTAssertEqual(model.errorMessage, FileServiceError.missingFile("Former").localizedDescription)
        XCTAssertTrue(model.settings.recentFiles.isEmpty)
    }

    func testRenamingStandaloneFileRetargetsItsRecentEntry() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("Draft.md")
        try "draft".write(to: file, atomically: true, encoding: .utf8)
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        await model.openStandalone(url: file)
        let path = try XCTUnwrap(model.activeTab?.path)

        let renamed = await model.renameNote(path: path, newName: "Final")

        XCTAssertTrue(renamed)
        let dest = FileService.canonicalURL(root.appendingPathComponent("Final.md")).path
        XCTAssertEqual(model.settings.recentFiles.map(\.path), [dest])
        XCTAssertEqual(model.settings.recentFiles.first?.name, "Final")
    }

    func testRemoveAndClearRecents() {
        let vault = RecentVault(name: "Notes", path: "/tmp/notes", remote: nil, lastOpened: 1)
        let file = RecentFile(name: "Loose", path: "/tmp/loose.md", lastOpened: 2)
        var settings = AppSettings.default()
        settings.recentVaults = [vault]
        settings.recentFiles = [file]
        let model = AppModel(settings: settings, bootstrapOnLaunch: false)

        model.removeRecent(.file(file))
        XCTAssertTrue(model.settings.recentFiles.isEmpty)
        XCTAssertEqual(model.settings.recentVaults, [vault])

        model.settings.recentFiles = [file]
        model.clearRecents()
        XCTAssertTrue(model.settings.recentItems.isEmpty)
    }

    func testRecentItemsInterleaveVaultsAndFilesByLastOpened() {
        var settings = AppSettings.default()
        settings.recentVaults = [
            RecentVault(name: "Newest vault", path: "/v/new", remote: nil, lastOpened: 30),
            RecentVault(name: "Old vault", path: "/v/old", remote: nil, lastOpened: 10)
        ]
        settings.recentFiles = [
            RecentFile(name: "Middle file", path: "/f/mid.md", lastOpened: 20),
            RecentFile(name: "Oldest file", path: "/f/old.md", lastOpened: 5)
        ]

        XCTAssertEqual(
            settings.recentItems.map(\.name),
            ["Newest vault", "Middle file", "Old vault", "Oldest file"]
        )
    }

    func testRecentRowsUseDistinctIconsAndDisplayPaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let vault = RecentItem.vault(RecentVault(
            name: "Vault", path: "/tmp/Vault", remote: nil, lastOpened: 1
        ))
        let file = RecentItem.file(RecentFile(
            name: "Note", path: "\(home)/Note.md", lastOpened: 2
        ))

        XCTAssertEqual(vault.symbolName, "folder")
        XCTAssertEqual(file.symbolName, "doc.text")
        XCTAssertEqual(vault.detail, "/tmp/Vault")
        XCTAssertEqual(file.detail, "~/Note.md")
        XCTAssertEqual(file.id, "file:\(home)/Note.md")
    }

    func testWelcomeViewRendersRecentFilesWhenSettingsChange() async throws {
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 680)
        let host = NSHostingView(rootView: WelcomeView().environment(model).frame(width: 1000, height: 680))
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<3 { await drainMainQueue() }
        host.layoutSubtreeIfNeeded()
        let empty = try renderedPNG(of: host)

        model.settings.recentFiles = [
            RecentFile(name: "Visible note", path: "/tmp/Visible.md", lastOpened: 1)
        ]
        for _ in 0..<3 { await drainMainQueue() }
        host.layoutSubtreeIfNeeded()
        let withRecent = try renderedPNG(of: host)

        XCTAssertNotEqual(empty, withRecent)
    }

    func testOpenRecentMenuObservesCombinedItemsAndClearState() {
        let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
        var invalidations = 0
        withObservationTracking {
            _ = model.settings.recentItems
        } onChange: {
            invalidations += 1
        }

        model.settings.recentFiles = [
            RecentFile(name: "Note", path: "/tmp/Note.md", lastOpened: 2)
        ]
        model.settings.recentVaults = [
            RecentVault(name: "Vault", path: "/tmp/Vault", remote: nil, lastOpened: 1)
        ]

        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(model.settings.recentItems.map(\.name), ["Note", "Vault"])
        model.clearRecents()
        XCTAssertTrue(model.settings.recentItems.isEmpty)
    }

    private func renderedPNG(of view: NSView) throws -> Data {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    /// A model whose "save changes?" prompt answers from `prompts` instead of showing an alert.
    private func manualSaveModel(prompts: UnsavedChangesPrompts) -> AppModel {
        var settings = AppSettings.default()
        settings.autoSync = false
        var dependencies = disabledAuthDependencies()
        dependencies.confirmUnsavedChanges = { titles in
            prompts.asked.append(titles)
            return prompts.decision
        }
        return AppModel(settings: settings, bootstrapOnLaunch: false, dependencies: dependencies)
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
private final class TitleSyncGate {
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
    @State private var query = ""

    var body: some View {
        ZStack {
            NoteEditorView()
            if model.commandOpen {
                PaletteSearchField(
                    text: $query,
                    placeholder: "Type a command…",
                    onSubmit: {},
                    onCancel: { model.commandOpen = false }
                )
                    .frame(width: 240)
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

private func containsTextField(value: String, in root: NSView) -> Bool {
    if let field = root as? NSTextField, field.stringValue == value { return true }
    return root.subviews.contains { containsTextField(value: value, in: $0) }
}

private func button(titled title: String, in root: NSView) -> NSButton? {
    if let button = root as? NSButton, button.title == title { return button }
    for subview in root.subviews {
        if let button = button(titled: title, in: subview) { return button }
    }
    return nil
}

/// Records the unsaved-changes prompts a model shows and answers them with `decision`.
@MainActor
private final class UnsavedChangesPrompts {
    var decision: UnsavedChangesDecision
    var asked: [[String]] = []

    init(decision: UnsavedChangesDecision) {
        self.decision = decision
    }
}
