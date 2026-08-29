import Foundation

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
    var darkMode: Bool
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
            darkMode: true,
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
        darkMode: Bool,
        useGitHubCLI: Bool = true,
        loadRemoteImages: Bool = false,
        leftSidebarWidth: CGFloat = VGTheme.sidebarWidth,
        rightSidebarWidth: CGFloat = VGTheme.sidebarWidth
    ) {
        self.recentVaults = recentVaults
        self.vaultsRoot = vaultsRoot
        self.autoSync = autoSync
        self.darkMode = darkMode
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
        darkMode = try container.decode(Bool.self, forKey: .darkMode)
        useGitHubCLI = try container.decodeIfPresent(Bool.self, forKey: .useGitHubCLI) ?? true
        loadRemoteImages = try container.decodeIfPresent(Bool.self, forKey: .loadRemoteImages) ?? false
        leftSidebarWidth = try container.decodeIfPresent(CGFloat.self, forKey: .leftSidebarWidth) ?? VGTheme.sidebarWidth
        rightSidebarWidth = try container.decodeIfPresent(CGFloat.self, forKey: .rightSidebarWidth) ?? VGTheme.sidebarWidth
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

    var dirty: Bool { content != originalContent }
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
