import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct AppModelDependencies {
    var githubCLIStatus: (Bool) async -> GitHubCLIStatus
    var githubUser: (String) async throws -> GitHubUser
    var githubRepos: (String) async throws -> [GitHubRepo]
    var loadKeychainToken: () -> String?
    var saveKeychainToken: (String) throws -> Void
    var authenticationDisabled: () -> Bool = { false }
    var chooseNewStandaloneNoteURL: @MainActor () -> URL? = { nil }
    var syncGit: (String, String, GitCredential?) async throws -> GitStatus = { path, message, credential in
        try await Task.detached {
            try GitService.sync(path: path, message: message, credential: credential)
        }.value
    }
    var renameFile: (URL, String, URL?) async throws -> URL = { source, name, root in
        try await Task.detached {
            try FileService.rename(source, to: name, root: root)
        }.value
    }

    static let live = AppModelDependencies(
        githubCLIStatus: { includeToken in
            await Task.detached { GitHubCLIService.status(includeToken: includeToken) }.value
        },
        githubUser: { try await GitHubService.user(token: $0) },
        githubRepos: { try await GitHubService.repos(token: $0) },
        loadKeychainToken: { KeychainService.load() },
        saveKeychainToken: { try KeychainService.save(token: $0) },
        authenticationDisabled: { DevelopmentAuthentication.isDisabledForThisProcess },
        chooseNewStandaloneNoteURL: {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "Untitled.md"
            panel.message = "Save Markdown file"
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
    )
}

enum DevelopmentAuthentication {
    static let environmentKey = "VULKANGLASS_DISABLE_AUTH"
    static let launchArgument = "--disable-auth"

    /// XCTest publishes these into the host application's environment before any app code runs.
    static let testEnvironmentKeys = [
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "XCTestSessionIdentifier"
    ]

    /// Resolved once per process: launch arguments and environment cannot change after launch,
    /// and this is read from SwiftUI view bodies.
    static let isDisabledForThisProcess = isDisabled()

    /// Development-only escape hatch. Release builds always authenticate normally so a
    /// shipped app cannot be silently downgraded by a launch argument or environment variable.
    static func isDisabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        #if DEBUG
        if arguments.contains(launchArgument) { return true }
        if isRunningTests(environment: environment) { return true }
        guard let value = environment[environmentKey] else { return false }
        return ["1", "true", "yes", "on"].contains(
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
        #else
        return false
        #endif
    }

    /// True while hosting an XCTest bundle. The unit tests run inside the real app, so its
    /// launch would otherwise reach the Keychain and `gh` through `AppModel.bootstrap()`.
    static func isRunningTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        testEnvironmentKeys.contains { environment[$0] != nil }
    }
}

@MainActor
struct SystemAppearanceProvider {
    var currentDarkMode: () -> Bool
    var observeDarkMode: (@escaping @MainActor @Sendable (Bool) -> Void) -> NSKeyValueObservation?

    static let live = SystemAppearanceProvider(
        currentDarkMode: {
            isDark(NSApplication.shared.effectiveAppearance)
        },
        observeDarkMode: { handler in
            let application = NSApplication.shared
            return application.observe(\.effectiveAppearance, options: [.new]) { _, change in
                guard let appearance = change.newValue else { return }
                let isDarkMode = isDark(appearance)
                Task { @MainActor in handler(isDarkMode) }
            }
        }
    )

    nonisolated static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

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
    var titleEditingTabID: String?
    private(set) var titleEditingDraft = ""
    private(set) var editorFocusRequest: EditorFocusRequest?
    var leftOpen = true
    var rightOpen = true
    var leftPanel: LeftPanel = .files
    var rightPanel: RightPanel = .graph
    var centerView: CenterView = .editor
    var editorMode: EditorMode {
        get {
            guard let activeTabID,
                  let index = tabs.firstIndex(where: { $0.id == activeTabID })
            else { return defaultEditorMode }
            return tabs[index].editorMode
        }
        set {
            guard let activeTabID,
                  let index = tabs.firstIndex(where: { $0.id == activeTabID })
            else {
                defaultEditorMode = newValue
                return
            }
            tabs[index].editorMode = newValue
        }
    }
    var searchQuery = ""
    var gitStatus: GitStatus?
    var commandOpen = false
    var switcherOpen = false
    var settingsOpen = false
    var cloneOpen = false
    var createOpen = false
    var errorMessage: String?
    var busyMessage: String?
    var githubCLIStatus = GitHubCLIStatus()
    var githubAuthSource: GitHubAuthSource?
    private(set) var systemDarkMode: Bool

    /// True when this launch runs local-only: no Keychain, no `gh`, no GitHub network calls.
    var authenticationDisabled: Bool { dependencies.authenticationDisabled() }

    var inWorkspace: Bool { vault != nil || !tabs.isEmpty }
    var dark: Bool {
        switch settings.appearanceMode {
        case .inherit: systemDarkMode
        case .light: false
        case .dark: true
        }
    }
    var token: String? { activeToken }
    var gitCredential: GitCredential? {
        guard let activeToken, let githubAuthSource else { return nil }
        switch githubAuthSource {
        case .gitHubCLI:
            guard let executablePath = githubCLIStatus.executablePath else { return nil }
            return .gitHubCLI(executablePath: executablePath)
        case .personalAccessToken:
            return .personalAccessToken(activeToken)
        }
    }

    private var activeToken: String?
    private let dependencies: AppModelDependencies
    private var defaultEditorMode: EditorMode = .preview
    private var githubConnectionGeneration = 0
    @ObservationIgnored private var systemAppearanceObservation: NSKeyValueObservation?

    var activeTab: NoteTab? { tabs.first { $0.id == activeTabID } }
    var wordCount: Int { Markdown.wordCount(activeTab?.content ?? "") }

    private var saveTasks: [String: Task<Void, Never>] = [:]
    private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var titleCommitTask: Task<Bool, Never>?
    @ObservationIgnored private var titleCommitTabID: String?
    @ObservationIgnored private var titleCommitGeneration: UUID?
    @ObservationIgnored private var titleSubmissions: [UUID: String] = [:]
    @ObservationIgnored private var latestTitleSubmissionID: UUID?

    init(
        settings: AppSettings? = nil,
        systemDarkMode: Bool? = nil,
        bootstrapOnLaunch: Bool = true,
        dependencies: AppModelDependencies = .live,
        systemAppearanceProvider: SystemAppearanceProvider? = nil
    ) {
        let appearanceProvider = systemAppearanceProvider ?? .live
        self.settings = settings ?? SettingsStore.load()
        self.systemDarkMode = systemDarkMode ?? appearanceProvider.currentDarkMode()
        self.dependencies = dependencies
        if systemDarkMode == nil {
            systemAppearanceObservation = appearanceProvider.observeDarkMode { [weak self] isDark in
                self?.updateSystemDarkMode(isDark)
            }
        }
        if bootstrapOnLaunch {
            Task { await bootstrap() }
        }
    }

    func updateSystemDarkMode(_ isDark: Bool) {
        systemDarkMode = isDark
    }

    /// Loads GitHub identity from GitHub CLI or a saved PAT, then opens `--vault`.
    func bootstrap() async {
        await connectGitHub()
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--vault"), args.indices.contains(index + 1) {
            let path = args[index + 1]
            await openVault(path: path)
        }
    }

    /// Resolves a GitHub token from `gh` (when enabled and available) or the Keychain PAT.
    func connectGitHub() async {
        githubConnectionGeneration &+= 1
        if authenticationDisabled {
            githubCLIStatus = GitHubCLIStatus()
            clearGitHubConnection(error: nil)
            return
        }
        let generation = githubConnectionGeneration
        let useCLI = settings.useGitHubCLI
        let status = await dependencies.githubCLIStatus(useCLI)
        guard isCurrentGitHubConnection(generation, useCLI: useCLI) else { return }
        githubCLIStatus = status
        let candidates = GitHubAuthResolver.candidates(
            useCLI: useCLI,
            cliToken: status.token,
            keychainToken: dependencies.loadKeychainToken()
        )
        if candidates.isEmpty {
            clearGitHubConnection(error: nil)
            return
        }
        var lastError: Error?
        for candidate in candidates {
            do {
                let user = try await dependencies.githubUser(candidate.token)
                guard isCurrentGitHubConnection(generation, useCLI: useCLI) else { return }
                let repos = try await dependencies.githubRepos(candidate.token)
                guard isCurrentGitHubConnection(generation, useCLI: useCLI) else { return }
                githubUser = user
                githubRepos = repos
                activeToken = candidate.token
                githubAuthSource = candidate.source
                errorMessage = nil
                return
            } catch {
                guard isCurrentGitHubConnection(generation, useCLI: useCLI) else { return }
                lastError = error
            }
        }
        clearGitHubConnection(error: lastError)
    }

    /// Inspects and opens a vault folder. Missing paths toast and return to welcome.
    func openVault(path: String) async {
        busyMessage = "Inspecting vault…"
        guard FileService.directoryExists(at: path) else {
            guard await commitTitleEditing() else {
                busyMessage = nil
                return
            }
            rejectMissingVault(path: path, name: URL(fileURLWithPath: path).lastPathComponent)
            return
        }
        let info = await Task.detached { GitService.inspect(path: path) }.value
        await openVault(info)
    }

    /// Opens a GitHub-backed vault folder.
    func openVault(_ info: VaultInfo) async {
        guard FileService.directoryExists(at: info.path) else {
            guard await commitTitleEditing() else { return }
            rejectMissingVault(path: info.path, name: info.name)
            return
        }
        if (!tabs.isEmpty || vault != nil), vault?.path != info.path {
            guard await commitTitleEditing() else {
                busyMessage = nil
                return
            }
        }
        if (!tabs.isEmpty || vault != nil), vault?.path != info.path, !(await flushDirtyTabs()) {
            busyMessage = nil
            return
        }
        vault = info
        remember(info)
        busyMessage = "Opening vault…"
        let path = info.path
        let authenticationDisabled = self.authenticationDisabled
        let credential = info.isGitHub ? gitCredential : nil
        let hasRemote = info.remote != nil
        let pulled: GitStatus = await Task.detached {
            do {
                if hasRemote, !authenticationDisabled {
                    return try GitService.pull(path: path, credential: credential)
                }
                var status = GitService.status(path: path)
                if hasRemote, authenticationDisabled {
                    status.message = "Local only — GitHub auth disabled for development"
                }
                return status
            } catch {
                return GitStatus(state: .error, branch: info.branch, remote: info.remote, message: error.localizedDescription)
            }
        }.value
        gitStatus = pulled
        if pulled.state == .error { errorMessage = pulled.message }
        await refreshVault(reconcileTabs: false)
        busyMessage = nil
        defaultEditorMode = .preview
        for index in tabs.indices {
            tabs[index].editorMode = .preview
        }
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
        guard await commitTitleEditing() else { return }
        guard await flushDirtyTabs() else { return }
        saveTasks.values.forEach { $0.cancel() }
        saveTasks = [:]
        syncTask?.cancel()
        vault = nil
        fileTree = []
        notes = []
        editorFocusRequest = nil
        titleEditingTabID = nil
        titleEditingDraft = ""
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
        if activeTabID != path {
            guard await commitTitleEditing() else { return }
        }
        if let existing = tabs.first(where: { $0.path == path }) {
            editorFocusRequest = nil
            titleEditingTabID = nil
            titleEditingDraft = ""
            activeTabID = existing.id
            centerView = .editor
            return
        }
        do {
            let inheritedEditorMode = editorMode
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
                isStandalone: standalone,
                editorMode: inheritedEditorMode
            )
            tabs.append(tab)
            editorFocusRequest = nil
            titleEditingTabID = nil
            titleEditingDraft = ""
            activeTabID = tab.id
            centerView = .editor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeTab(_ id: String? = nil) async {
        let target = id ?? activeTabID
        guard let target else { return }
        let wasActive = activeTabID == target
        if titleEditingTabID == target || titleCommitTabID == target {
            guard await commitTitleEditing(for: target) else { return }
        }
        let resolvedTarget = wasActive ? (activeTabID ?? target) : target
        if let tab = tabs.first(where: { $0.id == resolvedTarget }), tab.dirty,
           !(await save(id: resolvedTarget, sync: false))
        {
            return
        }
        saveTasks[resolvedTarget]?.cancel()
        saveTasks[resolvedTarget] = nil
        if titleEditingTabID == resolvedTarget {
            titleEditingTabID = nil
            titleEditingDraft = ""
        }
        if editorFocusRequest?.tabID == resolvedTarget {
            editorFocusRequest = nil
        }
        tabs.removeAll { $0.id == resolvedTarget }
        if activeTabID == resolvedTarget {
            activeTabID = tabs.last?.id
        }
    }

    func setActiveTab(_ id: String) async {
        guard id != activeTabID else { return }
        guard await commitTitleEditing() else { return }
        if let outgoing = activeTabID, outgoing != id,
           tabs.first(where: { $0.id == outgoing })?.dirty == true
        {
            // Track the flush in `saveTasks` so it is cancellable and awaitable like any other
            // autosave; it supersedes the pending debounce for the same tab.
            saveTasks[outgoing]?.cancel()
            saveTasks[outgoing] = Task { [weak self] in
                _ = await self?.save(id: outgoing, sync: false)
            }
        }
        if titleEditingTabID != id {
            titleEditingTabID = nil
        }
        editorFocusRequest = nil
        activeTabID = id
        centerView = .editor
    }

    func beginEditingTitle(for id: String) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        editorFocusRequest = nil
        titleEditingTabID = id
        titleEditingDraft = tab.title
    }

    func updateTitleDraft(for id: String, draft: String) {
        guard titleEditingTabID == id else { return }
        titleEditingDraft = draft
    }

    func endEditingTitle(for id: String) {
        if titleEditingTabID == id {
            titleEditingTabID = nil
            titleEditingDraft = ""
            if activeTabID == id, editorMode == .source {
                editorFocusRequest = EditorFocusRequest(tabID: id, placement: .start)
            }
        }
    }

    /// Commits the current draft before navigation mutates or removes its tab. The task is
    /// retained so a simultaneous close or vault replacement waits for the same filesystem move.
    @discardableResult
    func commitTitleEditing(for id: String? = nil) async -> Bool {
        if let pending = titleCommitTask,
           id == nil || titleCommitTabID == id
        {
            return await pending.value
        }
        guard let target = titleEditingTabID,
              id == nil || id == target,
              tabs.contains(where: { $0.id == target })
        else { return true }

        let draft = titleEditingDraft
        titleEditingTabID = nil
        titleEditingDraft = ""
        let generation = UUID()
        titleCommitGeneration = generation
        titleCommitTabID = target
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.renameNote(path: target, newName: draft, sync: false)
        }
        titleCommitTask = task
        let committed = await task.value
        if titleCommitGeneration == generation {
            if committed, settings.autoSync, let vaultPath = vault?.path,
               !tabs.contains(where: { $0.path == target }) {
                let message = "Rename \(Markdown.title(from: target)) to \(draft)"
                Task { [weak self] in
                    guard let self, self.vault?.path == vaultPath else { return }
                    await self.syncNow(message: message)
                }
            }
            titleCommitTask = nil
            titleCommitTabID = nil
            titleCommitGeneration = nil
        }
        if !committed,
           titleEditingTabID == nil,
           tabs.contains(where: { $0.id == target })
        {
            titleEditingTabID = target
            titleEditingDraft = draft
        }
        return committed
    }

    /// Return in the title saves the name and hands typing over to the top of the document.
    func submitTitleEditing(for id: String, draft: String) async {
        guard titleEditingTabID == id || titleCommitTabID == id else { return }
        updateTitleDraft(for: id, draft: draft)
        let submissionID = UUID()
        latestTitleSubmissionID = submissionID
        titleSubmissions[submissionID] = id
        let committed = await commitTitleEditing(for: id)
        // A rename retargets the tracked ID, and any navigation during the commit moves the
        // active tab away from it, so only the renamed note that is still in front takes focus.
        let target = titleSubmissions.removeValue(forKey: submissionID)
        guard committed,
              latestTitleSubmissionID == submissionID,
              let target,
              activeTabID == target,
              titleEditingTabID == nil,
              editorMode == .source
        else { return }
        latestTitleSubmissionID = nil
        editorFocusRequest = EditorFocusRequest(tabID: target, placement: .start)
    }

    /// Awaits every in-flight autosave, including debounced writes that have not fired yet.
    /// Lets callers (and tests) observe persisted content without guessing at a sleep duration.
    func awaitPendingSaves() async {
        var awaited: Set<String> = []
        while true {
            let pending = saveTasks.filter { !awaited.contains($0.key) }
            guard !pending.isEmpty else { return }
            for (id, task) in pending {
                awaited.insert(id)
                await task.value
            }
        }
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
        guard await commitTitleEditing() else { return }
        if let vault {
            do {
                let url = try FileService.createNote(in: URL(fileURLWithPath: vault.path), name: "Untitled")
                await refreshVault()
                await openTab(path: url.path)
                prepareNewNoteForEditing(at: url.path, editingTitle: true)
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        guard let url = dependencies.chooseNewStandaloneNoteURL() else { return }
        do {
            try FileService.write(url, content: "")
            await openTab(path: url.path, standalone: true, content: "")
            prepareNewNoteForEditing(at: url.path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dailyNote() async {
        guard let vault else { return }
        guard await commitTitleEditing() else { return }
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
                prepareNewNoteForEditing(at: url.path)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createFolder(name: String) async {
        guard let vault else { return }
        do {
            _ = try FileService.createFolder(
                in: URL(fileURLWithPath: vault.path),
                name: name
            )
            await refreshVault()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Renames a note on disk and retargets any open tab for that file.
    @discardableResult
    func renameNote(path: String, newName: String, sync: Bool = true) async -> Bool {
        let currentTitle = Markdown.title(from: path)
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var proposed = trimmed
        if proposed.lowercased().hasSuffix(".md") {
            proposed.removeLast(3)
            proposed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard proposed != currentTitle else { return true }

        if let tab = tabs.first(where: { $0.path == path }), tab.dirty {
            guard await save(id: tab.id, sync: false) else { return false }
        }

        let root = vault.map { URL(fileURLWithPath: $0.path) }
        do {
            let source = URL(fileURLWithPath: path)
            let dest = try await dependencies.renameFile(source, newName, root)
            retargetOpenItems(from: path, to: dest.path)
            if vault != nil {
                await refreshVault(reconcileTabs: true)
                if let aligned = notes.first(where: {
                    FileService.canonicalURL(URL(fileURLWithPath: $0.path)).path
                        == FileService.canonicalURL(dest).path
                })?.path, aligned != dest.path {
                    retargetOpenItems(from: dest.path, to: aligned)
                }
                if sync && settings.autoSync {
                    await syncNow(message: "Rename \(currentTitle) to \(Markdown.title(from: dest.path))")
                }
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
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
            if let titleEditingTabID, removedIDs.contains(titleEditingTabID) {
                self.titleEditingTabID = nil
                titleEditingDraft = ""
            }
            if let requestedTabID = editorFocusRequest?.tabID,
               removedIDs.contains(requestedTabID)
            {
                editorFocusRequest = nil
            }
            tabs.removeAll { $0.path == path || $0.path.hasPrefix(prefix) }
            if let activeTabID, removedIDs.contains(activeTabID) { self.activeTabID = tabs.last?.id }
            await refreshVault()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func followWikiLink(_ target: String) async {
        guard let vault else { return }
        guard await commitTitleEditing() else { return }
        do {
            let root = URL(fileURLWithPath: vault.path)
            let resolution = try await Task.detached {
                try FileService.createFromWiki(root: root, target: target)
            }.value
            await refreshVault()
            await openTab(path: resolution.url.path)
            if resolution.wasCreated {
                prepareNewNoteForEditing(at: resolution.url.path)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func syncNow(message: String? = nil) async {
        guard let vault else { return }
        guard !authenticationDisabled else {
            gitStatus = GitStatus(
                state: .idle,
                branch: vault.branch,
                remote: vault.remote,
                message: "Local only — GitHub auth disabled for development"
            )
            return
        }
        gitStatus = GitStatus(state: .syncing, branch: vault.branch, remote: vault.remote, message: "Syncing…")
        let path = vault.path
        let credential = vault.isGitHub ? gitCredential : nil
        let msg = message ?? "Update \(activeTab?.title ?? "notes")"
        do {
            let status = try await dependencies.syncGit(path, msg, credential)
            guard self.vault?.path == path else { return }
            gitStatus = status
            await refreshVault(reconcileTabs: true)
        } catch {
            guard self.vault?.path == path else { return }
            gitStatus = GitStatus(state: .error, message: error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func saveToken(_ raw: String) async {
        guard !authenticationDisabled else {
            errorMessage = "GitHub authentication is disabled for this development launch."
            return
        }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            errorMessage = GitHubError.noToken.localizedDescription
            return
        }
        do {
            _ = try await dependencies.githubUser(normalized)
            _ = try await dependencies.githubRepos(normalized)
            try dependencies.saveKeychainToken(normalized)
            errorMessage = nil
            await connectGitHub()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cloneVault(input: String) async {
        guard let parsed = GitHubService.parseRepo(input) else {
            errorMessage = GitHubError.badInput.localizedDescription
            return
        }
        guard token != nil, let credential = gitCredential else {
            errorMessage = GitHubError.noToken.localizedDescription
            settingsOpen = true
            return
        }
        busyMessage = "Cloning…"
        do {
            let dest = URL(fileURLWithPath: settings.vaultsRoot, isDirectory: true)
            let cloneURL = "https://github.com/\(parsed.owner)/\(parsed.repo).git"
            let url = try await Task.detached {
                try GitService.clone(cloneURL: cloneURL, destDir: dest, credential: credential)
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
        guard let token, let credential = gitCredential else {
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
            _ = try await Task.detached {
                try GitService.initAndPush(
                    path: dest.path,
                    remoteURL: repo.cloneURL,
                    message: "Initial commit from Vulkan Glass",
                    credential: credential
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
        githubRepos = (try? await dependencies.githubRepos(token)) ?? []
    }

    private func isCurrentGitHubConnection(_ generation: Int, useCLI: Bool) -> Bool {
        generation == githubConnectionGeneration && settings.useGitHubCLI == useCLI
    }

    private func clearGitHubConnection(error: Error?) {
        activeToken = nil
        githubAuthSource = nil
        githubUser = nil
        githubRepos = []
        errorMessage = error?.localizedDescription
    }

    func patchSettings(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        SettingsStore.save(settings)
    }

    /// Updates open tabs after a file is renamed on disk.
    private func retargetOpenItems(from oldPath: String, to newPath: String) {
        if let task = saveTasks.removeValue(forKey: oldPath) {
            task.cancel()
        }
        if let index = tabs.firstIndex(where: { $0.path == oldPath }) {
            tabs[index].path = newPath
            tabs[index].title = Markdown.title(from: newPath)
        }
        if activeTabID == oldPath {
            activeTabID = newPath
        }
        if titleEditingTabID == oldPath {
            titleEditingTabID = newPath
        }
        if let request = editorFocusRequest, request.tabID == oldPath {
            editorFocusRequest = EditorFocusRequest(
                id: request.id,
                tabID: newPath,
                placement: request.placement
            )
        }
        if titleCommitTabID == oldPath {
            titleCommitTabID = newPath
        }
        for submissionID in titleSubmissions.filter({ $0.value == oldPath }).map(\.key) {
            titleSubmissions[submissionID] = newPath
        }
    }

    /// New notes always begin in source mode. A note created with a placeholder name starts with
    /// that name selected in the title so typing replaces it; a note whose name was already
    /// chosen (daily notes, wiki links, a save panel) starts with the document ready for typing.
    private func prepareNewNoteForEditing(at path: String, editingTitle: Bool = false) {
        guard tabs.contains(where: { $0.id == path }) else { return }
        editorMode = .source
        centerView = .editor
        if editingTitle {
            editorFocusRequest = nil
            titleEditingTabID = path
            titleEditingDraft = Markdown.title(from: path)
        } else {
            titleEditingTabID = nil
            titleEditingDraft = ""
            editorFocusRequest = EditorFocusRequest(tabID: path)
        }
    }

    func fulfillEditorFocusRequest(_ id: UUID) {
        guard editorFocusRequest?.id == id else { return }
        editorFocusRequest = nil
    }

    /// Shows a toast and returns to the welcome screen when a vault folder is gone.
    private func rejectMissingVault(path: String, name: String) {
        busyMessage = nil
        errorMessage = FileServiceError.missingVault(name).localizedDescription
        forgetRecent(path: path)
        if vault == nil || vault?.path == path {
            saveTasks.values.forEach { $0.cancel() }
            saveTasks = [:]
            syncTask?.cancel()
            vault = nil
            fileTree = []
            notes = []
            editorFocusRequest = nil
            titleEditingTabID = nil
            titleEditingDraft = ""
            tabs = []
            activeTabID = nil
            gitStatus = nil
            centerView = .editor
        }
    }

    /// Drops a vanished vault from the recents list so it cannot trap the user again.
    private func forgetRecent(path: String) {
        let remaining = settings.recentVaults.filter { $0.path != path }
        guard remaining.count != settings.recentVaults.count else { return }
        settings.recentVaults = remaining
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

    func openStandalone(url: URL) async {
        guard await commitTitleEditing() else { return }
        guard await flushDirtyTabs() else { return }
        let inheritedEditorMode = editorMode
        vault = nil
        fileTree = []
        notes = []
        editorFocusRequest = nil
        gitStatus = GitStatus(state: .idle, message: "Standalone file — not a GitHub vault")
        do {
            let text = try FileService.read(url)
            let tab = NoteTab(
                path: url.path,
                title: Markdown.title(from: url.path),
                content: text,
                originalContent: text,
                isStandalone: true,
                editorMode: inheritedEditorMode
            )
            titleEditingTabID = nil
            titleEditingDraft = ""
            tabs = [tab]
            activeTabID = tab.id
            centerView = .editor
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
