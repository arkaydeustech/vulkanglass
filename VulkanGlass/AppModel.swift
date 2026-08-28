import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Central application state for vaults, tabs, and GitHub sync.
@MainActor
@Observable
final class AppModel {
    var settings: AppSettings
    var githubUser: GitHubUser?
    var githubRepos: [GitHubRepo] = []
    var vault: VaultInfo?
    var fileTree: [FileNode] = []
    var notes: [NoteMeta] = []
    var tabs: [NoteTab] = []
    var activeTabID: String?
    var leftOpen = true
    var rightOpen = true
    var leftPanel: LeftPanel = .files
    var rightPanel: RightPanel = .graph
    var centerView: CenterView = .editor
    var editorMode: EditorMode = .preview
    var searchQuery = ""
    var gitStatus: GitStatus?
    var commandOpen = false
    var switcherOpen = false
    var settingsOpen = false
    var cloneOpen = false
    var createOpen = false
    var errorMessage: String?
    var busyMessage: String?

    var inWorkspace: Bool { vault != nil || !tabs.isEmpty }
    var dark: Bool { settings.darkMode }
    var token: String? { KeychainService.load() }

    var activeTab: NoteTab? { tabs.first { $0.id == activeTabID } }
    var wordCount: Int { Markdown.wordCount(activeTab?.content ?? "") }

    private var saveTasks: [String: Task<Void, Never>] = [:]
    private var syncTask: Task<Void, Never>?

    init(settings: AppSettings? = nil, bootstrapOnLaunch: Bool = true) {
        self.settings = settings ?? SettingsStore.load()
        if bootstrapOnLaunch {
            Task { await bootstrap() }
        }
    }

    /// Loads GitHub identity if a token is already in the keychain, and opens `--vault`.
    func bootstrap() async {
        if let token {
            do {
                githubUser = try await GitHubService.user(token: token)
                githubRepos = try await GitHubService.repos(token: token)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--vault"), args.indices.contains(index + 1) {
            let path = args[index + 1]
            await openVault(path: path)
        }
    }

    func openVault(path: String) async {
        busyMessage = "Inspecting vault…"
        let info = await Task.detached { GitService.inspect(path: path) }.value
        await openVault(info)
    }

    /// Opens a GitHub-backed vault folder.
    func openVault(_ info: VaultInfo) async {
        if (!tabs.isEmpty || vault != nil), vault?.path != info.path, !(await flushDirtyTabs()) {
            busyMessage = nil
            return
        }
        vault = info
        remember(info)
        busyMessage = "Opening vault…"
        let path = info.path
        let token = info.isGitHub ? token : nil
        let hasRemote = info.remote != nil
        let pulled: GitStatus = await Task.detached {
            do {
                if hasRemote {
                    return try GitService.pull(path: path, token: token)
                }
                return GitService.status(path: path)
            } catch {
                return GitStatus(state: .error, branch: info.branch, remote: info.remote, message: error.localizedDescription)
            }
        }.value
        gitStatus = pulled
        if pulled.state == .error { errorMessage = pulled.message }
        await refreshVault(reconcileTabs: false)
        busyMessage = nil
        editorMode = .preview
        centerView = .editor
        rightPanel = .graph
        let featured = notes.first { $0.title.lowercased() == "writing is telepathy" }
        let evergreen = notes.first { $0.title.lowercased() == "evergreen notes" }
        if let featured {
            await openTab(path: featured.path)
            if let evergreen { await openTab(path: evergreen.path) }
            await openTab(path: featured.path)
        } else if let welcome = notes.first(where: { $0.title.lowercased() == "welcome" }) ?? notes.first {
            await openTab(path: welcome.path)
        }
    }

    /// Closes the current vault and returns to the welcome screen.
    func closeVault() async {
        guard await flushDirtyTabs() else { return }
        saveTasks.values.forEach { $0.cancel() }
        saveTasks = [:]
        syncTask?.cancel()
        vault = nil
        fileTree = []
        notes = []
        tabs = []
        activeTabID = nil
        gitStatus = nil
        centerView = .editor
    }

    /// Re-reads the vault tree and note index from disk.
    func refreshVault(reconcileTabs: Bool = false) async {
        guard let vault else { return }
        let root = URL(fileURLWithPath: vault.path)
        let snapshot = await Task.detached {
            (FileService.tree(at: root), FileService.index(at: root))
        }.value
        guard self.vault?.path == vault.path else { return }
        fileTree = snapshot.0
        notes = snapshot.1
        if reconcileTabs { reconcileOpenTabs(with: snapshot.1, vaultPath: vault.path) }
    }

    /// Opens a markdown file that is not inside a vault.
    func openStandaloneFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsOtherFileTypes = true
        panel.message = "Open a Markdown file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openStandalone(url: url) }
    }

    /// Opens a local folder as a vault (expected to be a git repo).
    func openLocalVault() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Open a GitHub repository folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await openVault(path: url.path)
    }

    /// Opens or focuses a tab for a note path.
    func openTab(path: String, standalone: Bool = false, content: String? = nil) async {
        if let existing = tabs.first(where: { $0.path == path }) {
            activeTabID = existing.id
            centerView = .editor
            return
        }
        do {
            let text: String
            if let content {
                text = content
            } else {
                text = try FileService.read(URL(fileURLWithPath: path))
            }
            let tab = NoteTab(
                path: path,
                title: Markdown.title(from: path),
                content: text,
                originalContent: text,
                isStandalone: standalone
            )
            tabs.append(tab)
            activeTabID = tab.id
            centerView = .editor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeTab(_ id: String? = nil) async {
        let target = id ?? activeTabID
        guard let target else { return }
        if let tab = tabs.first(where: { $0.id == target }), tab.dirty, !(await save(id: target, sync: false)) {
            return
        }
        saveTasks[target]?.cancel()
        saveTasks[target] = nil
        tabs.removeAll { $0.id == target }
        if activeTabID == target {
            activeTabID = tabs.last?.id
        }
    }

    func setActiveTab(_ id: String) {
        if let outgoing = activeTabID, outgoing != id,
           tabs.first(where: { $0.id == outgoing })?.dirty == true
        {
            Task { await save(id: outgoing, sync: false) }
        }
        activeTabID = id
        centerView = .editor
    }

    /// Updates editor text and schedules autosave plus GitHub sync.
    func updateContent(_ id: String, _ content: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].content = content
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            _ = await self.save(id: id, sync: false)
        }
        if settings.autoSync, vault != nil {
            syncTask?.cancel()
            syncTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1800))
                guard let self, !Task.isCancelled else { return }
                _ = await self.save(id: id, sync: true)
            }
        }
    }

    /// Writes the active note; optionally commit and push.
    func saveActive(sync: Bool) async {
        guard let id = activeTabID else { return }
        _ = await save(id: id, sync: sync)
    }

    @discardableResult
    func save(id: String, sync: Bool) async -> Bool {
        guard let tab = tabs.first(where: { $0.id == id }) else { return false }
        do {
            try FileService.write(URL(fileURLWithPath: tab.path), content: tab.content)
            if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
                tabs[index].originalContent = tabs[index].content
            }
            updateMetadata(for: tab.path, content: tab.content)
            if vault != nil {
                if sync { await syncNow(message: "Update \(tab.title)") }
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func flushDirtyTabs() async -> Bool {
        for id in tabs.filter(\.dirty).map(\.id) {
            guard await save(id: id, sync: false) else { return false }
        }
        return true
    }

    func newNote() async {
        if let vault {
            do {
                let url = try FileService.createNote(in: URL(fileURLWithPath: vault.path), name: "Untitled")
                await refreshVault()
                await openTab(path: url.path)
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Untitled.md"
        panel.message = "Save Markdown file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileService.write(url, content: "")
            await openTab(path: url.path, standalone: true, content: "")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dailyNote() async {
        guard let vault else { return }
        let dailyDir = URL(fileURLWithPath: vault.path).appendingPathComponent("Daily")
        let name = Markdown.dailyNoteName()
        let existing = dailyDir.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: existing.path) {
                await openTab(path: existing.path)
            } else {
                let url = try FileService.createNote(in: dailyDir, name: name)
                await refreshVault()
                await openTab(path: url.path)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createFolder(name: String) async {
        guard let vault, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            _ = try FileService.createFolder(
                in: URL(fileURLWithPath: vault.path),
                name: name.trimmingCharacters(in: .whitespaces)
            )
            await refreshVault()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deletePath(_ path: String) async {
        guard let vault else { return }
        do {
            let url = URL(fileURLWithPath: path)
            try FileService.moveToTrash(url, root: URL(fileURLWithPath: vault.path))
            let prefix = url.standardizedFileURL.path + "/"
            let removedIDs = tabs.filter { $0.path == path || $0.path.hasPrefix(prefix) }.map(\.id)
            removedIDs.forEach { saveTasks[$0]?.cancel(); saveTasks[$0] = nil }
            tabs.removeAll { $0.path == path || $0.path.hasPrefix(prefix) }
            if let activeTabID, removedIDs.contains(activeTabID) { self.activeTabID = tabs.last?.id }
            await refreshVault()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func followWikiLink(_ target: String) async {
        guard let vault else { return }
        do {
            let root = URL(fileURLWithPath: vault.path)
            let url = try await Task.detached {
                try FileService.createFromWiki(root: root, target: target)
            }.value
            await refreshVault()
            await openTab(path: url.path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func syncNow(message: String? = nil) async {
        guard let vault else { return }
        gitStatus = GitStatus(state: .syncing, branch: vault.branch, remote: vault.remote, message: "Syncing…")
        let path = vault.path
        let token = vault.isGitHub ? token : nil
        let msg = message ?? "Update \(activeTab?.title ?? "notes")"
        do {
            let status = try await Task.detached {
                try GitService.sync(path: path, message: msg, token: token)
            }.value
            gitStatus = status
            await refreshVault(reconcileTabs: true)
        } catch {
            gitStatus = GitStatus(state: .error, message: error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func saveToken(_ raw: String) async {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainService.save(token: normalized)
            githubUser = try await GitHubService.user(token: normalized)
            githubRepos = try await GitHubService.repos(token: normalized)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cloneVault(input: String) async {
        guard let parsed = GitHubService.parseRepo(input) else {
            errorMessage = GitHubError.badInput.localizedDescription
            return
        }
        guard let token else {
            errorMessage = GitHubError.noToken.localizedDescription
            settingsOpen = true
            return
        }
        busyMessage = "Cloning…"
        do {
            let dest = URL(fileURLWithPath: settings.vaultsRoot, isDirectory: true)
            let cloneURL = "https://github.com/\(parsed.owner)/\(parsed.repo).git"
            let url = try await Task.detached {
                try GitService.clone(cloneURL: cloneURL, destDir: dest, token: token)
            }.value
            cloneOpen = false
            busyMessage = nil
            await openVault(path: url.path)
        } catch {
            busyMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    func createGithubVault(name: String, isPrivate: Bool) async {
        guard let token else {
            errorMessage = GitHubError.noToken.localizedDescription
            settingsOpen = true
            return
        }
        busyMessage = "Creating repository…"
        do {
            let repo = try await GitHubService.createRepo(name: name, isPrivate: isPrivate, token: token)
            let dest = URL(fileURLWithPath: settings.vaultsRoot, isDirectory: true)
                .appendingPathComponent(repo.name)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let welcome = """
            # Welcome to \(repo.name)

            This vault is a GitHub repository. Saving a note commits and pushes to origin.

            Try a wiki link: [[Welcome]]
            """
            try FileService.write(dest.appendingPathComponent("Welcome.md"), content: welcome)
            let tokenCopy = token
            _ = try await Task.detached {
                try GitService.initAndPush(
                    path: dest.path,
                    remoteURL: repo.cloneURL,
                    message: "Initial commit from Vulkan Glass",
                    token: tokenCopy
                )
            }.value
            createOpen = false
            busyMessage = nil
            await openVault(path: dest.path)
        } catch {
            busyMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    func loadRepos() async {
        guard let token else { return }
        githubRepos = (try? await GitHubService.repos(token: token)) ?? []
    }

    func patchSettings(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        SettingsStore.save(settings)
    }

    private func remember(_ info: VaultInfo) {
        let entry = RecentVault(
            name: info.name,
            path: info.path,
            remote: info.remote,
            lastOpened: Date().timeIntervalSince1970
        )
        settings.recentVaults = [entry] + settings.recentVaults.filter { $0.path != info.path }
        settings.recentVaults = Array(settings.recentVaults.prefix(12))
        SettingsStore.save(settings)
    }

    private func updateMetadata(for path: String, content: String) {
        guard let vault else { return }
        let canonicalRoot = FileService.canonicalURL(URL(fileURLWithPath: vault.path)).path
        let canonicalPath = FileService.canonicalURL(URL(fileURLWithPath: path)).path
        guard canonicalPath.hasPrefix(canonicalRoot + "/") else { return }
        let relative = String(canonicalPath.dropFirst(canonicalRoot.count + 1))
        let metadata = FileService.metadata(path: canonicalPath, relativePath: relative, content: content)
        if let index = notes.firstIndex(where: {
            FileService.canonicalURL(URL(fileURLWithPath: $0.path)).path == canonicalPath
        }) {
            notes[index] = metadata
        } else {
            notes.append(metadata)
            notes.sort { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
        }
    }

    private func reconcileOpenTabs(with indexedNotes: [NoteMeta], vaultPath: String) {
        let diskByPath = Dictionary(uniqueKeysWithValues: indexedNotes.map {
            (FileService.canonicalURL(URL(fileURLWithPath: $0.path)).path, $0.content)
        })
        let rootPrefix = FileService.canonicalURL(URL(fileURLWithPath: vaultPath)).path + "/"
        var conflicts: [String] = []
        for index in tabs.indices {
            let canonicalTabPath = FileService.canonicalURL(URL(fileURLWithPath: tabs[index].path)).path
            guard canonicalTabPath.hasPrefix(rootPrefix), let disk = diskByPath[canonicalTabPath] else { continue }
            if tabs[index].dirty {
                if disk != tabs[index].originalContent { conflicts.append(tabs[index].title) }
            } else {
                tabs[index].content = disk
                tabs[index].originalContent = disk
            }
        }
        if !conflicts.isEmpty {
            errorMessage = "Remote changes conflict with unsaved edits in: \(conflicts.joined(separator: ", ")). Your edits were preserved."
        }
    }

    private func openStandalone(url: URL) async {
        guard await flushDirtyTabs() else { return }
        vault = nil
        fileTree = []
        notes = []
        gitStatus = GitStatus(state: .idle, message: "Standalone file — not a GitHub vault")
        do {
            let text = try FileService.read(url)
            let tab = NoteTab(
                path: url.path,
                title: Markdown.title(from: url.path),
                content: text,
                originalContent: text,
                isStandalone: true
            )
            tabs = [tab]
            activeTabID = tab.id
            centerView = .editor
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
