import Foundation

enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case inherit
    case light
    case dark
}

struct RecentVault: Codable, Identifiable, Hashable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var remote: String?
    var lastOpened: TimeInterval
}

struct AppSettings: Codable, Sendable {
    var recentVaults: [RecentVault]
    var vaultsRoot: String
    var autoSync: Bool
    var appearanceMode: AppearanceMode
    var useGitHubCLI: Bool
    var loadRemoteImages: Bool
    var leftSidebarWidth: CGFloat
    var rightSidebarWidth: CGFloat

    static func `default`() -> AppSettings {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("VulkanGlass", isDirectory: true).path
        return AppSettings(
            recentVaults: [],
            vaultsRoot: root,
            autoSync: true,
            appearanceMode: .inherit,
            useGitHubCLI: true,
            loadRemoteImages: false,
            leftSidebarWidth: VGTheme.sidebarWidth,
            rightSidebarWidth: VGTheme.sidebarWidth
        )
    }

    init(
        recentVaults: [RecentVault],
        vaultsRoot: String,
        autoSync: Bool,
        appearanceMode: AppearanceMode = .inherit,
        useGitHubCLI: Bool = true,
        loadRemoteImages: Bool = false,
        leftSidebarWidth: CGFloat = VGTheme.sidebarWidth,
        rightSidebarWidth: CGFloat = VGTheme.sidebarWidth
    ) {
        self.recentVaults = recentVaults
        self.vaultsRoot = vaultsRoot
        self.autoSync = autoSync
        self.appearanceMode = appearanceMode
        self.useGitHubCLI = useGitHubCLI
        self.loadRemoteImages = loadRemoteImages
        self.leftSidebarWidth = leftSidebarWidth
        self.rightSidebarWidth = rightSidebarWidth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recentVaults = try container.decode([RecentVault].self, forKey: .recentVaults)
        vaultsRoot = try container.decode(String.self, forKey: .vaultsRoot)
        autoSync = try container.decode(Bool.self, forKey: .autoSync)
        if let savedAppearance = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearanceMode) {
            appearanceMode = savedAppearance
        } else if let legacyDarkMode = try container.decodeIfPresent(Bool.self, forKey: .darkMode) {
            appearanceMode = legacyDarkMode ? .dark : .light
        } else {
            appearanceMode = .inherit
        }
        useGitHubCLI = try container.decodeIfPresent(Bool.self, forKey: .useGitHubCLI) ?? true
        loadRemoteImages = try container.decodeIfPresent(Bool.self, forKey: .loadRemoteImages) ?? false
        leftSidebarWidth = try container.decodeIfPresent(CGFloat.self, forKey: .leftSidebarWidth) ?? VGTheme.sidebarWidth
        rightSidebarWidth = try container.decodeIfPresent(CGFloat.self, forKey: .rightSidebarWidth) ?? VGTheme.sidebarWidth
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recentVaults, forKey: .recentVaults)
        try container.encode(vaultsRoot, forKey: .vaultsRoot)
        try container.encode(autoSync, forKey: .autoSync)
        try container.encode(appearanceMode, forKey: .appearanceMode)
        // Keep settings readable by the previous release during the migration window.
        // Inherit has no legacy representation, so use the non-dark fallback.
        try container.encode(appearanceMode == .dark, forKey: .darkMode)
        try container.encode(useGitHubCLI, forKey: .useGitHubCLI)
        try container.encode(loadRemoteImages, forKey: .loadRemoteImages)
        try container.encode(leftSidebarWidth, forKey: .leftSidebarWidth)
        try container.encode(rightSidebarWidth, forKey: .rightSidebarWidth)
    }

    private enum CodingKeys: String, CodingKey {
        case recentVaults
        case vaultsRoot
        case autoSync
        case appearanceMode
        case darkMode
        case useGitHubCLI
        case loadRemoteImages
        case leftSidebarWidth
        case rightSidebarWidth
    }
}

struct VaultInfo: Identifiable, Hashable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var remote: String?
    var branch: String?
    var isGitHub: Bool
}

struct FileNode: Identifiable, Hashable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
    var children: [FileNode]?
}

struct NoteHeading: Hashable, Sendable {
    var level: Int
    var text: String
    var line: Int
}

struct NoteMeta: Identifiable, Hashable, Sendable {
    var id: String { path }
    var path: String
    var relativePath: String
    var title: String
    var content: String
    var tags: [String]
    var wikiLinks: [String]
    var headings: [NoteHeading]
}

struct NoteTab: Identifiable, Equatable, Sendable {
    var id: String { path }
    var path: String
    var title: String
    var content: String
    var originalContent: String
    var isStandalone: Bool
    var editorMode: EditorMode = .preview

    var dirty: Bool { content != originalContent }
}

struct EditorFocusRequest: Equatable, Sendable {
    /// Where the insertion point lands when the document body takes focus.
    enum Placement: Equatable, Sendable {
        case start
        case end
    }

    let id: UUID
    let tabID: String
    let placement: Placement

    init(id: UUID = UUID(), tabID: String, placement: Placement = .end) {
        self.id = id
        self.tabID = tabID
        self.placement = placement
    }
}

struct GitHubUser: Sendable {
    var login: String
    var name: String?
    var avatarURL: String
}

struct GitHubRepo: Identifiable, Sendable {
    var id: Int
    var name: String
    var fullName: String
    var description: String?
    var isPrivate: Bool
    var cloneURL: String
    var htmlURL: String
}

enum GitSyncState: String, Sendable {
    case idle
    case syncing
    case synced
    case error
}

struct GitStatus: Sendable {
    var state: GitSyncState
    var branch: String?
    var remote: String?
    var message: String?
}

enum LeftPanel: String, Sendable {
    case files
    case search
}

enum RightPanel: String, Sendable {
    case graph
    case backlinks
    case outline
    case tags
}

enum CenterView: String, Sendable {
    case editor
    case graph
}

enum EditorMode: String, Sendable {
    case source
    case preview
}
