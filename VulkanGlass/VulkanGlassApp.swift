import AppKit
import SwiftUI

@MainActor
final class VulkanGlassAppDelegate: NSObject, NSApplicationDelegate {
    /// The windows open in this app. Finder opens go to the window the user worked in last.
    var session: AppSession = .shared {
        didSet { openPendingFiles() }
    }
    /// Opens a window when Finder hands over a file and none is open to receive it.
    var openMainWindow: (() -> Void)?
    /// The most recent external open; each one waits for the previous so files open in order.
    private(set) var externalOpenTask: Task<Void, Never>?
    private var pendingFileURLs: [URL] = []
    var replyToTermination: (NSApplication, Bool) -> Void = { application, ready in
        application.reply(toApplicationShouldTerminate: ready)
    }

    /// The model that receives Finder opens.
    var model: AppModel? { session.activeModel }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Notes already open as tabs inside a window; macOS window tabs would nest a second,
        // unrelated tab bar above them, and ⌘T belongs to New note.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingFileURLs.append(contentsOf: urls)
        if let model { session.focus(model) } else { openMainWindow?() }
        openPendingFiles()
    }

    /// Called when a window's model is ready, so files that arrived before any window opened
    /// (a cold launch from Finder) land in it.
    func windowDidRegister(_ model: AppModel) {
        session.register(model)
        openPendingFiles()
    }

    private func openPendingFiles() {
        guard let model, !pendingFileURLs.isEmpty else { return }
        let urls = pendingFileURLs
        pendingFileURLs = []
        let previous = externalOpenTask
        externalOpenTask = Task { @MainActor in
            await previous?.value
            session.focus(model)
            await model.openExternalFiles(urls)
        }
    }

    /// Settles every window's unsaved work one window at a time; any cancellation stops the quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let pending = session.models.filter(\.needsPreparationBeforeClosing)
        guard !pending.isEmpty else { return .terminateNow }
        Task { @MainActor in
            var ready = true
            for model in pending {
                session.focus(model)
                guard await model.prepareToCloseWindow() else {
                    ready = false
                    break
                }
            }
            replyToTermination(sender, ready)
        }
        return .terminateLater
    }
}

@main
struct VulkanGlassApp: App {
    @StateObject private var updater = AppUpdater()
    @NSApplicationDelegateAdaptor(VulkanGlassAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Vulkan Glass", id: AppWindow.sceneID) {
            AppWindow(session: appDelegate.session, updater: updater, appDelegate: appDelegate)
        }
        .defaultSize(width: 1320, height: 860)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            VulkanGlassCommands(session: appDelegate.session, updater: updater)
        }
    }
}

/// One window: its own model (vault, tabs, panels) over the shared session.
struct AppWindow: View {
    static let sceneID = "main"

    let session: AppSession
    @ObservedObject var updater: AppUpdater
    let appDelegate: VulkanGlassAppDelegate
    /// Created once the window appears: a model's init starts its bootstrap, so it must not run
    /// for view values SwiftUI builds and throws away.
    @State private var model: AppModel?

    var body: some View {
        Group {
            if let model {
                RootView(updater: updater)
                    .environment(model)
                    .focusedSceneValue(\.appModel, model)
                    .background(WindowSessionBridge(session: session, model: model))
                    .modifier(AppDelegateBridge(appDelegate: appDelegate, model: model))
                    .onDisappear { session.unregister(model) }
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear {
            if model == nil { model = AppModel(session: session) }
            updater.start()
        }
    }
}

struct VulkanGlassCommands: Commands {
    let session: AppSession
    @ObservedObject var updater: AppUpdater
    @FocusedValue(\.appModel) private var model: AppModel?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: AppWindow.sceneID) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New note") { Task { await model?.newNote() } }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(model == nil)
            Divider()
            Button("Open Markdown file…") { model?.openStandaloneFile() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Open GitHub vault…") { Task { await model?.openLocalVault() } }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Clone GitHub vault…") { model?.cloneOpen = true }
                .disabled(model == nil)
            Menu("Open Recent") {
                ForEach(session.settings.recentItems) { item in
                    Button(item.name) { Task { await model?.openRecent(item) } }
                        .disabled(model == nil)
                }
                Divider()
                Button("Clear Menu") { model?.clearRecents() }
                    .disabled(model == nil || session.settings.recentItems.isEmpty)
            }
            Divider()
            Button(model?.saveCommandTitle ?? "Save") { Task { await model?.saveActive(sync: true) } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model?.activeTab == nil)
        }
        CommandMenu("View") {
            Button("Command palette") { model?.commandOpen = true }
                .keyboardShortcut("p", modifiers: .command)
            Button("Quick switcher") { model?.switcherOpen = true }
                .keyboardShortcut("o", modifiers: .command)
            Button("Search in vault") {
                model?.leftPanel = .search
                model?.leftOpen = true
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Toggle left sidebar") { model?.leftOpen.toggle() }
            Button("Toggle right sidebar") { model?.rightOpen.toggle() }
            Button("Toggle reading view") {
                guard let model else { return }
                model.editorMode = model.editorMode.togglingReadingView
            }
            .keyboardShortcut("e", modifiers: .command)
            Button("Toggle raw Markdown") {
                guard let model else { return }
                model.editorMode = model.editorMode.togglingRawMarkdown
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Open graph view") { model?.centerView = .graph }
                .keyboardShortcut("g", modifiers: .command)
            Divider()
            Button("Split right") { model?.splitActiveTab(.trailing) }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(model?.canSplitActiveTab != true)
            Button("Split down") { model?.splitActiveTab(.bottom) }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                .disabled(model?.canSplitActiveTab != true)
        }
        CommandMenu("Go") {
            Button("Open today's daily note") { Task { await model?.dailyNote() } }
                .keyboardShortcut("d", modifiers: .command)
            Button("Close vault") { Task { await model?.closeVault() } }
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
            Button("Settings…") { model?.settingsOpen = true }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(model == nil)
        }
    }
}

/// Connects the app delegate, which receives Finder's open-document events, to a window's model
/// and to the scene's window opener.
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
                    openWindow(id: AppWindow.sceneID)
                }
            }
            appDelegate.windowDidRegister(model)
        }
    }
}
