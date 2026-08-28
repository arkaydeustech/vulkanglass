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

    static func `default`() -> AppSettings {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("VulkanGlass", isDirectory: true).path
        return AppSettings(recentVaults: [], vaultsRoot: root, autoSync: true, darkMode: true)
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
