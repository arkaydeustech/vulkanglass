import Foundation

/// How Vulkan Glass obtained the GitHub token currently in use.
enum GitHubAuthSource: String, Equatable, Sendable {
    case gitHubCLI
    case personalAccessToken
}

/// Authentication that Git can use without conflating CLI-managed and app-managed secrets.
enum GitCredential: Equatable, Sendable {
    case gitHubCLI(executablePath: String)
    case personalAccessToken(String)
}

/// Snapshot of the local GitHub CLI (`gh`) installation.
struct GitHubCLIStatus: Equatable, Sendable {
    var executablePath: String?
    var token: String?

    var isInstalled: Bool { executablePath != nil }
    var isAuthenticated: Bool { !(token?.isEmpty ?? true) }
}

/// Chooses between a GitHub CLI token and a saved personal access token.
enum GitHubAuthResolver {
    /// Returns auth candidates in preference order: GitHub CLI first when enabled, then a Keychain PAT.
    static func candidates(
        useCLI: Bool,
        cliToken: String?,
        keychainToken: String?
    ) -> [(token: String, source: GitHubAuthSource)] {
        var result: [(token: String, source: GitHubAuthSource)] = []
        let cli = cliToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let keychain = keychainToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if useCLI, !cli.isEmpty {
            result.append((cli, .gitHubCLI))
        }
        if !keychain.isEmpty, keychain != result.first?.token {
            result.append((keychain, .personalAccessToken))
        }
        return result
    }
}

/// Locates `gh` and reads `gh auth token` without copying it into the Keychain.
enum GitHubCLIService {
    private static let wellKnownDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin"
    ]

    private static let tokenPrefixes = [
        "ghp_",
        "gho_",
        "ghu_",
        "ghs_",
        "ghr_",
        "github_pat_"
    ]

    /// Locates the GitHub CLI executable, including Homebrew paths GUI apps often lack on `PATH`.
    static func executablePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        var directories = wellKnownDirectories
        directories.append("\(homeDirectory)/.local/bin")
        directories.append("\(homeDirectory)/.asdf/shims")
        directories.append("\(homeDirectory)/.local/share/mise/shims")
        if let path = environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":").map(String.init))
        }

        var seen = Set<String>()
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("gh").path
            if seen.insert(candidate).inserted, isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Reads the current GitHub CLI token, if `gh` is installed and authenticated.
    static func token(
        executable: String? = nil,
        run: ((String, [String], [String: String]) throws -> String)? = nil
    ) -> String? {
        guard let gh = executable ?? executablePath() else { return nil }
        let execute = run ?? { path, arguments, extraEnv in
            try Shell.run(path, arguments, extraEnv: extraEnv)
        }
        let extraEnv = pathEnvironment(for: gh)
        guard let output = try? execute(gh, ["auth", "token"], extraEnv) else { return nil }
        return parseToken(from: output)
    }

    /// Reports whether `gh` is installed and, optionally, its current token.
    static func status(includeToken: Bool = true) -> GitHubCLIStatus {
        let path = executablePath()
        let token = includeToken ? path.flatMap { self.token(executable: $0) } : nil
        return GitHubCLIStatus(executablePath: path, token: token)
    }

    /// Extracts a GitHub token from `gh auth token` output, ignoring warnings on other lines.
    static func parseToken(from output: String) -> String? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let match = lines.reversed().first(where: isLikelyToken) {
            return match
        }
        if lines.count == 1, isOpaqueToken(lines[0]) {
            return lines[0]
        }
        return nil
    }

    private static func isLikelyToken(_ value: String) -> Bool {
        tokenPrefixes.contains { value.hasPrefix($0) }
    }

    private static func isOpaqueToken(_ value: String) -> Bool {
        value.count >= 20 && !value.contains(where: { $0.isWhitespace })
    }

    private static func pathEnvironment(for executable: String) -> [String: String] {
        let bin = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return ["PATH": "\(bin):/opt/homebrew/bin:/usr/local/bin:\(path)"]
    }
}
