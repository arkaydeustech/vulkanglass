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
        XCTAssertEqual(settings.appearanceMode, .dark)
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
        XCTAssertEqual(decoded.appearanceMode, .inherit)
    }

    func testSettingsRoundTripPreservesExplicitAppearanceModes() throws {
        for appearanceMode in [AppearanceMode.light, .dark] {
            var settings = AppSettings.default()
            settings.appearanceMode = appearanceMode

            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

            XCTAssertEqual(decoded.appearanceMode, appearanceMode)
        }
    }

    func testAppearanceModeWinsOverConflictingLegacyDarkMode() throws {
        let json = """
        {
          "recentVaults": [],
          "vaultsRoot": "/tmp/vaults",
          "autoSync": true,
          "appearanceMode": "light",
          "darkMode": true
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertEqual(settings.appearanceMode, .light)
    }

    func testEncodedSettingsRemainReadableByPreviousDecoder() throws {
        var settings = AppSettings.default()
        settings.recentVaults = [
            RecentVault(
                name: "Notes",
                path: "/tmp/notes",
                remote: "git@example.com:notes.git",
                lastOpened: 42
            )
        ]
        settings.vaultsRoot = "/tmp/vaults"
        settings.autoSync = false
        settings.appearanceMode = .dark
        settings.useGitHubCLI = false
        settings.loadRemoteImages = true
        settings.leftSidebarWidth = 222
        settings.rightSidebarWidth = 333

        let data = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let legacy = try JSONDecoder().decode(LegacyAppSettings.self, from: data)

        XCTAssertEqual(json["appearanceMode"] as? String, "dark")
        XCTAssertEqual(json["darkMode"] as? Bool, true)
        XCTAssertEqual(legacy.recentVaults, settings.recentVaults)
        XCTAssertEqual(legacy.vaultsRoot, settings.vaultsRoot)
        XCTAssertEqual(legacy.autoSync, settings.autoSync)
        XCTAssertTrue(legacy.darkMode)
        XCTAssertEqual(legacy.useGitHubCLI, settings.useGitHubCLI)
        XCTAssertEqual(legacy.loadRemoteImages, settings.loadRemoteImages)
        XCTAssertEqual(legacy.leftSidebarWidth, settings.leftSidebarWidth)
        XCTAssertEqual(legacy.rightSidebarWidth, settings.rightSidebarWidth)
    }

    func testLegacyLightAppearanceMigratesToExplicitLight() throws {
        let json = """
        {"recentVaults":[],"vaultsRoot":"/tmp/vaults","autoSync":true,"darkMode":false}
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertEqual(settings.appearanceMode, .light)
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

private struct LegacyAppSettings: Decodable {
    var recentVaults: [RecentVault]
    var vaultsRoot: String
    var autoSync: Bool
    var darkMode: Bool
    var useGitHubCLI: Bool
    var loadRemoteImages: Bool
    var leftSidebarWidth: CGFloat
    var rightSidebarWidth: CGFloat
}
