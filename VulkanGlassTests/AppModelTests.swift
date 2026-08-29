import XCTest
@testable import VulkanGlass

@MainActor
final class AppModelTests: XCTestCase {
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
        model.setActiveTab(b.path)
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

        await model.renameNote(path: source.path, newName: "Hello")

        let dest = FileService.canonicalURL(root.appendingPathComponent("Hello.md"))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(
            model.activeTabID.map { FileService.canonicalURL(URL(fileURLWithPath: $0)).path },
            dest.path
        )
        XCTAssertEqual(model.tabs.first?.title, "Hello")
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
}
