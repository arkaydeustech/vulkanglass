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
enum MarkdownFileAssociation {
    /// The content type Finder assigns to `.md` files; the one whose handler is reported.
    static var markdownType: UTType {
        UTType(filenameExtension: "md") ?? UTType(importedAs: "net.daringfireball.markdown")
    }

    /// Every Markdown content type to claim: `.md` and `.markdown` normally share one.
    static var markdownTypes: [UTType] {
        var types: [UTType] = []
        let candidates = [
            markdownType,
            UTType("net.daringfireball.markdown"),
            UTType(filenameExtension: "markdown")
        ]
        for case let type? in candidates where !types.contains(type) {
            types.append(type)
        }
        return types
    }

    static func status(
        workspace: NSWorkspace = .shared,
        bundle: Bundle = .main
    ) -> MarkdownEditorStatus {
        guard let handler = workspace.urlForApplication(toOpen: markdownType) else {
            return MarkdownEditorStatus(isVulkanGlass: false, currentAppName: nil)
        }
        return MarkdownEditorStatus(
            isVulkanGlass: isSameApp(handler, as: bundle),
            currentAppName: FileManager.default.displayName(atPath: handler.path)
                .replacingOccurrences(of: ".app", with: "", options: [.anchored, .backwards])
        )
    }

    static func makeDefault(workspace: NSWorkspace = .shared, bundle: Bundle = .main) async throws {
        for type in markdownTypes {
            try await workspace.setDefaultApplication(at: bundle.bundleURL, toOpen: type)
        }
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
