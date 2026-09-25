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

    func testResetWithoutUpstreamStillPublishesInsteadOfPullingOldCommits() throws {
        let pair = try connectedRepositories(commits: ["First", "Second"])
        _ = try Shell.git(["branch", "--unset-upstream", "main"], cwd: pair.local)
        _ = try GitService.checkoutHistory(path: pair.local.path, commit: pair.hashes[0], message: "Save")

        try GitService.resetToHistory(path: pair.local.path)
        XCTAssertTrue(GitService.hasPendingForcePush(at: pair.local))
        _ = try GitService.sync(path: pair.local.path, message: "Reset", credential: nil)

        XCTAssertEqual(try Shell.git(["rev-parse", "main"], cwd: pair.remote), pair.hashes[0])
        XCTAssertFalse(GitService.hasPendingForcePush(at: pair.local))
    }

    func testPendingResetCannotForcePushAnotherBranch() throws {
        let pair = try connectedRepositories(commits: ["First", "Second"])
        _ = try Shell.git(["checkout", "-b", "other"], cwd: pair.local)
        _ = try Shell.git(["push", "-u", "origin", "other"], cwd: pair.local)
        let otherTip = try Shell.git(["rev-parse", "other"], cwd: pair.local)
        _ = try Shell.git(["checkout", "main"], cwd: pair.local)
        _ = try GitService.checkoutHistory(path: pair.local.path, commit: pair.hashes[0], message: "Save")
        try GitService.resetToHistory(path: pair.local.path)
        _ = try Shell.git(["checkout", "other"], cwd: pair.local)

        XCTAssertThrowsError(try GitService.sync(path: pair.local.path, message: "Save", credential: nil)) { error in
            XCTAssertEqual(error as? GitServiceError, .resetPendingOnOtherBranch("main"))
        }
        XCTAssertEqual(try Shell.git(["rev-parse", "other"], cwd: pair.remote), otherTip)
        XCTAssertTrue(GitService.hasPendingForcePush(at: pair.local))
        _ = try Shell.git(["checkout", "main"], cwd: pair.local)
        _ = try GitService.sync(path: pair.local.path, message: "Reset", credential: nil)
        XCTAssertEqual(try Shell.git(["rev-parse", "main"], cwd: pair.remote), pair.hashes[0])
    }

    func testLegacyBooleanResetMarkerNeverForcePushesCurrentBranch() throws {
        let pair = try connectedRepositories(commits: ["First", "Second"])
        _ = try Shell.git(["config", GitService.pendingForcePushKey, "true"], cwd: pair.local)

        XCTAssertThrowsError(try GitService.sync(path: pair.local.path, message: "Save", credential: nil)) { error in
            XCTAssertEqual(error as? GitServiceError, .legacyResetPending)
        }
        XCTAssertFalse(GitService.hasPendingForcePush(at: pair.local))
        XCTAssertEqual(try Shell.git(["rev-parse", "main"], cwd: pair.remote), pair.hashes[1])
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

        XCTAssertThrowsError(try GitService.sync(path: pair.local.path, message: "Reset", credential: nil)) { error in
            XCTAssertEqual(error as? GitServiceError, .resetRejected)
        }
        XCTAssertEqual(try Shell.git(["rev-parse", "main"], cwd: pair.remote), peerTip)
        XCTAssertFalse(GitService.hasPendingForcePush(at: pair.local))
        _ = try GitService.pull(path: pair.local.path, credential: nil)
        _ = try GitService.sync(path: pair.local.path, message: "Save", credential: nil)
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

    func testHistoryModeRejectsFolderNoteDeleteAndSyncMutations() async throws {
        let repo = try vaultRepository()
        let folder = repo.url.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = try await openedModel(at: repo.url)
        await model.checkoutCommit(repo.hashes[0])
        let status = model.gitStatus

        await model.createFolder(name: "New Folder")
        let renamedFolder = await model.renameFolder(path: folder.path, newName: "Moved")
        let renamedNote = await model.renameNote(path: repo.url.appendingPathComponent("Welcome.md").path, newName: "Renamed")
        XCTAssertFalse(renamedFolder)
        XCTAssertFalse(renamedNote)
        await model.deletePath(repo.url.appendingPathComponent("Welcome.md").path)
        await model.syncNow()

        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("New Folder").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("Welcome.md").path))
        XCTAssertEqual(model.gitStatus?.message, status?.message)
    }

    func testHistoryWikiLinkOpensExistingOnlyInRequestedGroup() async throws {
        let repo = try vaultRepository()
        let model = try await openedModel(at: repo.url)
        await model.checkoutCommit(repo.hashes[0])
        // Create a second pane using a standalone file, then request the existing note there.
        let outside = try temporaryDirectory().appendingPathComponent("Outside.md")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        await model.openExternalFiles([repo.url.appendingPathComponent("Welcome.md"), outside])
        model.splitActiveTab(.trailing)
        let destination = model.tabGroupLayout.focusedGroupID
        await model.followWikiLink("Welcome", inGroup: destination)
        let welcome = try XCTUnwrap(model.tabs.first { $0.title == "Welcome" })
        XCTAssertEqual(model.tabGroupLayout.groupID(containing: welcome.id), destination)

        await model.followWikiLink("Missing")
        XCTAssertEqual(model.errorMessage, AppModel.readOnlyMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("Missing.md").path))
    }

    func testStandaloneTabCanEditWhileVaultShowsHistory() async throws {
        let repo = try vaultRepository()
        let model = try await openedModel(at: repo.url)
        await model.checkoutCommit(repo.hashes[0])
        let outside = try temporaryDirectory().appendingPathComponent("Outside.md")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        await model.openExternalFiles([repo.url.appendingPathComponent("Welcome.md"), outside])

        XCTAssertEqual(model.activeTab?.path, FileService.canonicalURL(outside).path)
        model.editorMode = .source
        XCTAssertEqual(model.editorMode, .source)
        let tab = try XCTUnwrap(model.activeTab)
        model.updateContent(tab.id, "edited")
        await model.saveActive(sync: false)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "edited")
    }

    func testVaultWritesStayLockedDuringCheckoutAndReturn() async throws {
        let repo = try vaultRepository()
        let gate = HistoryGate()
        let checkoutStarted = expectation(description: "checkout started")
        let model = try await modelWithDependencies(at: repo.url) { dependencies in
            dependencies.checkoutHistory = { path, hash, message in
                checkoutStarted.fulfill()
                await gate.pause()
                return try GitService.checkoutHistory(path: path, commit: hash, message: message)
            }
        }
        let tab = try XCTUnwrap(model.activeTab)
        let checkout = Task { await model.checkoutCommit(repo.hashes[0]) }
        await fulfillment(of: [checkoutStarted], timeout: 5)
        XCTAssertTrue(model.historyTransitionInProgress)
        model.updateContent(tab.id, "bad edit")
        let savedDuringCheckout = await model.save(id: tab.id, sync: false)
        XCTAssertFalse(savedDuringCheckout)
        await model.newNote()
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("Untitled.md").path))
        gate.release()
        await checkout.value
        XCTAssertEqual(model.activeTab?.content, "# Welcome v1")

        let returnGate = HistoryGate()
        let returnStarted = expectation(description: "return started")
        // A second model lets the return dependency be injected before it opens the vault.
        let returning = try await modelWithDependencies(at: repo.url) { dependencies in
            dependencies.returnToLatest = { path in
                returnStarted.fulfill()
                await returnGate.pause()
                try GitService.returnToLatest(path: path)
            }
        }
        let older = try XCTUnwrap(returning.activeTab)
        let returnTask = Task { await returning.returnToLatestCommit() }
        await fulfillment(of: [returnStarted], timeout: 5)
        returning.updateContent(older.id, "bad edit")
        let savedDuringReturn = await returning.save(id: older.id, sync: false)
        XCTAssertFalse(savedDuringReturn)
        returnGate.release()
        await returnTask.value
        XCTAssertEqual(returning.activeTab?.content, "# Welcome v2")
    }

    func testReopeningHistoryLocksVaultBeforeHistoryStateCompletes() async throws {
        let repo = try vaultRepository()
        _ = try GitService.checkoutHistory(path: repo.url.path, commit: repo.hashes[0], message: "Save")
        let gate = HistoryGate()
        let started = expectation(description: "history inspection started")
        var dependencies = AppModelDependencies(
            githubCLIStatus: { _ in GitHubCLIStatus() },
            githubUser: { _ in throw GitHubError.noToken },
            githubRepos: { _ in [] },
            loadKeychainToken: { nil },
            saveKeychainToken: { _ in },
            authenticationDisabled: { true }
        )
        dependencies.historyState = { path in
            started.fulfill()
            await gate.pause()
            return GitService.historyState(path: path)
        }
        let model = AppModel(bootstrapOnLaunch: false, dependencies: dependencies)
        let opening = Task { await model.openVault(path: repo.url.path) }
        await fulfillment(of: [started], timeout: 5)

        XCTAssertTrue(model.isReadOnly)
        await model.newNote()
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("Untitled.md").path))
        gate.release()
        await opening.value
        XCTAssertEqual(model.historyCheckout?.commit.hash, repo.hashes[0])
    }

    func testConcurrentReturnAndResetRunsOnlyOneHistoryOperation() async throws {
        let repo = try vaultRepository()
        _ = try GitService.checkoutHistory(path: repo.url.path, commit: repo.hashes[0], message: "Save")
        let gate = HistoryGate()
        let started = expectation(description: "return started")
        let model = try await modelWithDependencies(at: repo.url, confirmReset: { _, _ in true }) { dependencies in
            dependencies.returnToLatest = { path in
                started.fulfill()
                await gate.pause()
                try GitService.returnToLatest(path: path)
            }
        }
        let returning = Task { await model.returnToLatestCommit() }
        await fulfillment(of: [started], timeout: 5)
        await model.resetToHistoryCommit()
        gate.release()
        await returning.value
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isReadOnly)
        XCTAssertEqual(try Shell.git(["rev-parse", "main"], cwd: repo.url), repo.hashes[2])
    }

    func testConfirmedResetAutoSyncsThroughModel() async throws {
        let repo = try vaultRepository()
        let remote = try temporaryDirectory()
        _ = try Shell.git(["init", "--bare", "-b", "main"], cwd: remote)
        _ = try Shell.git(["remote", "add", "origin", remote.path], cwd: repo.url)
        _ = try Shell.git(["push", "-u", "origin", "main"], cwd: repo.url)
        let model = try await modelWithDependencies(
            at: repo.url, confirmReset: { _, _ in true }, autoSync: true, authenticationDisabled: false
        ) { _ in }
        await model.checkoutCommit(repo.hashes[0])
        await model.resetToHistoryCommit()

        XCTAssertEqual(try Shell.git(["rev-parse", "main"], cwd: remote), repo.hashes[0])
        XCTAssertFalse(GitService.hasPendingForcePush(at: repo.url))
        XCTAssertEqual(model.gitStatus?.state, .synced)
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
        try await modelWithDependencies(at: root, confirmReset: confirmReset) { _ in }
    }

    private func modelWithDependencies(
        at root: URL,
        confirmReset: @escaping @MainActor (GitCommit, Bool) -> Bool = { _, _ in false },
        autoSync: Bool = false,
        authenticationDisabled: Bool = true,
        configure: (inout AppModelDependencies) -> Void
    ) async throws -> AppModel {
        var settings = AppSettings.default()
        settings.autoSync = autoSync
        var dependencies = AppModelDependencies(
            githubCLIStatus: { _ in GitHubCLIStatus() },
            githubUser: { _ in throw GitHubError.noToken },
            githubRepos: { _ in [] },
            loadKeychainToken: { nil },
            saveKeychainToken: { _ in },
            authenticationDisabled: { authenticationDisabled }
        )
        dependencies.confirmHistoryReset = confirmReset
        configure(&dependencies)
        let model = AppModel(settings: settings, bootstrapOnLaunch: false, dependencies: dependencies)
        await model.openVault(path: root.path)
        XCTAssertEqual(model.activeTab?.title, "Welcome")
        return model
    }

    @MainActor private final class HistoryGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func pause() async {
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
