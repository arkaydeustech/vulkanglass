import XCTest
@testable import VulkanGlass

final class GitHubServiceTests: XCTestCase {
    func testParseRepoAcceptsSupportedForms() {
        XCTAssertEqual(GitHubService.parseRepo("owner/repo")?.owner, "owner")
        XCTAssertEqual(GitHubService.parseRepo("https://github.com/owner/repo.git")?.repo, "repo")
        XCTAssertEqual(GitHubService.parseRepo("git@github.com:owner/dot.gitignore-tools.git")?.repo, "dot.gitignore-tools")
    }

    func testParseRepoRejectsTraversalAndLookalikeHosts() {
        XCTAssertNil(GitHubService.parseRepo("../.."))
        XCTAssertNil(GitHubService.parseRepo("https://github.com.evil.test/owner/repo"))
        XCTAssertNil(GitHubService.parseRepo("owner/.."))
    }
}

final class GitServiceTests: XCTestCase {
    func testGitHubHostRecognitionIsExact() {
        XCTAssertTrue(GitService.isGitHubRemote("https://github.com/owner/repo.git"))
        XCTAssertTrue(GitService.isGitHubRemote("git@github.com:owner/repo.git"))
        XCTAssertFalse(GitService.isGitHubRemote("http://github.com.evil.test/owner/repo.git"))
        XCTAssertFalse(GitService.isGitHubRemote("http://127.0.0.1/repo.git"))
        XCTAssertFalse(GitService.isHTTPSGitHubRemote("http://github.com/owner/repo.git"))
    }

    func testShellDrainsLargeOutput() throws {
        let output = try Shell.run("/bin/sh", ["-c", "i=0; while [ $i -lt 12000 ]; do echo 0123456789abcdef; i=$((i+1)); done"])
        XCTAssertGreaterThan(output.utf8.count, 64 * 1024)
    }

    func testShellSurfacesNonZeroExit() {
        XCTAssertThrowsError(try Shell.run("/bin/sh", ["-c", "echo failure >&2; exit 17"])) { error in
            guard case ShellError.failed(let code, let output) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(code, 17)
            XCTAssertEqual(output, "failure")
        }
    }

    func testGitLocatorPrefersDeveloperToolsGit() {
        let path = GitExecutable.locate(
            developerDirectory: { "/Library/Developer/CommandLineTools" },
            isExecutable: { ["/Library/Developer/CommandLineTools/usr/bin/git", "/opt/homebrew/bin/git"].contains($0) }
        )
        XCTAssertEqual(path, "/usr/bin/git")
    }

    func testGitLocatorFallsBackToHomebrewWithoutDeveloperTools() {
        XCTAssertEqual(
            GitExecutable.locate(developerDirectory: { nil }, isExecutable: { $0 == "/opt/homebrew/bin/git" }),
            "/opt/homebrew/bin/git"
        )
        // A developer directory that has no git (e.g. a deleted Xcode) must not select the shim.
        XCTAssertEqual(
            GitExecutable.locate(
                developerDirectory: { "/Applications/Xcode.app/Contents/Developer" },
                isExecutable: { $0 == "/usr/local/bin/git" }
            ),
            "/usr/local/bin/git"
        )
    }

    func testGitLocatorReportsMissingGit() {
        XCTAssertNil(GitExecutable.locate(developerDirectory: { nil }, isExecutable: { _ in false }))
    }

    func testCredentialSecretIsSeparatedFromGitArguments() {
        let sentinel = "sentinel-secret"
        XCTAssertFalse(GitService.credentialArguments.joined().contains(sentinel))
        XCTAssertTrue(GitService.credentialPayload(token: sentinel).contains(sentinel))
    }

    func testGitHubCLICredentialUsesTransientHelperInsteadOfKeychain() {
        let arguments = GitService.credentialArguments(
            for: .gitHubCLI(executablePath: "/opt/homebrew/bin/gh"),
            remote: "https://github.com/owner/repo.git"
        )
        XCTAssertTrue(arguments.joined(separator: " ").contains("gh' auth git-credential"))
        XCTAssertFalse(arguments.contains("credential.helper=osxkeychain"))

        let patArguments = GitService.credentialArguments(
            for: .personalAccessToken("secret-not-an-argument"),
            remote: "https://github.com/owner/repo.git"
        )
        XCTAssertEqual(patArguments, GitService.credentialArguments)
        XCTAssertFalse(patArguments.joined().contains("secret-not-an-argument"))
    }

    func testGitHubCLIHelperParticipatesInGitCredentialProtocol() throws {
        let root = try temporaryDirectory()
        let helper = root.appendingPathComponent("fake gh")
        let script = """
        #!/bin/sh
        if [ "$1" = "auth" ] && [ "$2" = "git-credential" ] && [ "$3" = "get" ]; then
          while IFS= read -r line && [ -n "$line" ]; do :; done
          echo username=x-access-token
          echo password=transient-cli-token
          exit 0
        fi
        exit 1
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let arguments = GitService.credentialArguments(
            for: .gitHubCLI(executablePath: helper.path),
            remote: "https://github.com/owner/repo.git"
        )

        let output = try Shell.run(
            "/usr/bin/git",
            arguments + ["credential", "fill"],
            input: Data("protocol=https\nhost=github.com\n\n".utf8)
        )

        XCTAssertTrue(output.contains("username=x-access-token"))
        XCTAssertTrue(output.contains("password=transient-cli-token"))
        XCTAssertFalse(arguments.contains("credential.helper=osxkeychain"))
    }

    func testGitMutationsAreSerialized() {
        let state = NSLock()
        var active = 0
        var maximum = 0
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            GitService.withMutationLock {
                state.lock()
                active += 1
                maximum = max(maximum, active)
                state.unlock()
                Thread.sleep(forTimeInterval: 0.01)
                state.lock()
                active -= 1
                state.unlock()
            }
        }
        XCTAssertEqual(maximum, 1)
    }

    func testCloneRefusesExistingDestination() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("repo"), withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try GitService.clone(cloneURL: "https://github.com/owner/repo.git", destDir: root, credential: nil)
        ) { error in
            guard case GitServiceError.destinationExists = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPullFailureIsThrown() throws {
        let root = try temporaryDirectory()
        _ = try Shell.git(["init"], cwd: root)
        _ = try Shell.git(["config", "user.name", "Tests"], cwd: root)
        _ = try Shell.git(["config", "user.email", "tests@example.com"], cwd: root)
        try "hello".write(to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        _ = try Shell.git(["add", "--all"], cwd: root)
        _ = try Shell.git(["commit", "-m", "Initial"], cwd: root)
        _ = try Shell.git(["remote", "add", "origin", root.appendingPathComponent("missing.git").path], cwd: root)
        XCTAssertThrowsError(try GitService.pull(path: root.path, credential: nil))
    }

    func testPullPreservesUnstagedEditsInsteadOfFailingRebase() throws {
        let pair = try connectedRepositories()
        try "local draft".write(to: pair.local.appendingPathComponent("Draft.md"), atomically: true, encoding: .utf8)

        let status = try GitService.pull(path: pair.local.path, credential: nil)

        XCTAssertNotEqual(status.state, .error)
        XCTAssertEqual(try String(contentsOf: pair.local.appendingPathComponent("Draft.md"), encoding: .utf8), "local draft")
    }

    func testSyncCommitsUnstagedEditsThenPushes() throws {
        let pair = try connectedRepositories()
        try "local draft".write(to: pair.local.appendingPathComponent("Draft.md"), atomically: true, encoding: .utf8)

        let status = try GitService.sync(path: pair.local.path, message: "Save draft", credential: nil)

        XCTAssertEqual(status.state, .synced)
        XCTAssertEqual(try Shell.git(["status", "--porcelain"], cwd: pair.local), "")
        let cloned = try temporaryDirectory()
        _ = try Shell.git(["clone", pair.remote.path, "."], cwd: cloned)
        XCTAssertEqual(try String(contentsOf: cloned.appendingPathComponent("Draft.md"), encoding: .utf8), "local draft")
    }

    func testConflictingAutostashIsReportedAndNeverPushed() throws {
        let pair = try connectedRepositories()
        let peer = try temporaryDirectory()
        _ = try Shell.git(["clone", pair.remote.path, "."], cwd: peer)
        _ = try Shell.git(["config", "user.name", "Peer"], cwd: peer)
        _ = try Shell.git(["config", "user.email", "peer@example.com"], cwd: peer)
        try "# Remote".write(to: peer.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)
        _ = try Shell.git(["add", "--all"], cwd: peer)
        _ = try Shell.git(["commit", "-m", "Remote edit"], cwd: peer)
        _ = try Shell.git(["push", "origin", "main"], cwd: peer)

        try "# Local".write(
            to: pair.local.appendingPathComponent("Welcome.md"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try GitService.pull(path: pair.local.path, credential: nil)) { error in
            guard case GitServiceError.unmergedPaths(let paths) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(paths, ["Welcome.md"])
        }
        XCTAssertTrue(
            try String(contentsOf: pair.local.appendingPathComponent("Welcome.md"), encoding: .utf8)
                .contains("<<<<<<< Updated upstream")
        )
        XCTAssertThrowsError(
            try GitService.sync(path: pair.local.path, message: "Must not publish", credential: nil)
        ) { error in
            guard case GitServiceError.unmergedPaths = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let verify = try temporaryDirectory()
        _ = try Shell.git(["clone", pair.remote.path, "."], cwd: verify)
        let remoteText = try String(contentsOf: verify.appendingPathComponent("Welcome.md"), encoding: .utf8)
        XCTAssertEqual(remoteText, "# Remote")
        XCTAssertFalse(remoteText.contains("<<<<<<<"))
    }

    private func connectedRepositories() throws -> (local: URL, remote: URL) {
        let remote = try temporaryDirectory()
        _ = try Shell.git(["init", "--bare", "-b", "main"], cwd: remote)
        let local = try temporaryDirectory()
        _ = try Shell.git(["init", "-b", "main"], cwd: local)
        _ = try Shell.git(["config", "user.name", "Tests"], cwd: local)
        _ = try Shell.git(["config", "user.email", "tests@example.com"], cwd: local)
        try "# Welcome".write(to: local.appendingPathComponent("Welcome.md"), atomically: true, encoding: .utf8)
        _ = try Shell.git(["add", "--all"], cwd: local)
        _ = try Shell.git(["commit", "-m", "Initial"], cwd: local)
        _ = try Shell.git(["remote", "add", "origin", remote.path], cwd: local)
        _ = try Shell.git(["push", "-u", "origin", "main"], cwd: local)
        return (local, remote)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
