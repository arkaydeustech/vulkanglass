import XCTest
@testable import VulkanGlass

final class GitHubCLIServiceTests: XCTestCase {
    func testResolverPrefersGitHubCLIWhenEnabled() {
        let candidates = GitHubAuthResolver.candidates(
            useCLI: true,
            cliToken: "gho_cli",
            keychainToken: "ghp_pat"
        )
        XCTAssertEqual(candidates.map(\.source), [.gitHubCLI, .personalAccessToken])
        XCTAssertEqual(candidates.map(\.token), ["gho_cli", "ghp_pat"])
    }

    func testResolverSkipsCLIWhenDisabled() {
        let candidates = GitHubAuthResolver.candidates(
            useCLI: false,
            cliToken: "gho_cli",
            keychainToken: "ghp_pat"
        )
        XCTAssertEqual(candidates.map(\.source), [.personalAccessToken])
        XCTAssertEqual(candidates.first?.token, "ghp_pat")
    }

    func testResolverOmitsDuplicateTokens() {
        let candidates = GitHubAuthResolver.candidates(
            useCLI: true,
            cliToken: "same-token",
            keychainToken: "same-token"
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.source, .gitHubCLI)
    }

    func testResolverReturnsEmptyWhenNothingIsAvailable() {
        XCTAssertTrue(GitHubAuthResolver.candidates(useCLI: true, cliToken: nil, keychainToken: nil).isEmpty)
        XCTAssertTrue(GitHubAuthResolver.candidates(useCLI: true, cliToken: "", keychainToken: "  ").isEmpty)
    }

    func testParseTokenPrefersPrefixedLineAndIgnoresWarnings() {
        let output = """
        A new release of gh is available
        gho_abcdefghijklmnopqrstuvwxyz012345
        """
        XCTAssertEqual(
            GitHubCLIService.parseToken(from: output),
            "gho_abcdefghijklmnopqrstuvwxyz012345"
        )
        XCTAssertEqual(
            GitHubCLIService.parseToken(from: "github_pat_abcdefghijklmnopqrstuvwxyz"),
            "github_pat_abcdefghijklmnopqrstuvwxyz"
        )
        XCTAssertNil(GitHubCLIService.parseToken(from: "no oauth token"))
    }

    func testParseTokenAcceptsSingleOpaqueLine() {
        XCTAssertEqual(
            GitHubCLIService.parseToken(from: "abcdefghijklmnopqrstuvwxyz0123"),
            "abcdefghijklmnopqrstuvwxyz0123"
        )
        XCTAssertNil(GitHubCLIService.parseToken(from: "short"))
    }

    func testExecutablePathPrefersHomebrewThenPATH() {
        let home = "/Users/test"
        let path = GitHubCLIService.executablePath(
            environment: ["PATH": "\(home)/bin:/usr/bin"],
            homeDirectory: home,
            isExecutable: { $0 == "/opt/homebrew/bin/gh" || $0 == "\(home)/bin/gh" }
        )
        XCTAssertEqual(path, "/opt/homebrew/bin/gh")
    }

    func testExecutablePathFallsBackToPATH() {
        let home = "/Users/test"
        let custom = "\(home)/custom/gh"
        let path = GitHubCLIService.executablePath(
            environment: ["PATH": "\(home)/custom"],
            homeDirectory: home,
            isExecutable: { $0 == custom }
        )
        XCTAssertEqual(path, custom)
    }

    func testTokenReadsStdoutFromFakeGitHubCLI() throws {
        let gh = try fakeGitHubCLI(script: """
        #!/bin/sh
        echo "notice from gh" >&2
        if [ "$1" = "auth" ] && [ "$2" = "token" ]; then
          echo "gho_from_cli_abcdefghijklmnopqrstuv"
          exit 0
        fi
        exit 1
        """)
        XCTAssertEqual(
            GitHubCLIService.token(executable: gh.path),
            "gho_from_cli_abcdefghijklmnopqrstuv"
        )
    }

    func testTokenReturnsNilWhenGitHubCLIIsLoggedOut() throws {
        let gh = try fakeGitHubCLI(script: """
        #!/bin/sh
        echo "no oauth token" >&2
        exit 1
        """)
        XCTAssertNil(GitHubCLIService.token(executable: gh.path))
    }

    func testLegacySettingsDefaultToUsingGitHubCLI() throws {
        let json = """
        {"recentVaults":[],"vaultsRoot":"/tmp/vaults","autoSync":true,"darkMode":true}
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(settings.useGitHubCLI)
        XCTAssertFalse(settings.loadRemoteImages)
        XCTAssertEqual(settings.vaultsRoot, "/tmp/vaults")
        XCTAssertEqual(settings.rightSidebarWidth, VGTheme.sidebarWidth)
    }

    func testSettingsRoundTripPreservesGitHubCLIFlag() throws {
        var settings = AppSettings.default()
        settings.useGitHubCLI = false
        settings.loadRemoteImages = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(decoded.useGitHubCLI)
        XCTAssertTrue(decoded.loadRemoteImages)
    }

    func testMissingTokenErrorMentionsGitHubCLI() {
        XCTAssertTrue(GitHubError.noToken.localizedDescription.contains("GitHub CLI"))
    }

    private func fakeGitHubCLI(script: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
