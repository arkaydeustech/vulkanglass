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

    func testCredentialSecretIsSeparatedFromGitArguments() {
        let sentinel = "sentinel-secret"
        XCTAssertFalse(GitService.credentialArguments.joined().contains(sentinel))
        XCTAssertTrue(GitService.credentialPayload(token: sentinel).contains(sentinel))
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
            try GitService.clone(cloneURL: "https://github.com/owner/repo.git", destDir: root, token: nil)
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
        XCTAssertThrowsError(try GitService.pull(path: root.path, token: nil))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
