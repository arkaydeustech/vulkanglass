import AppKit
import SwiftUI

@MainActor
final class VulkanGlassAppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the main window appears. Files opened before then (a cold launch from Finder)
    /// are queued and opened as soon as the model arrives.
    var model: AppModel? {
        didSet { openPendingFiles() }
    }
    /// Reopens the main window when Finder hands over a file after the user closed it.
    var openMainWindow: (() -> Void)?
    /// The most recent external open; each one waits for the previous so files open in order.
    private(set) var externalOpenTask: Task<Void, Never>?
    private var pendingFileURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingFileURLs.append(contentsOf: urls)
        openMainWindow?()
        openPendingFiles()
    }

    private func openPendingFiles() {
        guard let model, !pendingFileURLs.isEmpty else { return }
        let urls = pendingFileURLs
        pendingFileURLs = []
        let previous = externalOpenTask
        externalOpenTask = Task { @MainActor in
            await previous?.value
            await model.openExternalFiles(urls)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.tabs.contains(where: { $0.dirty }) else { return .terminateNow }
        Task { @MainActor in
            let saved = await model.flushDirtyTabs()
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}

@main
struct VulkanGlassApp: App {
    @State private var model = AppModel()
    @StateObject private var updater = AppUpdater()
    @NSApplicationDelegateAdaptor(VulkanGlassAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Vulkan Glass", id: "main") {
            RootView(updater: updater)
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
                .modifier(AppDelegateBridge(appDelegate: appDelegate, model: model))
                .onAppear { updater.start() }
        }
        .defaultSize(width: 1320, height: 860)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("New note") { Task { await model.newNote() } }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open Markdown file…") { model.openStandaloneFile() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Open GitHub vault…") { Task { await model.openLocalVault() } }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Clone GitHub vault…") { model.cloneOpen = true }
                Menu("Open Recent") {
                    ForEach(model.settings.recentItems) { item in
                        Button(item.name) { Task { await model.openRecent(item) } }
                    }
                    Divider()
                    Button("Clear Menu") { model.clearRecents() }
                        .disabled(model.settings.recentItems.isEmpty)
                }
                Divider()
                Button("Save and sync") { Task { await model.saveActive(sync: true) } }
                    .keyboardShortcut("s", modifiers: .command)
            }
            CommandMenu("View") {
                Button("Command palette") { model.commandOpen = true }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Quick switcher") { model.switcherOpen = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Search in vault") {
                    model.leftPanel = .search
                    model.leftOpen = true
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Toggle left sidebar") { model.leftOpen.toggle() }
                Button("Toggle right sidebar") { model.rightOpen.toggle() }
                Button("Toggle reading view") {
                    model.editorMode = model.editorMode == .source ? .preview : .source
                }
                .keyboardShortcut("e", modifiers: .command)
                Button("Open graph view") { model.centerView = .graph }
                    .keyboardShortcut("g", modifiers: .command)
            }
            CommandMenu("Go") {
                Button("Open today's daily note") { Task { await model.dailyNote() } }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Close vault") { Task { await model.closeVault() } }
            }
            CommandMenu("Format") {
                Button("Bold") {
                    NSApp.sendAction(#selector(SourceTextView.toggleBold(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("Italic") {
                    NSApp.sendAction(#selector(SourceTextView.toggleItalic(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("i", modifiers: .command)
                Button("Underline") {
                    NSApp.sendAction(#selector(SourceTextView.toggleUnderline(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("u", modifiers: .command)
                Button("Link…") {
                    NSApp.sendAction(#selector(SourceTextView.editLink(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Heading 1") {
                    NSApp.sendAction(#selector(SourceTextView.applyHeading1(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Heading 2") {
                    NSApp.sendAction(#selector(SourceTextView.applyHeading2(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Heading 3") {
                    NSApp.sendAction(#selector(SourceTextView.applyHeading3(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("3", modifiers: [.command, .option])
            }
            CommandMenu("Table") {
                Button("Add Table Column") {
                    NSApp.sendAction(#selector(SourceTextView.addTableColumn(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Add Table Row") {
                    NSApp.sendAction(#selector(SourceTextView.addTableRow(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.settingsOpen = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// Connects the app delegate, which receives Finder's open-document events, to the model and to
/// the scene's window opener.
struct AppDelegateBridge: ViewModifier {
    let appDelegate: VulkanGlassAppDelegate
    let model: AppModel
    var openWindowOverride: (() -> Void)? = nil
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            appDelegate.openMainWindow = {
                if let openWindowOverride {
                    openWindowOverride()
                } else {
                    openWindow(id: "main")
                }
            }
            appDelegate.model = model
        }
    }
}
