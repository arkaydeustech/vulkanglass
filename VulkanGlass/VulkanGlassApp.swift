import AppKit
import SwiftUI

@MainActor
final class VulkanGlassAppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

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
    @NSApplicationDelegateAdaptor(VulkanGlassAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Vulkan Glass", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1320, height: 860)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New note") { Task { await model.newNote() } }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open Markdown file…") { model.openStandaloneFile() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Open GitHub vault…") { Task { await model.openLocalVault() } }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Clone GitHub vault…") { model.cloneOpen = true }
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
