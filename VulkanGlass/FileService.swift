import Darwin
import Foundation

enum FileServiceError: LocalizedError, Equatable {
    case invalidRelativePath(String)
    case outsideRoot(String)
    case missingVault(String)
    case nameTaken(String)
    case symbolicLinkRenameUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let value):
            return "Invalid file or folder name: \(value)"
        case .outsideRoot(let path):
            return "The requested path is outside the vault: \(path)"
        case .missingVault(let name):
            return "The vault “\(name)” doesn’t exist."
        case .nameTaken(let name):
            return "A file named \(name) already exists."
        case .symbolicLinkRenameUnsupported(let path):
            return "Symbolic-link notes cannot be renamed in Vulkan Glass: \(path)"
        }
    }
}

enum FileService {
    private static let skipped = Set([".git", "node_modules", ".obsidian", ".vulkan-glass", "dist", "out"])

    /// Returns whether `path` exists on disk and is a directory.
    static func directoryExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func tree(at root: URL) -> [FileNode] {
        let root = canonicalURL(root)
        return walk(root, root: root)
    }

    static func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    static func write(_ url: URL, content: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    static func createNote(in directory: URL, name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.lowercased().hasSuffix(".md") ? trimmed : "\(trimmed).md"
        var url = try containedURL(root: directory, relativePath: base)
        var i = 1
        while FileManager.default.fileExists(atPath: url.path) {
            let stem = (base as NSString).deletingPathExtension
            url = try containedURL(root: directory, relativePath: "\(stem) \(i).md")
            i += 1
        }
        try write(url, content: "")
        return url
    }

    static func createFolder(in directory: URL, name: String) throws -> URL {
        let url = try containedURL(root: directory, relativePath: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func moveToTrash(_ url: URL, root: URL) throws {
        let canonical = try validateExisting(url, inside: root)
        try FileManager.default.trashItem(at: canonical, resultingItemURL: nil)
    }

    /// Renames a Markdown file in place, keeping it in the same folder.
    static func rename(_ url: URL, to newName: String, root: URL?) throws -> URL {
        let fileName = try markdownFileName(from: newName)
        let original = url.standardizedFileURL
        if try original.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw FileServiceError.symbolicLinkRenameUnsupported(original.path)
        }
        let source: URL
        if let root {
            source = try validateExisting(original, inside: root)
        } else {
            source = canonicalURL(original)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                throw FileServiceError.invalidRelativePath(url.path)
            }
        }

        let destination = original.deletingLastPathComponent().appendingPathComponent(fileName)
        if let root {
            let canonicalRoot = canonicalURL(root)
            let destCanonical = canonicalURL(destination)
            let sourceParent = canonicalURL(source.deletingLastPathComponent())
            let destParent = canonicalURL(destination.deletingLastPathComponent())
            guard destParent.path == sourceParent.path,
                  destCanonical.path.hasPrefix(canonicalRoot.path + "/")
            else {
                throw FileServiceError.outsideRoot(destination.path)
            }
        }

        let sourceCanonical = canonicalURL(source)
        let destCanonical = canonicalURL(destination)
        let sameItem = sourceCanonical.path == destCanonical.path
            || (
                canonicalURL(source.deletingLastPathComponent()).path
                    == canonicalURL(destination.deletingLastPathComponent()).path
                    && source.lastPathComponent.compare(destination.lastPathComponent, options: .caseInsensitive)
                    == .orderedSame
            )
        if sameItem {
            if source.lastPathComponent == destination.lastPathComponent {
                return original
            }
            let temp = original.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).md")
            try FileManager.default.moveItem(at: source, to: temp)
            do {
                try FileManager.default.moveItem(at: temp, to: destination)
            } catch {
                try? FileManager.default.moveItem(at: temp, to: source)
                throw error
            }
            return destination
        }

        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw FileServiceError.nameTaken(fileName)
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    /// Builds a `.md` filename from a user-entered title, rejecting path separators.
    static func markdownFileName(from raw: String) throws -> String {
        var stem = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.lowercased().hasSuffix(".md") {
            stem.removeLast(3)
            stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let components = (stem as NSString).pathComponents
        guard !stem.isEmpty,
              !stem.hasPrefix("."),
              stem.rangeOfCharacter(from: .newlines) == nil,
              !(stem as NSString).isAbsolutePath,
              !stem.contains("/"),
              !stem.contains("\\"),
              !stem.contains(":"),
              !stem.contains("\0"),
              stem != ".",
              stem != "..",
              !components.contains(".."),
              !components.contains(".")
        else {
            throw FileServiceError.invalidRelativePath(raw)
        }
        return "\(stem).md"
    }

    static func index(at root: URL) -> [NoteMeta] {
        let root = canonicalURL(root)
        var notes: [NoteMeta] = []
        visit(root) { url, relative in
            guard url.pathExtension.lowercased() == "md",
                  let content = try? read(url)
            else { return }
            notes.append(metadata(path: url.path, relativePath: relative, content: content))
        }
        return notes.sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
    }

    static func metadata(path: String, relativePath: String, content: String) -> NoteMeta {
        NoteMeta(
            path: path,
            relativePath: relativePath,
            title: Markdown.title(from: path),
            content: content,
            tags: Markdown.tags(in: content),
            wikiLinks: Markdown.wikiLinks(in: content),
            headings: Markdown.headings(in: content)
        )
    }

    static func resolveWiki(root: URL, target: String) -> URL? {
        let notes = index(at: root)
        let key = normalizedWikiTarget(target)
        if let byPath = notes.first(where: {
            normalizedWikiTarget($0.relativePath) == key
        }) {
            return URL(fileURLWithPath: byPath.path)
        }
        return notes.first(where: { $0.title.lowercased() == key })
            .map { URL(fileURLWithPath: $0.path) }
    }

    static func createFromWiki(root: URL, target: String) throws -> URL {
        if let existing = resolveWiki(root: root, target: target) { return existing }
        return try createNote(in: root, name: target)
    }

    /// Produces a candidate beneath root and rejects absolute, parent, and symlink escapes.
    static func containedURL(root: URL, relativePath: String) throws -> URL {
        let value = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = (value as NSString).pathComponents
        guard !value.isEmpty,
              !(value as NSString).isAbsolutePath,
              !components.contains(".."),
              !components.contains("."),
              !components.contains("/")
        else {
            throw FileServiceError.invalidRelativePath(relativePath)
        }

        let canonicalRoot = canonicalURL(root)
        let raw = canonicalRoot.appendingPathComponent(value).standardizedFileURL
        let resolvedParent = canonicalURL(raw.deletingLastPathComponent())
        let candidate = resolvedParent.appendingPathComponent(raw.lastPathComponent).standardizedFileURL
        guard candidate.path.hasPrefix(canonicalRoot.path + "/") else {
            throw FileServiceError.outsideRoot(candidate.path)
        }
        return candidate
    }

    private static func validateExisting(_ url: URL, inside root: URL) throws -> URL {
        let canonicalRoot = canonicalURL(root)
        let canonical = canonicalURL(url)
        guard canonical.path.hasPrefix(canonicalRoot.path + "/") else {
            throw FileServiceError.outsideRoot(canonical.path)
        }
        return canonical
    }

    static func canonicalURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if standardized.path.withCString({ realpath($0, &buffer) }) != nil {
            return URL(fileURLWithPath: String(cString: buffer))
        }
        guard standardized.path != "/" else { return standardized }
        return canonicalURL(standardized.deletingLastPathComponent())
            .appendingPathComponent(standardized.lastPathComponent)
    }

    private static func normalizedWikiTarget(_ value: String) -> String {
        var target = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.lowercased().hasSuffix(".md") { target.removeLast(3) }
        return target.lowercased()
    }

    private static func walk(_ dir: URL, root: URL) -> [FileNode] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var nodes: [FileNode] = []
        for url in entries {
            let name = url.lastPathComponent
            if skipped.contains(name) { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                nodes.append(
                    FileNode(name: name, path: url.path, isDirectory: true, children: walk(url, root: root))
                )
            } else if url.pathExtension.lowercased() == "md" {
                nodes.append(FileNode(name: name, path: url.path, isDirectory: false, children: nil))
            }
        }
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private static func visit(
        _ dir: URL,
        relativePrefix: String = "",
        visitFile: (URL, String) -> Void
    ) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in entries {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if skipped.contains(name) || values?.isSymbolicLink == true { continue }
            let relative = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
            if values?.isDirectory == true {
                visit(url, relativePrefix: relative, visitFile: visitFile)
            } else {
                visitFile(url, relative)
            }
        }
    }
}
