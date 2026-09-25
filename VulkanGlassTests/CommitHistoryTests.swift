import XCTest
@testable import VulkanGlass

final class CommitHistoryGitServiceTests: XCTestCase {
    func testCommitHistoryListsNewestFirstUpToTheLimit() throws {
        let repo = try repository(commits: ["First", "Second", "Third"])

        let all = try GitService.commitHistory(path: repo.url.path)
        XCTAssertEqual(all.map(\.subject), ["Third", "Second", "First"])
        XCTAssertEqual(all.map(\.hash), repo.hashes.reversed())
        XCTAssertEqual(all.first?.author, "Tests")
        XCTAssertTrue(all.first.map { $0.hash.hasPrefix($0.shortHash) } ?? false)

        let limited = try GitService.commitHistory(path: repo.url.path, limit: 2)
        XCTAssertEqual(limited.map(\.subject), ["Third", "Second"])
    }

    func testCommitHistoryIsEmptyForRepositoryWithoutCommits() throws {
        let root = try temporaryDirectory()
        _ = try Shell.git(["init", "-b", "main"], cwd: root)

        XCTAssertEqual(try GitService.commitHistory(path: root.path), [])
    }

    func testCommitHistoryCapsAtOneHundredCommits() throws {
        let root = try temporaryDirectory()
        try initRepository(at: root)
        for index in 0..<105 {
            _ = try Shell.git(["commit", "--allow-empty", "-m", "Commit \(index)"], cwd: root)
        }

        let commits = try GitService.commitHistory(path: root.path)

        XCTAssertEqual(GitService.commitHistoryLimit, 100)
        XCTAssertEqual(commits.count, 100)
        XCTAssertEqual(commits.first?.subject, "Commit 104")
    }

    func testParseLogKeepsSeparatorsInsideSubjects() {
        let output = "abc123\u{1f}abc\u{1f}Ada\u{1f}1700000000\u{1f}Fix\u{1f}it\u{1e}\n"
            + "def456\u{1f}def\u{1f}Bob\u{1f}1600000000\u{1f}\u{1e}"

        let commits = GitService.parseLog(output)

        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].subject, "Fix\u{1f}it")
        XCTAssertEqual(commits[0].date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(commits[1].subject, "")
    }

    func testCheckoutHistoryDetachesAtCommitAndKeepsBranchHistory() throws {
        let repo = try repository(commits: ["First", "Second", "Third"])

        let checkout = try XCTUnwrap(
            GitService.checkoutHistory(path: repo.url.path, commit: repo.hashes[0], message: "Save")
        )

        XCTAssertEqual(checkout.branch, "main")
        XCTAssertEqual(checkout.commit.hash, repo.hashes[0])
        XCTAssertEqual(checkout.commit.subject, "First")
        XCTAssertEqual(try note(in: repo.url), "First")
        XCTAssertThrowsError(try Shell.git(["symbolic-ref", "-q", "HEAD"], cwd: repo.url))
        XCTAssertEqual(try Shell.git(["rev-parse", "main"], cwd: repo.url), repo.hashes[2])
        XCTAssertEqual(GitService.historyState(path: repo.url.path), checkout)
        XCTAssertEqual(try GitService.commitHistory(path: repo.url.path).map(\.subject), ["Third", "Second", "First"])
    }

    func testCheckoutHistoryCommitsPendingEditsBeforeLeavingTheBranch() throws {
        let repo = try repository(commits: ["First", "Second"])
        try "Draft".write(to: repo.url.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)

        _ = try GitService.checkoutHistory(path: repo.url.path, commit: repo.hashes[0], message: "Save draft")

        XCTAssertEqual(try note(in: repo.url), "First")
        XCTAssertEqual(try Shell.git(["log", "-1", "--format=%s", "main"], cwd: repo.url), "Save draft")
        XCTAssertEqual(try Shell.git(["show", "main:Note.md"], cwd: repo.url), "Draft")
    }

    func testCheckingOutTheNewestCommitReturnsToTheBranch() throws {
        let repo = try repository(commits: ["First", "Second"])
        _ = try GitService.checkoutHistory(path: repo.url.path, commit: repo.hashes[0], message: "Save")

        let result = try GitService.checkoutHistory(path: repo.url.path, commit: repo.hashes[1], message: "Save")

        XCTAssertNil(result)
        XCTAssertEqual(try Shell.git(["symbolic-ref", "--short", "HEAD"], cwd: repo.url), "main")
        XCTAssertNil(GitService.historyState(path: repo.url.path))
        XCTAssertEqual(try note(in: repo.url), "Second")
    }

    func testReturnToLatestKeepsEveryCommit() throws {
        let repo = try repository(commits: ["First", "Second"])
        _ = try GitService.checkoutHistory(path: repo.url.path, commit: repo.hashes[0], message: "Save")

        try GitService.returnToLatest(path: repo.url.path)

        XCTAssertEqual(try Shell.git(["symbolic-ref", "--short", "HEAD"], cwd: repo.url), "main")
        XCTAssertEqual(try Shell.git(["rev-parse", "HEAD"], cwd: repo.url), repo.hashes[1])
        XCTAssertEqual(try note(in: repo.url), "Second")
        XCTAssertNil(GitService.historyState(path: repo.url.path))
    }

    func testResetToHistoryDiscardsLaterCommitsLocally() throws {
        let repo = try repository(commits: ["First", "Second", "Third"])
        _ = try GitService.checkoutHistory(path: repo.url.path, commit: repo.hashes[1], message: "Save")

        try GitService.resetToHistory(path: repo.url.path)

        XCTAssertEqual(try Shell.git(["symbolic-ref", "--short", "HEAD"], cwd: repo.url), "main")
        XCTAssertEqual(try Shell.git(["rev-parse", "HEAD"], cwd: repo.url), repo.hashes[1])
        XCTAssertEqual(try GitService.commitHistory(path: repo.url.path).map(\.subject), ["Second", "First"])
        XCTAssertEqual(try note(in: repo.url), "Second")
        XCTAssertNil(GitService.historyState(path: repo.url.path))
        // Without a remote there is nothing to force-push.
        XCTAssertFalse(GitService.hasPendingForcePush(at: repo.url))
    }

    func testResetRequiresHistoryMode() throws {
        let repo = try repository(commits: ["First"])

        XCTAssertThrowsError(try GitService.resetToHistory(path: repo.url.path)) { error in
            XCTAssertEqual(error as? GitServiceError, .notViewingHistory)
        }
    }

    func testSyncRefusesWhileViewingHistory() throws {
        let pair = try connectedRepositories(commits: ["First", "Second"])
        _ = try GitService.checkoutHistory(path: pair.local.path, commit: pair.hashes[0], message: "Save")

        XCTAssertThrowsError(try GitService.sync(path: pair.local.path, message: "Save", credential: nil)) { error in
            XCTAssertEqual(error as? GitServiceError, .historyCheckedOut)
        }
        XCTAssertThrowsError(try GitService.pull(path: pair.local.path, credential: nil)) { error in
            XCTAssertEqual(error as? GitServiceError, .historyCheckedOut)
        }
    }

    func testResetIsForcePushedOnNextSyncInsteadOfPulledBack() throws {
        let pair = try connectedRepositories(commits: ["First", "Second", "Third"])
        _ = try GitService.checkoutHistory(path: pair.local.path, commit: pair.hashes[0], message: "Save")
        try GitService.resetToHistory(path: pair.local.path)
        XCTAssertTrue(GitService.hasPendingForcePush(at: pair.local))

        // Opening the vault pulls; that must not restore the discarded commits.
        let pulled = try GitService.pull(path: pair.local.path, credential: nil)
        XCTAssertEqual(pulled.message, "Reset not yet synced")
        XCTAssertEqual(try Shell.git(["rev-parse", "HEAD"], cwd: pair.local), pair.hashes[0])

        let status = try GitService.sync(path: pair.local.path, message: "Reset", credential: nil)

        XCTAssertEqual(status.state, .synced)
        XCTAssertFalse(GitService.hasPendingForcePush(at: pair.local))
        XCTAssertEqual(try Shell.git(["rev-parse", "main"], cwd: pair.remote), pair.hashes[0])
        XCTAssertEqual(try Shell.git(["rev-parse", "HEAD"], cwd: pair.local), pair.hashes[0])
    }

    func testForcePushRefusesWhenTheRemoteMovedSinceTheReset() throws {
        let pair = try connectedRepositories(commits: ["First", "Second"])
        _ = try GitService.checkoutHistory(path: pair.local.path, commit: pair.hashes[0], message: "Save")
        try GitService.resetToHistory(path: pair.local.path)
        let peer = try temporaryDirectory()
        _ = try Shell.git(["clone", pair.remote.path, "."], cwd: peer)
        _ = try Shell.git(["config", "user.name", "Peer"], cwd: peer)
        _ = try Shell.git(["config", "user.email", "peer@example.com"], cwd: peer)
        _ = try Shell.git(["commit", "--allow-empty", "-m", "Peer work"], cwd: peer)
        _ = try Shell.git(["push", "origin", "main"], cwd: peer)
        let peerTip = try Shell.git(["rev-parse", "HEAD"], cwd: peer)

        XCTAssertThrowsError(try GitService.sync(path: pair.local.path, message: "Reset", credential: nil))
        XCTAssertEqual(try Shell.git(["rev-parse", "main"], cwd: pair.remote), peerTip)
    }

    // MARK: Helpers

    private func repository(commits: [String]) throws -> (url: URL, hashes: [String]) {
        let root = try temporaryDirectory()
        try initRepository(at: root)
        return (root, try commit(commits, in: root))
    }

    private func connectedRepositories(commits: [String]) throws -> (local: URL, remote: URL, hashes: [String]) {
        let remote = try temporaryDirectory()
        _ = try Shell.git(["init", "--bare", "-b", "main"], cwd: remote)
        let local = try temporaryDirectory()
        try initRepository(at: local)
        let hashes = try commit(commits, in: local)
        _ = try Shell.git(["remote", "add", "origin", remote.path], cwd: local)
        _ = try Shell.git(["push", "-u", "origin", "main"], cwd: local)
        return (local, remote, hashes)
    }

    private func initRepository(at root: URL) throws {
        _ = try Shell.git(["init", "-b", "main"], cwd: root)
        _ = try Shell.git(["config", "user.name", "Tests"], cwd: root)
        _ = try Shell.git(["config", "user.email", "tests@example.com"], cwd: root)
    }

    private func commit(_ messages: [String], in root: URL) throws -> [String] {
        try messages.map { message in
            try message.write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
            _ = try Shell.git(["add", "--all"], cwd: root)
            _ = try Shell.git(["commit", "-m", message], cwd: root)
            return try Shell.git(["rev-parse", "HEAD"], cwd: root)
        }
    }

    private func note(in root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent("Note.md"), encoding: .utf8)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

@MainActor
final class CommitHistoryModelTests: XCTestCase {
    func testCheckingOutAnEarlierCommitMakesTheVaultReadOnly() async throws {
        let repo = try vaultRepository()
        let model = try await openedModel(at: repo.url)
        await model.openTab(path: repo.url.appendingPathComponent("Later.md").path)
        await model.loadCommitHistory()
        XCTAssertEqual(model.commitHistory.map(\.subject), ["Add later note", "Edit welcome", "Initial"])

        await model.checkoutCommit(repo.hashes[0])

        let checkout = try XCTUnwrap(model.historyCheckout)
        XCTAssertTrue(model.isReadOnly)
        XCTAssertEqual(checkout.commit.hash, repo.hashes[0])
        XCTAssertEqual(model.checkedOutCommitHash, repo.hashes[0])
        XCTAssertEqual(model.vault?.branch, "main")
        XCTAssertEqual(model.commitHistory.count, 3)
        // The open note shows the older text; a note that did not exist yet closes.
        XCTAssertEqual(model.tabs.map(\.title), ["Welcome"])
        XCTAssertEqual(model.activeTab?.content, "# Welcome v1")
        XCTAssertFalse(model.notes.contains { $0.title == "Later" })
        XCTAssertNil(model.busyMessage)

        // Nothing can be edited.
        model.editorMode = .source
        XCTAssertEqual(model.editorMode, .preview)
        let welcome = try XCTUnwrap(model.activeTab)
        model.updateContent(welcome.id, "typed")
        XCTAssertEqual(model.activeTab?.content, "# Welcome v1")
        model.beginEditingTitle(for: welcome.id)
        XCTAssertNil(model.titleEditingTabID)
        await model.newNote()
        XCTAssertEqual(model.errorMessage, AppModel.readOnlyMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("Untitled.md").path))
        model.errorMessage = nil
        await model.dailyNote()
        XCTAssertEqual(model.errorMessage, AppModel.readOnlyMessage)
        XCTAssertFalse(model.canMoveNote(welcome.path, toFolder: repo.url.appendingPathComponent("Daily").path))
    }

    func testReturningToLatestRestoresEditing() async throws {
        let repo = try vaultRepository()
        let model = try await openedModel(at: repo.url)
        await model.loadCommitHistory()
        await model.checkoutCommit(repo.hashes[0])
        XCTAssertTrue(model.isReadOnly)

        await model.returnToLatestCommit()

        XCTAssertFalse(model.isReadOnly)
        XCTAssertEqual(model.activeTab?.content, "# Welcome v2")
        XCTAssertEqual(model.commitHistory.count, 3)
        XCTAssertEqual(try Shell.git(["symbolic-ref", "--short", "HEAD"], cwd: repo.url), "main")
        model.editorMode = .source
        XCTAssertEqual(model.editorMode, .source)
    }

    func testSelectingTheLatestCommitFromHistoryReturnsToTheBranch() async throws {
        let repo = try vaultRepository()
        let model = try await openedModel(at: repo.url)
        await model.loadCommitHistory()
        await model.checkoutCommit(repo.hashes[0])

        await model.checkoutCommit(repo.hashes[2])

        XCTAssertFalse(model.isReadOnly)
        XCTAssertEqual(model.activeTab?.content, "# Welcome v2")
    }

    func testDecliningTheResetKeepsHistoryMode() async throws {
        let repo = try vaultRepository()
        var prompts: [(GitCommit, Bool)] = []
        let model = try await openedModel(at: repo.url) { commit, hasRemote in
            prompts.append((commit, hasRemote))
            return false
        }
        await model.loadCommitHistory()
        await model.checkoutCommit(repo.hashes[1])

        await model.resetToHistoryCommit()

        XCTAssertEqual(prompts.map(\.0.hash), [repo.hashes[1]])
        XCTAssertEqual(prompts.first?.1, false)
        XCTAssertTrue(model.isReadOnly)
        XCTAssertEqual(try Shell.git(["rev-parse", "main"], cwd: repo.url), repo.hashes[2])
    }

    func testConfirmedResetDiscardsLaterCommitsAndRestoresEditing() async throws {
        let repo = try vaultRepository()
        let model = try await openedModel(at: repo.url) { _, _ in true }
        await model.loadCommitHistory()
        await model.checkoutCommit(repo.hashes[0])

        await model.resetToHistoryCommit()

        XCTAssertFalse(model.isReadOnly)
        XCTAssertEqual(model.commitHistory.map(\.subject), ["Initial"])
        XCTAssertEqual(model.checkedOutCommitHash, repo.hashes[0])
        XCTAssertEqual(try Shell.git(["rev-parse", "main"], cwd: repo.url), repo.hashes[0])
        XCTAssertEqual(try Shell.git(["symbolic-ref", "--short", "HEAD"], cwd: repo.url), "main")
        XCTAssertEqual(model.activeTab?.content, "# Welcome v1")

        // Editing resumes from the reset commit.
        model.editorMode = .source
        let welcome = try XCTUnwrap(model.activeTab)
        model.updateContent(welcome.id, "# Welcome v3")
        await model.awaitPendingSaves()
        XCTAssertEqual(
            try String(contentsOf: repo.url.appendingPathComponent("Welcome.md"), encoding: .utf8),
            "# Welcome v3"
        )
    }

    func testReopeningAVaultLeftInHistoryModeStaysReadOnly() async throws {
        let repo = try vaultRepository()
        _ = try GitService.checkoutHistory(path: repo.url.path, commit: repo.hashes[1], message: "Save")

        let model = try await openedModel(at: repo.url)

        XCTAssertEqual(model.historyCheckout?.commit.hash, repo.hashes[1])
        XCTAssertEqual(model.historyCheckout?.branch, "main")
        XCTAssertEqual(model.vault?.branch, "main")
        XCTAssertEqual(model.gitStatus?.message, "Viewing \(repo.hashes[1].prefix(7))")
        XCTAssertEqual(model.editorMode, .preview)

        await model.closeVault()
        XCTAssertNil(model.historyCheckout)
        XCTAssertTrue(model.commitHistory.isEmpty)
    }

    // MARK: Helpers

    /// Welcome.md at v1, then v2, then a second note added.
    private func vaultRepository() throws -> (url: URL, hashes: [String]) {
        let root = try temporaryDirectory()
        _ = try Shell.git(["init", "-b", "main"], cwd: root)
        _ = try Shell.git(["config", "user.name", "Tests"], cwd: root)
        _ = try Shell.git(["config", "user.email", "tests@example.com"], cwd: root)
        _ = try Shell.git(["config", "core.abbrev", "7"], cwd: root)
        var hashes: [String] = []
        func commit(_ message: String) throws {
            _ = try Shell.git(["add", "--all"], cwd: root)
            _ = try Shell.git(["commit", "-m", message], cwd: root)
            hashes.append(try Shell.git(["rev-parse", "HEAD"], cwd: root))
        }
        try "# Welcome v1".write(to: root.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)
        try commit("Initial")
        try "# Welcome v2".write(to: root.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)
        try commit("Edit welcome")
        try "# Later".write(to: root.appendingPathComponent("Later.md"), atomically: true, encoding: .utf8)
        try commit("Add later note")
        return (root, hashes)
    }

    private func openedModel(
        at root: URL,
        confirmReset: @escaping @MainActor (GitCommit, Bool) -> Bool = { _, _ in false }
    ) async throws -> AppModel {
        var settings = AppSettings.default()
        settings.autoSync = false
        var dependencies = AppModelDependencies(
            githubCLIStatus: { _ in GitHubCLIStatus() },
            githubUser: { _ in throw GitHubError.noToken },
            githubRepos: { _ in [] },
            loadKeychainToken: { nil },
            saveKeychainToken: { _ in },
            authenticationDisabled: { true }
        )
        dependencies.confirmHistoryReset = confirmReset
        let model = AppModel(settings: settings, bootstrapOnLaunch: false, dependencies: dependencies)
        await model.openVault(path: root.path)
        XCTAssertEqual(model.activeTab?.title, "Welcome")
        return model
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
