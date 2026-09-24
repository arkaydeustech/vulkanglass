import Darwin
import Foundation

enum FileServiceError: LocalizedError, Equatable {
    case emptyName
    case invalidRelativePath(String)
    case outsideRoot(String)
    case missingVault(String)
    case missingFile(String)
    case nameTaken(String)
    case symbolicLinkRenameUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a folder name."
        case .invalidRelativePath(let value):
            return "Invalid file or folder name: \(value)"
        case .outsideRoot(let path):
            return "The requested path is outside the vault: \(path)"
        case .missingVault(let name):
            return "The vault “\(name)” doesn’t exist."
        case .missingFile(let name):
            return "The file “\(name)” doesn’t exist."
        case .nameTaken(let name):
            return "A file named \(name) already exists."
        case .symbolicLinkRenameUnsupported(let path):
            return "Symbolic-link notes cannot be renamed in Vulkan Glass: \(path)"
        }
    }
}

enum FileService {
    struct WikiNoteResolution: Sendable {
        let url: URL
        let wasCreated: Bool
    }

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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FileServiceError.emptyName }
        guard !trimmed.contains("/") else { throw FileServiceError.invalidRelativePath(name) }
        let url = try containedURL(root: directory, relativePath: trimmed)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw FileServiceError.nameTaken(trimmed)
        }
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

    /// Renames a folder inside the vault in place, keeping it under the same parent.
    static func renameFolder(_ url: URL, to newName: String, root: URL) throws -> URL {
        let name = try folderName(from: newName)
        let original = url.standardizedFileURL
        if try original.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw FileServiceError.invalidRelativePath(original.path)
        }
        let source = try validateExisting(original, inside: root)
        guard directoryExists(at: source.path) else {
            throw FileServiceError.invalidRelativePath(url.path)
        }

        let parent = source.deletingLastPathComponent()
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        guard canonicalURL(destination).path.hasPrefix(canonicalURL(root).path + "/") else {
            throw FileServiceError.outsideRoot(destination.path)
        }
        if source.lastPathComponent == name { return source }

        // Changing only the case must go through a temporary name on case-insensitive volumes,
        // where the destination otherwise "exists" as the folder itself.
        if source.lastPathComponent.compare(name, options: .caseInsensitive) == .orderedSame {
            let temp = parent.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
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
            throw FileServiceError.nameTaken(name)
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    /// Validates a user-entered folder name, rejecting names the vault cannot show.
    static func folderName(from raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FileServiceError.emptyName }
        guard !name.hasPrefix("."),
              !skipped.contains(name),
              name.rangeOfCharacter(from: .newlines) == nil,
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains(":"),
              !name.contains("\0")
        else {
            throw FileServiceError.invalidRelativePath(raw)
        }
        return name
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

    static func createFromWiki(root: URL, target: String) throws -> WikiNoteResolution {
        if let existing = resolveWiki(root: root, target: target) {
            return WikiNoteResolution(url: existing, wasCreated: false)
        }
        return WikiNoteResolution(
            url: try createNote(in: root, name: target),
            wasCreated: true
        )
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
        // Resolve both existing and not-yet-created candidates the same way. Foundation can
        // re-express an existing /private/var path through /var during standardization, which
        // otherwise makes the second generated "Untitled" filename look outside its vault.
        let candidate = canonicalURL(raw)
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
