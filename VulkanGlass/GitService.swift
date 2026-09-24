import Foundation

enum ShellError: LocalizedError {
    case launchFailed(String)
    case failed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message): return message
        case .failed(let code, let output): return "Command failed (\(code)): \(output)"
        }
    }
}

enum GitServiceError: LocalizedError, Equatable {
    case invalidGitHubRemote(String)
    case destinationExists(String)
    case invalidDestination(String)
    case rebaseInProgress
    case unmergedPaths([String])
    case gitNotInstalled

    var errorDescription: String? {
        switch self {
        case .invalidGitHubRemote(let remote):
            return "GitHub credentials cannot be used with remote: \(remote)"
        case .destinationExists(let path):
            return "A file or folder already exists at \(path). Choose a different vault location."
        case .invalidDestination(let path):
            return "The clone destination is outside the configured vault folder: \(path)"
        case .rebaseInProgress:
            return "This repository already has a rebase in progress. Resolve or abort it before syncing."
        case .unmergedPaths(let paths):
            return "Git could not reapply local changes cleanly. Resolve the conflicts before syncing: \(paths.joined(separator: ", "))."
        case .gitNotInstalled:
            return "Git is not installed. Install the Command Line Tools (xcode-select --install) or Homebrew Git (brew install git), then try again."
        }
    }
}

enum Shell {
    static func run(
        _ launchPath: String,
        _ arguments: [String],
        cwd: URL? = nil,
        extraEnv: [String: String] = [:],
        input: Data? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        extraEnv.forEach { env[$0.key] = $0.value }
        process.environment = env

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let inputPipe = input.map { _ in Pipe() }
        if let inputPipe { process.standardInput = inputPipe }

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(error.localizedDescription)
        }
        if let input, let inputPipe {
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
        }

        // Drain while the child runs. Waiting first deadlocks once the pipe fills.
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus != 0 {
            throw ShellError.failed(process.terminationStatus, trimmed)
        }
        return trimmed
    }

    static func git(_ arguments: [String], cwd: URL? = nil, input: Data? = nil) throws -> String {
        guard let git = GitExecutable.path() else { throw GitServiceError.gitNotInstalled }
        return try run(git, arguments, cwd: cwd, input: input)
    }
}

/// Finds a working `git` without running `/usr/bin/git`, which on a Mac without the developer
/// tools only opens Apple's install prompt.
enum GitExecutable {
    static let systemPath = "/usr/bin/git"
    static let homebrewPaths = ["/opt/homebrew/bin/git", "/usr/local/bin/git"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedPath: String?

    /// Returns the git to run, or nil when neither the developer tools nor Homebrew provide one.
    /// Only a hit is cached, so installing git while the app is open is picked up on the next call.
    static func path() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedPath { return cachedPath }
        cachedPath = locate()
        return cachedPath
    }

    /// Prefers the developer tools' git behind `/usr/bin/git`, then Homebrew's.
    static func locate(
        developerDirectory: () -> String? = activeDeveloperDirectory,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let developer = developerDirectory(),
           isExecutable(URL(fileURLWithPath: developer).appendingPathComponent("usr/bin/git").path) {
            return systemPath
        }
        return homebrewPaths.first(where: isExecutable)
    }

    /// The developer directory the `/usr/bin` shims forward to. `xcode-select` is not a shim, so
    /// asking it never triggers the install prompt.
    static func activeDeveloperDirectory() -> String? {
        guard let path = try? Shell.run("/usr/bin/xcode-select", ["--print-path"]), !path.isEmpty else {
            return nil
        }
        return path
    }
}

enum GitService {
    private static let mutationLock = NSLock()
    static let credentialArguments = [
        "-c", "credential.helper=",
        "-c", "credential.helper=osxkeychain"
    ]

    static func isGitHubRemote(_ remote: String?) -> Bool {
        guard let remote = remote?.trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty else {
            return false
        }
        if remote.hasPrefix("git@") {
            guard let colon = remote.firstIndex(of: ":") else { return false }
            return remote[remote.index(remote.startIndex, offsetBy: 4)..<colon].lowercased() == "github.com"
        }
        guard let components = URLComponents(string: remote),
              let host = components.host?.lowercased()
        else { return false }
        return host == "github.com"
    }

    static func isHTTPSGitHubRemote(_ remote: String?) -> Bool {
        guard let remote, let components = URLComponents(string: remote) else { return false }
        return components.scheme?.lowercased() == "https" && components.host?.lowercased() == "github.com"
    }

    static func inspect(path: String) -> VaultInfo {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let gitDir = url.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir.path) else {
            return VaultInfo(name: name, path: path, remote: nil, branch: nil, isGitHub: false)
        }
        let remote = try? Shell.git(["remote", "get-url", "origin"], cwd: url)
        let branch = try? Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: url)
        return VaultInfo(
            name: name,
            path: path,
            remote: remote,
            branch: branch,
            isGitHub: isGitHubRemote(remote)
        )
    }

    static func status(path: String, token: String? = nil) -> GitStatus {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
            return GitStatus(state: .idle, message: "Not a git vault")
        }
        do {
            let branch = try Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: url)
            let remote = try? Shell.git(["remote", "get-url", "origin"], cwd: url)
            let porcelain = try Shell.git(["status", "--porcelain"], cwd: url)
            return GitStatus(
                state: porcelain.isEmpty ? .synced : .idle,
                branch: branch,
                remote: remote,
                message: porcelain.isEmpty ? "Working tree clean" : "Uncommitted changes"
            )
        } catch {
            return GitStatus(state: .error, message: error.localizedDescription)
        }
    }

    static func clone(cloneURL: String, destDir: URL, credential: GitCredential?) throws -> URL {
        try withMutationLock {
            guard isHTTPSGitHubRemote(cloneURL) else {
                throw GitServiceError.invalidGitHubRemote(cloneURL)
            }
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let canonicalRoot = destDir.standardizedFileURL.resolvingSymlinksInPath()
            var name = URL(string: cloneURL)?.lastPathComponent ?? "vault"
            if name.hasSuffix(".git") { name.removeLast(4) }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                throw GitServiceError.invalidDestination(name)
            }
            let target = canonicalRoot.appendingPathComponent(name).standardizedFileURL
            guard target.path.hasPrefix(canonicalRoot.path + "/") else {
                throw GitServiceError.invalidDestination(target.path)
            }
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw GitServiceError.destinationExists(target.path)
            }
            try prepareCredential(credential, remote: cloneURL)
            _ = try Shell.git(credentialArguments(for: credential, remote: cloneURL) + ["clone", cloneURL, target.path])
            return target
        }
    }

    static func sync(path: String, message: String, credential: GitCredential?) throws -> GitStatus {
        try withMutationLock {
            let url = URL(fileURLWithPath: path)
            try ensureNoRebase(at: url)
            let remote = try Shell.git(["remote", "get-url", "origin"], cwd: url)
            try prepareCredential(credential, remote: remote)
            try commitAll(at: url, message: message)
            let branch = try Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: url)
            _ = try networkGit(
                ["pull", "--rebase", "--autostash", "origin", branch],
                cwd: url,
                remote: remote,
                credential: credential
            )
            try ensureNoUnmergedPaths(at: url)
            try commitAll(at: url, message: message)
            _ = try networkGit(
                ["push", "-u", "origin", branch],
                cwd: url,
                remote: remote,
                credential: credential
            )
            let porcelainAfter = try Shell.git(["status", "--porcelain"], cwd: url)
            guard porcelainAfter.isEmpty else {
                return GitStatus(state: .idle, branch: branch, remote: remote, message: "Uncommitted changes")
            }
            return GitStatus(state: .synced, branch: branch, remote: remote, message: "Synced to GitHub")
        }
    }

    static func pull(path: String, credential: GitCredential?) throws -> GitStatus {
        try withMutationLock {
            let url = URL(fileURLWithPath: path)
            try ensureNoRebase(at: url)
            let remote = try Shell.git(["remote", "get-url", "origin"], cwd: url)
            try prepareCredential(credential, remote: remote)
            let branch = try Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: url)
            _ = try networkGit(
                ["pull", "--rebase", "--autostash", "origin", branch],
                cwd: url,
                remote: remote,
                credential: credential
            )
            try ensureNoUnmergedPaths(at: url)
            var result = status(path: path)
            result.remote = remote
            result.branch = branch
            result.message = result.state == .synced ? "Synced to GitHub" : result.message
            return result
        }
    }

    static func initAndPush(
        path: String,
        remoteURL: String,
        message: String,
        credential: GitCredential?
    ) throws -> GitStatus {
        try withMutationLock {
            guard isHTTPSGitHubRemote(remoteURL) else {
                throw GitServiceError.invalidGitHubRemote(remoteURL)
            }
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                _ = try Shell.git(["init"], cwd: url)
            }
            ensureIdentity(at: url)
            let remotes = (try? Shell.git(["remote"], cwd: url)) ?? ""
            if !remotes.split(separator: "\n").contains("origin") {
                _ = try Shell.git(["remote", "add", "origin", remoteURL], cwd: url)
            }
            _ = try Shell.git(["add", "--all"], cwd: url)
            let porcelain = try Shell.git(["status", "--porcelain"], cwd: url)
            if !porcelain.isEmpty {
                _ = try Shell.git(["commit", "-m", message], cwd: url)
            }
            _ = try Shell.git(["branch", "-M", "main"], cwd: url)
            try prepareCredential(credential, remote: remoteURL)
            _ = try networkGit(
                ["push", "-u", "origin", "main"],
                cwd: url,
                remote: remoteURL,
                credential: credential
            )
            return GitStatus(state: .synced, branch: "main", remote: remoteURL, message: "Synced to GitHub")
        }
    }

    private static func networkGit(
        _ arguments: [String],
        cwd: URL,
        remote: String,
        credential: GitCredential?
    ) throws -> String {
        if isHTTPSGitHubRemote(remote) {
            return try Shell.git(credentialArguments(for: credential, remote: remote) + arguments, cwd: cwd)
        }
        return try Shell.git(arguments, cwd: cwd)
    }

    /// Stages everything and commits when the worktree is dirty.
    private static func commitAll(at url: URL, message: String) throws {
        try ensureNoUnmergedPaths(at: url)
        _ = try Shell.git(["add", "--all"], cwd: url)
        let porcelain = try Shell.git(["status", "--porcelain"], cwd: url)
        guard !porcelain.isEmpty else { return }
        ensureIdentity(at: url)
        _ = try Shell.git(["commit", "-m", message], cwd: url)
    }

    private static func prepareCredential(_ credential: GitCredential?, remote: String) throws {
        guard isHTTPSGitHubRemote(remote),
              case .personalAccessToken(let token) = credential,
              !token.isEmpty
        else { return }
        try approveGitHubCredential(token)
    }

    private static func approveGitHubCredential(_ token: String?) throws {
        guard let token, !token.isEmpty else { return }
        let request = credentialPayload(token: token)
        _ = try Shell.git(credentialArguments + ["credential", "approve"], input: Data(request.utf8))
    }

    private static func ensureIdentity(at url: URL) {
        if (try? Shell.git(["config", "user.name"], cwd: url))?.isEmpty != false {
            _ = try? Shell.git(["config", "user.name", "Vulkan Glass"], cwd: url)
        }
        if (try? Shell.git(["config", "user.email"], cwd: url))?.isEmpty != false {
            _ = try? Shell.git(["config", "user.email", "vulkan-glass@users.noreply.github.com"], cwd: url)
        }
    }

    private static func ensureNoRebase(at url: URL) throws {
        let gitDir = url.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("rebase-merge").path)
            || FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("rebase-apply").path)
        {
            throw GitServiceError.rebaseInProgress
        }
    }

    private static func ensureNoUnmergedPaths(at url: URL) throws {
        let output = try Shell.git(["diff", "--name-only", "--diff-filter=U"], cwd: url)
        let paths = output.split(whereSeparator: \.isNewline).map(String.init)
        guard paths.isEmpty else { throw GitServiceError.unmergedPaths(paths) }
    }

    static func credentialArguments(for credential: GitCredential?, remote: String) -> [String] {
        guard isHTTPSGitHubRemote(remote) else { return [] }
        switch credential {
        case .gitHubCLI(let executablePath):
            let helper = "!\(shellQuoted(executablePath)) auth git-credential"
            return ["-c", "credential.helper=", "-c", "credential.helper=\(helper)"]
        case .personalAccessToken:
            return credentialArguments
        case nil:
            return []
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func credentialPayload(token: String) -> String {
        "protocol=https\nhost=github.com\nusername=x-access-token\npassword=\(token)\n\n"
    }

    static func withMutationLock<T>(_ operation: () throws -> T) rethrows -> T {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return try operation()
    }
}
