import AppKit
import UniformTypeIdentifiers

/// Which app macOS opens Markdown files with.
struct MarkdownEditorStatus: Equatable, Sendable {
    /// True when Finder opens `.md` files in Vulkan Glass.
    var isVulkanGlass: Bool
    /// The display name of the app that currently opens `.md` files, if any.
    var currentAppName: String?
}

/// Reads and changes the default app for Markdown files through Launch Services.
struct DefaultMarkdownEditor {
    /// Reports the app that currently opens `.md` files.
    var status: @MainActor () -> MarkdownEditorStatus
    /// Makes Vulkan Glass the app that opens Markdown files.
    var makeDefault: @MainActor () async throws -> Void
    /// Asks, on first launch, whether to make Vulkan Glass the default. True means yes.
    var confirmMakeDefault: @MainActor () -> Bool
    /// Whether launch may ask at all. False while hosting unit tests, whose app launch must not
    /// raise a modal alert.
    var offersOnFirstLaunch: Bool

    /// Does nothing and never asks; the default for models built by tests.
    static let inert = DefaultMarkdownEditor(
        status: { MarkdownEditorStatus(isVulkanGlass: false, currentAppName: nil) },
        makeDefault: {},
        confirmMakeDefault: { false },
        offersOnFirstLaunch: false
    )

    static let live = DefaultMarkdownEditor(
        status: { MarkdownFileAssociation.status() },
        makeDefault: { try await MarkdownFileAssociation.makeDefault() },
        confirmMakeDefault: {
            DefaultMarkdownEditorAlert.make().runModal() == .alertFirstButtonReturn
        },
        offersOnFirstLaunch: !DevelopmentAuthentication.isRunningTests()
    )
}

/// The Launch Services calls behind `DefaultMarkdownEditor.live`.
@MainActor
protocol MarkdownAssociationWorkspace {
    func urlForApplication(toOpen contentType: UTType) -> URL?
    func setDefaultApplication(at applicationURL: URL, toOpen contentType: UTType) async throws
}

extension NSWorkspace: MarkdownAssociationWorkspace {}

enum MarkdownAssociationError: LocalizedError {
    case handlerDidNotChange

    var errorDescription: String? {
        "macOS did not change the app that opens .md files."
    }
}

@MainActor
enum MarkdownFileAssociation {
    static let declaredMarkdownType = UTType(importedAs: "net.daringfireball.markdown")

    /// The content type Finder assigns to `.md` files; the one whose handler is reported.
    static var markdownType: UTType {
        UTType(filenameExtension: "md") ?? declaredMarkdownType
    }

    /// Claim the declared type first. Other resolved types may differ on Macs with competing
    /// importers; failure for one must not prevent trying the others.
    static var markdownTypes: [UTType] {
        var types: [UTType] = []
        let candidates = [
            declaredMarkdownType,
            markdownType,
            UTType(filenameExtension: "markdown")
        ]
        for case let type? in candidates where !types.contains(type) {
            types.append(type)
        }
        return types
    }

    static func status(
        workspace: any MarkdownAssociationWorkspace = NSWorkspace.shared,
        bundle: Bundle = .main,
        contentType: UTType? = nil
    ) -> MarkdownEditorStatus {
        guard let handler = workspace.urlForApplication(toOpen: contentType ?? markdownType) else {
            return MarkdownEditorStatus(isVulkanGlass: false, currentAppName: nil)
        }
        return MarkdownEditorStatus(
            isVulkanGlass: isSameApp(handler, as: bundle),
            currentAppName: FileManager.default.displayName(atPath: handler.path)
                .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
        )
    }

    static func makeDefault(
        workspace: any MarkdownAssociationWorkspace = NSWorkspace.shared,
        bundle: Bundle = .main,
        types: [UTType]? = nil,
        statusType: UTType? = nil
    ) async throws {
        var firstError: Error?
        for type in types ?? markdownTypes {
            do {
                try await workspace.setDefaultApplication(at: bundle.bundleURL, toOpen: type)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if status(workspace: workspace, bundle: bundle, contentType: statusType).isVulkanGlass { return }
        throw firstError ?? MarkdownAssociationError.handlerDidNotChange
    }

    /// A handler is this app when it has the same bundle identifier, so an installed copy and a
    /// development build count as one app.
    static func isSameApp(_ handler: URL, as bundle: Bundle) -> Bool {
        if let identifier = bundle.bundleIdentifier,
           let handlerIdentifier = Bundle(url: handler)?.bundleIdentifier {
            return identifier == handlerIdentifier
        }
        return handler.standardizedFileURL == bundle.bundleURL.standardizedFileURL
    }
}

@MainActor
enum DefaultMarkdownEditorAlert {
    static func make() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Make Vulkan Glass the default app for Markdown files?"
        alert.informativeText = "Markdown files you open from Finder will open in Vulkan Glass. "
            + "You can change this later in Settings."
        let accept = alert.addButton(withTitle: "Set Default")
        accept.keyEquivalent = "\r"
        let decline = alert.addButton(withTitle: "Not Now")
        decline.keyEquivalent = "\u{1b}"
        return alert
    }
}
