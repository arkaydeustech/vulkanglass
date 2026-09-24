import Observation
import SwiftUI

@MainActor
@Observable
final class FolderCreationDraft {
    var name = ""

    func begin() {
        name = ""
    }

    func cancel() {
        name = ""
    }

    @discardableResult
    func submit(into model: AppModel) -> Task<Void, Never> {
        let submittedName = name
        name = ""
        return Task { await model.createFolder(name: submittedName) }
    }
}

struct FileExplorerView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var folderDraft = FolderCreationDraft()
    @State private var askingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("FILES")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(VGTheme.textMuted(dark: model.dark))
                Spacer()
                Button {
                    Task { await model.newNote() }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("New note")
                Button {
                    folderDraft.begin()
                    askingFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("New folder")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if model.vault == nil {
                Text("This window is editing a standalone Markdown file. Open a GitHub vault to see a file tree.")
                    .font(.caption)
                    .foregroundStyle(VGTheme.textMuted(dark: model.dark))
                    .padding(12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered(model.fileTree)) { node in
                            TreeRow(node: node, depth: 0)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .alert("New folder", isPresented: $askingFolder) {
            TextField("Name", text: $folderDraft.name)
            Button("Create") {
                folderDraft.submit(into: model)
            }
            Button("Cancel", role: .cancel) {
                folderDraft.cancel()
            }
        }
    }

    private func filtered(_ nodes: [FileNode]) -> [FileNode] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nodes }
        func match(_ node: FileNode) -> FileNode? {
            if node.isDirectory {
                let kids = (node.children ?? []).compactMap(match)
                if !kids.isEmpty || node.name.lowercased().contains(q) {
                    var copy = node
                    copy.children = kids
                    return copy
                }
                return nil
            }
            return node.name.lowercased().contains(q) ? node : nil
        }
        return nodes.compactMap(match)
    }
}

private struct TreeRow: View {
    @Environment(AppModel.self) private var model
    let node: FileNode
    let depth: Int
    @State private var open = true
    @State private var confirmingDelete = false
    @State private var renaming = false

    var body: some View {
        if node.isDirectory {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                    Image(systemName: "folder")
                    Text(node.name)
                    Spacer()
                }
                .foregroundStyle(VGTheme.textNormal(dark: model.dark))
                .padding(.leading, 8 + CGFloat(depth) * 12)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                FolderContextMenu(path: node.path, open: $open)
            }
            if open {
                ForEach(node.children ?? []) { child in
                    TreeRow(node: child, depth: depth + 1)
                }
            }
        } else {
            let active = model.activeTabID == node.path
            let displayName = node.name.replacingOccurrences(of: ".md", with: "", options: .caseInsensitive)
            Group {
                if renaming {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                        InlineRenameField(text: displayName) { name in
                            renaming = false
                            Task { await model.renameNote(path: node.path, newName: name) }
                        } onCancel: {
                            renaming = false
                        }
                    }
                    .foregroundStyle(VGTheme.textNormal(dark: model.dark))
                    .padding(.leading, 20 + CGFloat(depth) * 14)
                    .padding(.vertical, 3)
                } else {
                    Button {
                        Task { await model.openTab(path: node.path) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                            Text(displayName)
                            Spacer()
                        }
                        .foregroundStyle(VGTheme.textNormal(dark: model.dark))
                        .padding(.leading, 20 + CGFloat(depth) * 14)
                        .padding(.vertical, 3)
                        .background(active ? VGTheme.hover(dark: model.dark) : Color.clear)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(active ? VGTheme.accent : Color.clear)
                                .frame(width: 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename") { renaming = true }
                        Button("Move to Trash…", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .confirmationDialog(
                "Move \(node.name) to Trash?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) {
                    Task { await model.deletePath(node.path) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can recover it from the macOS Trash.")
            }
        }
    }
}

struct FolderContextMenu: View {
    @Environment(AppModel.self) private var model
    let path: String
    @Binding var open: Bool

    var body: some View {
        Button("New File") {
            open = true
            Task { await model.newNote(inFolder: path) }
        }
    }
}

struct SearchPanelView: View {
    @Environment(AppModel.self) private var model

    var hits: [NoteMeta] {
        let q = model.searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return model.notes.filter {
            $0.title.lowercased().contains(q) || $0.content.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SEARCH")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(VGTheme.textMuted(dark: model.dark))
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
            TextField("Search vault…", text: Bindable(model).searchQuery)
                .textFieldStyle(.plain)
                .padding(6)
                .background(VGTheme.backgroundPrimary(dark: model.dark))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(VGTheme.divider(dark: model.dark)))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(hits) { note in
                        Button {
                            Task { await model.openTab(path: note.path) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title)
                                Text(note.relativePath)
                                    .font(.caption2)
                                    .foregroundStyle(VGTheme.textFaint(dark: model.dark))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
