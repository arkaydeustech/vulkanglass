import SwiftUI

struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @FocusState private var focused: Bool

    private var commands: [(id: String, label: String, hint: String, run: () -> Void)] {
        [
            ("new", "Create new note", "⌘N", { Task { await model.newNote() } }),
            ("daily", "Open today's daily note", "⌘D", { Task { await model.dailyNote() } }),
            ("graph", "Open graph view", "⌘G", { model.centerView = .graph }),
            ("preview", "Toggle reading view", "⌘E", {
                model.editorMode = model.editorMode == .source ? .preview : .source
            }),
            ("sync", "Sync vault to GitHub", "⌘S", { Task { await model.saveActive(sync: true) } }),
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
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .focused($focused)
                    .onSubmit { filtered.first?.run(); close() }
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
            .onAppear { focused = true }
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
    @FocusState private var focused: Bool

    var filtered: [NoteMeta] {
        let q = query.lowercased()
        return q.isEmpty ? model.notes : model.notes.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        paletteBackdrop(onDismiss: close) {
            VStack(spacing: 0) {
                TextField("Jump to note…", text: $query)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .focused($focused)
                    .onSubmit {
                        if let first = filtered.first {
                            Task { await model.openTab(path: first.path) }
                            close()
                        }
                    }
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
            .onAppear { focused = true }
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

struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.title2.weight(.semibold))
            Group {
                Text("GITHUB").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text("Vaults are GitHub repositories. Create a personal access token with repo scope. It is stored in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.githubUser.map { "Signed in as \($0.login)" } ?? "Not connected")
                    .foregroundStyle(VGTheme.textAccent)
                HStack {
                    SecureField("ghp_…", text: $token)
                    Button("Save") {
                        Task {
                            await model.saveToken(token)
                            token = ""
                            message = model.errorMessage ?? "GitHub connected."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(VGTheme.accent)
                }
                if let message { Text(message).font(.caption) }
            }
            Toggle("Automatically commit and push when a note is saved", isOn: Bindable(model).settings.autoSync)
                .onChange(of: model.settings.autoSync) { _, _ in
                    SettingsStore.save(model.settings)
                }
            HStack {
                Text("Appearance")
                Spacer()
                Picker("", selection: Bindable(model).settings.darkMode) {
                    Text("Dark").tag(true)
                    Text("Light").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: model.settings.darkMode) { _, _ in
                    SettingsStore.save(model.settings)
                }
            }
            Spacer()
            Button("Done") { model.settingsOpen = false }
        }
        .padding(24)
        .frame(width: 520, height: 420)
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
