import AppKit
import SwiftUI

struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""

    private var commands: [(id: String, label: String, hint: String, run: () -> Void)] {
        [
            ("new", "Create new note", "⌘T", { Task { await model.newNote() } }),
            ("window", "Open new window", "⌘N", { openWindow(id: AppWindow.sceneID) }),
            ("daily", "Open today's daily note", "⌘D", { Task { await model.dailyNote() } }),
            ("graph", "Open graph view", "⌘G", { model.centerView = .graph }),
            ("preview", "Toggle reading view", "⌘E", {
                model.editorMode = model.editorMode.togglingReadingView
            }),
            ("raw", "Toggle raw Markdown", "⇧⌘E", {
                model.editorMode = model.editorMode.togglingRawMarkdown
            }),
            ("split-right", "Split right", "⌘\\", { model.splitActiveTab(.trailing) }),
            ("split-down", "Split down", "⇧⌘\\", { model.splitActiveTab(.bottom) }),
            (
                "sync",
                model.activeTab?.savesAutomatically == false ? "Save file" : "Sync vault to GitHub",
                "⌘S",
                { Task { await model.saveActive(sync: true) } }
            ),
            ("file", "Open Markdown file (not in a vault)", "", { model.openStandaloneFile() }),
            ("clone", "Clone GitHub vault", "", { model.cloneOpen = true }),
            ("create", "Create GitHub vault", "", { model.createOpen = true }),
            ("settings", "Open settings", "⌘,", { model.settingsOpen = true }),
            ("close", "Close vault", "", { Task { await model.closeVault() } })
        ]
    }

    var filtered: [(id: String, label: String, hint: String, run: () -> Void)] {
        let q = query.lowercased()
        return q.isEmpty ? commands : commands.filter { $0.label.lowercased().contains(q) }
    }

    var body: some View {
        paletteBackdrop(onDismiss: close) {
            VStack(spacing: 0) {
                PaletteSearchField(
                    text: $query,
                    placeholder: "Type a command…",
                    onSubmit: { filtered.first?.run(); close() },
                    onCancel: close
                )
                .padding(14)
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filtered, id: \.id) { command in
                            Button {
                                command.run()
                                close()
                            } label: {
                                HStack {
                                    Text(command.label)
                                    Spacer()
                                    Text(command.hint).foregroundStyle(.secondary).font(.caption)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            .frame(width: 560)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(VGTheme.divider(dark: model.dark)))
            .onExitCommand { close() }
        }
    }

    private func close() {
        model.commandOpen = false
        query = ""
    }
}

struct QuickSwitcherView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var filtered: [NoteMeta] {
        let q = query.lowercased()
        return q.isEmpty ? model.notes : model.notes.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        paletteBackdrop(onDismiss: close) {
            VStack(spacing: 0) {
                PaletteSearchField(
                    text: $query,
                    placeholder: "Jump to note…",
                    onSubmit: {
                        if let first = filtered.first {
                            Task { await model.openTab(path: first.path) }
                            close()
                        }
                    },
                    onCancel: close
                )
                .padding(14)
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filtered) { note in
                            Button {
                                Task { await model.openTab(path: note.path) }
                                close()
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(note.title)
                                    Text(note.relativePath).font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            .frame(width: 560)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onExitCommand { close() }
        }
    }

    private func close() {
        model.switcherOpen = false
        query = ""
    }
}

private func paletteBackdrop<Content: View>(
    onDismiss: @escaping () -> Void,
    @ViewBuilder content: () -> Content
) -> some View {
    ZStack {
        Color.black.opacity(0.4).ignoresSafeArea().onTapGesture(perform: onDismiss)
        content().offset(y: -80)
    }
}

/// Search field for the command palette and quick switcher. SwiftUI's @FocusState cannot take
/// first responder away from the note's NSTextView, so typing kept editing the document behind
/// the palette. This AppKit field claims first responder when it appears and, if nothing else has
/// taken focus by the time it is dismissed, hands focus back to whatever held it before.
struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        context.coordinator.attach(field)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        nsView.placeholderString = placeholder
        // A SwiftUI update can arrive while AppKit's field editor holds a newer draft.
        // Replacing stringValue then would discard the user's in-progress query and caret.
        if nsView.currentEditor() == nil, nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.prepareForDismantle()
        nsView.delegate = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField
        weak var textField: NSTextField?
        /// The responder that had focus before the palette opened, restored on dismissal.
        private(set) weak var previousResponder: NSResponder?
        private weak var window: NSWindow?
        private let focus: (NSTextField) -> Bool
        private var focused = false
        private var focusRequestPending = false
        private var dismantling = false

        init(
            parent: PaletteSearchField,
            focus: @escaping (NSTextField) -> Bool = {
                guard let window = $0.window else { return false }
                return window.makeFirstResponder($0)
            }
        ) {
            self.parent = parent
            self.focus = focus
        }

        func attach(_ textField: NSTextField) {
            self.textField = textField
            requestFocus()
        }

        /// The field is not in a window until SwiftUI mounts it, so focus asynchronously and retry
        /// a few times rather than relying on the first run-loop pass.
        func requestFocus(remainingAttempts: Int = 8) {
            guard !focused, !focusRequestPending, !dismantling else { return }
            focusRequestPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusRequestPending = false
                guard let textField = self.textField, !self.dismantling else { return }
                if let window = textField.window {
                    self.window = window
                    if self.previousResponder == nil {
                        self.previousResponder = Self.restorableResponder(
                            window.firstResponder,
                            excluding: textField
                        )
                    }
                }
                if self.focus(textField) {
                    self.focused = true
                } else if remainingAttempts > 1 {
                    self.requestFocus(remainingAttempts: remainingAttempts - 1)
                }
            }
        }

        func prepareForDismantle() {
            dismantling = true
            guard focused, let window, let previousResponder else { return }
            let textField = textField
            // Let SwiftUI remove the field and run the chosen command first. Only restore focus
            // if the palette still owns it; a command that moved focus elsewhere keeps its choice.
            DispatchQueue.main.async {
                guard Self.paletteOwnsFocus(in: window, field: textField),
                      Self.canRestore(previousResponder, in: window)
                else { return }
                window.makeFirstResponder(previousResponder)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }

        /// A field editor stands in for its text field; restoring the shared editor itself would
        /// not reattach it, so remember the owning control instead.
        static func restorableResponder(
            _ responder: NSResponder?,
            excluding textField: NSTextField
        ) -> NSResponder? {
            guard let responder, !(responder is NSWindow) else { return nil }
            if let editor = responder as? NSTextView, editor.isFieldEditor {
                guard let owner = editor.delegate as? NSTextField, owner !== textField else {
                    return nil
                }
                return owner
            }
            return responder === textField ? nil : responder
        }

        static func paletteOwnsFocus(in window: NSWindow, field: NSTextField?) -> Bool {
            guard let responder = window.firstResponder else { return true }
            if responder === window { return true }
            if let field, responder === field { return true }
            if let editor = responder as? NSTextView, editor.isFieldEditor {
                // A detached field editor has no delegate once the palette field is torn down.
                return editor.delegate == nil || editor.delegate === field
            }
            return false
        }

        static func canRestore(_ responder: NSResponder, in window: NSWindow) -> Bool {
            guard let view = responder as? NSView else { return false }
            return view.window === window && view.acceptsFirstResponder
        }
    }
}

struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @ObservedObject var updater: AppUpdater
    @State private var token = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.title2.weight(.semibold))
            Group {
                Text("GITHUB").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(githubHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use GitHub CLI when installed", isOn: Bindable(model).settings.useGitHubCLI)
                    .onChange(of: model.settings.useGitHubCLI) { _, _ in
                        SettingsStore.save(model.settings)
                        Task { await model.connectGitHub() }
                    }
                Text(connectionStatus)
                    .foregroundStyle(VGTheme.textAccent)
                Text("A personal access token with repo scope is stored in the macOS Keychain and used if GitHub CLI is unavailable or turned off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    SecureField("ghp_…", text: $token)
                        .disabled(model.authenticationDisabled)
                    Button("Save") {
                        Task {
                            await model.saveToken(token)
                            token = ""
                            message = saveMessage
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(VGTheme.accent)
                    .disabled(
                        model.authenticationDisabled
                            || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
                if let message { Text(message).font(.caption) }
            }
            Toggle("Automatically commit and push when a note is saved", isOn: Bindable(model).settings.autoSync)
                .onChange(of: model.settings.autoSync) { _, _ in
                    SettingsStore.save(model.settings)
                }
            Toggle("Load remote images in notes", isOn: Bindable(model).settings.loadRemoteImages)
                .onChange(of: model.settings.loadRemoteImages) { _, _ in
                    SettingsStore.save(model.settings)
                }
            Text("Off by default. Enabling this can reveal your IP address to image hosts referenced by a note.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("Appearance")
                Spacer()
                Picker("", selection: Bindable(model).settings.appearanceMode) {
                    Text("Inherit").tag(AppearanceMode.inherit)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .onChange(of: model.settings.appearanceMode) { _, _ in
                    SettingsStore.save(model.settings)
                }
            }
            DefaultMarkdownEditorSettingsView()
            Spacer()
            Divider()
            UpdateSettingsView(updater: updater)
            Button("Done") { model.settingsOpen = false }
        }
        .padding(24)
        .frame(width: 520, height: 720)
        .task { await model.connectGitHub() }
    }

    private var githubHelpText: String {
        if model.authenticationDisabled {
            return "This is a local-only development launch, so GitHub CLI and Keychain access are turned off. Relaunch with python3 scripts/build.py --with-auth to test signing in."
        }
        if model.githubCLIStatus.isInstalled {
            return "GitHub CLI detected. Vulkan Glass signs in with it automatically when you are logged in (gh auth login)."
        }
        return "GitHub CLI was not found. Install gh (https://cli.github.com), or paste a personal access token with repo scope."
    }

    private var connectionStatus: String {
        if model.authenticationDisabled {
            return "GitHub authentication is disabled for this development launch"
        }
        if let user = model.githubUser {
            switch model.githubAuthSource {
            case .gitHubCLI:
                return "Signed in as \(user.login) via GitHub CLI"
            case .personalAccessToken:
                return "Signed in as \(user.login) with a personal access token"
            case nil:
                return "Signed in as \(user.login)"
            }
        }
        if model.settings.useGitHubCLI, model.githubCLIStatus.isInstalled, !model.githubCLIStatus.isAuthenticated {
            return "GitHub CLI is not logged in. Run gh auth login, or paste a token."
        }
        return "Not connected"
    }

    private var saveMessage: String {
        if let error = model.errorMessage { return error }
        if model.githubAuthSource == .gitHubCLI {
            return "Token saved as a fallback. Using GitHub CLI."
        }
        return "GitHub connected."
    }
}

/// Shows whether Vulkan Glass opens Markdown files and offers to make it the default app.
struct DefaultMarkdownEditorSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Default Markdown app")
                Text(Self.statusText(for: model.markdownEditorStatus))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Set Default") { Task { await model.makeDefaultMarkdownEditor() } }
                .disabled(Self.setDefaultDisabled(
                    status: model.markdownEditorStatus,
                    inProgress: model.settingDefaultMarkdownEditor
                ))
        }
        .onAppear { model.refreshMarkdownEditorStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The default can change in Finder's Get Info while the sheet is open.
            model.refreshMarkdownEditorStatus()
        }
    }

    static func statusText(for status: MarkdownEditorStatus?) -> String {
        guard let status else { return "Checking…" }
        if status.isVulkanGlass { return "Vulkan Glass opens Markdown files." }
        if let name = status.currentAppName { return "Markdown files open in \(name)." }
        return "No app is set to open Markdown files."
    }

    static func setDefaultDisabled(status: MarkdownEditorStatus?, inProgress: Bool) -> Bool {
        inProgress || status?.isVulkanGlass == true
    }
}

struct CloneVaultSheet: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone GitHub vault").font(.headline)
            TextField("owner/repo or https://github.com/owner/repo", text: $input)
                .onSubmit { Task { await model.cloneVault(input: input) } }
            Button("Clone") { Task { await model.cloneVault(input: input) } }
                .buttonStyle(.borderedProminent)
                .tint(VGTheme.accent)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.githubRepos.filter { input.isEmpty || $0.fullName.lowercased().contains(input.lowercased()) }) { repo in
                        Button {
                            Task { await model.cloneVault(input: repo.fullName) }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(repo.fullName)
                                Text(repo.isPrivate ? "Private" : "Public")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .task { await model.loadRepos() }
    }
}

struct CreateVaultSheet: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var isPrivate = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create GitHub vault").font(.headline)
            TextField("Repository name", text: $name)
            Toggle("Private repository", isOn: $isPrivate)
            Button("Create and open") {
                Task { await model.createGithubVault(name: name, isPrivate: isPrivate) }
            }
            .buttonStyle(.borderedProminent)
            .tint(VGTheme.accent)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
        }
        .padding(20)
        .frame(width: 420, height: 220)
    }
}
