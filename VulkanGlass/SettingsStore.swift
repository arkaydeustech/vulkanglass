import Foundation

enum SettingsStore {
    private static var url: URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("settings.json")
    }

    /// Application Support normally. The unit tests run inside the real app and open vaults and
    /// files that are recorded as recents, so an XCTest host keeps its settings in a scratch
    /// folder rather than rewriting the user's recents with temporary paths.
    static let directory: URL = {
        if DevelopmentAuthentication.isRunningTests() {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("VulkanGlassTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VulkanGlass", isDirectory: true)
    }()

    /// Loads settings from Application Support.
    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .default()
        }
        return settings
    }

    /// Writes settings to Application Support.
    static func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
