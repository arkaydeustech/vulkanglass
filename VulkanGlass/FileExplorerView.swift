import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// In-app drag payload for a note in the file explorer; the data is the note's file path.
    static let vulkanGlassNote = UTType(exportedAs: "app.vulkanglass.note-file")
}

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

/// The name typed into the "Rename folder" alert and the folder it applies to.
@MainActor
@Observable
final class FolderRenameDraft {
    var name = ""
    var isPresented = false
    private(set) var path: String?

    /// Starts renaming `folder`, pre-filling its current name.
    func begin(_ folder: FileNode) {
        path = folder.path
        name = folder.name
        isPresented = true
    }

    func cancel() {
        path = nil
        name = ""
        isPresented = false
    }

    @discardableResult
    func submit(into model: AppModel, onCompletion: ((Bool) -> Void)? = nil) -> Task<Void, Never>? {
        let submittedName = name
        let submittedPath = path
        cancel()
        guard let submittedPath else { return nil }
        return Task {
            let renamed = await model.renameFolder(path: submittedPath, newName: submittedName)
            onCompletion?(renamed)
        }
    }
}

/// Folder expansion and the pointer and keyboard selection for the file explorer's tree.
@MainActor
@Observable
final class FileTreeState {
    /// One row of the tree as drawn: a note or folder and how deeply it is nested.
    struct Row: Identifiable, Equatable {
        let node: FileNode
        let depth: Int
        var id: String { node.path }
    }

    /// Folders the user has collapsed; every other folder shows its children.
    private(set) var collapsedFolders: Set<String> = []
    /// The note row that has keyboard focus, if any.
    private(set) var focusedPath: String?
    /// A note row the arrow keys moved to, which takes keyboard focus once it is on screen.
    private(set) var focusRequestPath: String?
    /// The folder the user clicked or right-clicked, highlighted in place of any note until a
    /// note is selected again.
    private(set) var selectedFolderPath: String?
    private var selectionRevision = 0
    private var folderSelectionRevision = 0
    private var pendingNoteOpens: [UUID: (path: String, revision: Int)] = [:]
    private var pendingFolderRename: (oldPath: String, newPath: String)?

    func isOpen(_ folderPath: String) -> Bool {
        !collapsedFolders.contains(folderPath)
    }

    func setOpen(_ open: Bool, folder folderPath: String) {
        if open {
            collapsedFolders.remove(folderPath)
        } else {
            collapsedFolders.insert(folderPath)
        }
    }

    /// The highlighted row: a folder the user picked, otherwise the note the keyboard is on,
    /// otherwise the active tab's note.
    func selection(activeTabID: String?) -> String? {
        focusRequestPath ?? selectedFolderPath ?? focusedPath ?? activeTabID
    }

    /// Whether `path` is the note with keyboard focus and no folder has been picked since.
    func isFocusedSelection(_ path: String) -> Bool {
        selectedFolderPath == nil && focusedPath == path
    }

    /// Highlights `folderPath`, as when it is clicked or right-clicked, in place of any note.
    func selectFolder(_ folderPath: String) {
        selectionRevision += 1
        folderSelectionRevision = selectionRevision
        selectedFolderPath = folderPath
        focusRequestPath = nil
    }

    func clearFolderSelection() {
        selectedFolderPath = nil
    }

    /// Remaps a selected folder when its rename refresh replaces the old row.
    func beginFolderRename(from oldPath: String, to newPath: String) {
        guard selectedFolderPath == oldPath else { return }
        pendingFolderRename = (oldPath, newPath)
    }

    func finishFolderRename(succeeded: Bool) {
        if succeeded, let rename = pendingFolderRename, selectedFolderPath == rename.oldPath {
            selectFolder(rename.newPath)
        }
        pendingFolderRename = nil
    }

    /// Remembers which interaction began a note open before its title commit can suspend it.
    func beginNoteOpen(_ path: String) -> UUID {
        let token = UUID()
        pendingNoteOpens[token] = (path, selectionRevision)
        return token
    }

    func finishNoteOpen(_ token: UUID, activeTabID: String?, previousActiveTabID: String?) {
        guard let request = pendingNoteOpens[token] else { return }
        if activeTabID != request.path || activeTabID == previousActiveTabID {
            pendingNoteOpens[token] = nil
        }
    }

    func activeTabChanged(to path: String?) {
        let matching = pendingNoteOpens.filter { $0.value.path == path }
        defer { for (token, _) in matching { pendingNoteOpens[token] = nil } }
        if selectedFolderPath != nil {
            if pendingFolderRename != nil { return }
            if let latest = pendingNoteOpens.values.map(\.revision).max(), latest < folderSelectionRevision { return }
        }
        clearFolderSelection()
    }

    /// The rows on screen, in order: collapsed folders hide their descendants.
    static func visibleRows(_ nodes: [FileNode], collapsed: Set<String>) -> [Row] {
        var rows: [Row] = []
        func append(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                rows.append(Row(node: node, depth: depth))
                if node.isDirectory, !collapsed.contains(node.path) {
                    append(node.children ?? [], depth: depth + 1)
                }
            }
        }
        append(nodes, depth: 0)
        return rows
    }

    /// The note `offset` notes above (negative) or below the note or folder at `path` among
    /// `rows`, skipping folders; nil past either end of the list.
    static func note(_ offset: Int, from path: String, in rows: [Row]) -> String? {
        guard let index = rows.firstIndex(where: { $0.node.path == path }) else { return nil }
        if offset == 0 { return rows[index].node.isDirectory ? nil : path }
        let candidates = offset > 0 ? rows[(index + 1)...].map(\.node) : rows[..<index].reversed().map(\.node)
        let notes = candidates.filter { !$0.isDirectory }
        return notes.indices.contains(abs(offset) - 1) ? notes[abs(offset) - 1].path : nil
    }

    /// Moves from the pending selection when focus has not caught up with the arrow keys, or
    /// from a picked folder.
    @discardableResult
    func moveSelection(_ offset: Int, from path: String, in rows: [Row]) -> String? {
        let origin = focusRequestPath ?? selectedFolderPath ?? path
        guard let target = Self.note(offset, from: origin, in: rows) else { return nil }
        selectedFolderPath = nil
        focusRequestPath = target
        return target
    }

    /// Drops paths that have disappeared from the visible tree and restores keyboard focus to
    /// a surviving note when the focused row was removed by a tree change.
    func reconcileVisibleRows(_ rows: [Row], activeTabID: String?) {
        if let selectedFolderPath, !rows.contains(where: { $0.node.isDirectory && $0.node.path == selectedFolderPath }) {
            if let rename = pendingFolderRename, rename.oldPath == selectedFolderPath,
               rows.contains(where: { $0.node.isDirectory && $0.node.path == rename.newPath }) {
                self.selectedFolderPath = rename.newPath
            } else {
                self.selectedFolderPath = nil
            }
        }
        let notes = rows.filter { !$0.node.isDirectory }.map(\.node.path)
        let lostFocusedRow = focusedPath.map { !notes.contains($0) } ?? false
        let lostRequestedRow = focusRequestPath.map { !notes.contains($0) } ?? false
        if lostFocusedRow { focusedPath = nil }
        if lostRequestedRow { focusRequestPath = nil }
        if (lostFocusedRow || lostRequestedRow && focusedPath == nil), focusRequestPath == nil,
           selectedFolderPath == nil {
            focusRequestPath = activeTabID.flatMap { notes.contains($0) ? $0 : nil } ?? notes.first
        }
    }

    /// A press on a note row: drops any pending arrow-key move and picked folder, as the
    /// pressed note becomes the selection.
    func notePressed() {
        focusRequestPath = nil
        selectedFolderPath = nil
    }

    /// Records a note row gaining or losing keyboard focus.
    func focusChanged(_ path: String, focused: Bool) {
        if focused {
            let wasFocused = focusedPath == path
            focusedPath = path
            // Repeated focus notifications from the note that held first responder before a
            // folder click do not undo that newer pointer selection.
            if !wasFocused || focusRequestPath == path {
                selectedFolderPath = nil
            }
            if focusRequestPath == path { focusRequestPath = nil }
        } else if focusedPath == path {
            focusedPath = nil
        }
    }
}

/// The folder awaiting confirmation in the "Move to Trash" prompt.
@MainActor
@Observable
final class FolderTrashRequest {
    var isPresented = false
    private(set) var path: String?
    private(set) var name = ""
    private(set) var contents: FileService.FolderContents?
    private var identity: FileService.FolderIdentity?
    private var countTask: Task<Void, Never>?

    /// Asks to confirm moving `folder` and everything inside it to the Trash.
    func begin(_ folder: FileNode) {
        countTask?.cancel()
        let url = URL(fileURLWithPath: folder.path)
        guard let identity = try? FileService.folderIdentity(at: url) else {
            cancel()
            return
        }
        path = folder.path
        name = folder.name
        self.identity = identity
        contents = nil
        isPresented = true
        countTask = Task { [weak self] in
            let work = Task.detached {
                try? FileService.folderContents(in: url)
            }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, self?.path == folder.path else { return }
            self?.contents = result
        }
    }

    func cancel() {
        countTask?.cancel()
        countTask = nil
        path = nil
        name = ""
        contents = nil
        identity = nil
        isPresented = false
    }

    func awaitCount() async {
        await countTask?.value
    }

    var title: String {
        "Move “\(name)” to Trash?"
    }

    var message: String {
        let description: String
        if let contents {
            description = switch (contents.files, contents.directories) {
            case (0, 0): "This empty folder"
            case (0, _): "This folder and its subfolders"
            case (1, _): "This folder and the 1 file inside it"
            default: "This folder and all \(contents.files) files inside it"
            }
        } else {
            description = "This folder and everything inside it"
        }
        return "\(description) will be moved to the Trash. You can recover it from the macOS Trash."
    }

    @discardableResult
    func confirm(into model: AppModel) -> Task<Void, Never>? {
        let confirmedPath = path
        let confirmedIdentity = identity
        cancel()
        guard let confirmedPath, let confirmedIdentity else { return nil }
        return Task { await model.deletePath(confirmedPath, expectedFolderIdentity: confirmedIdentity) }
    }
}

struct FileExplorerView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var folderDraft = FolderCreationDraft()
    @State private var askingFolder = false
    @State private var rootDropTargeted = false
    @State private var treeRowsHeight: CGFloat = 0
    @State private var tree = FileTreeState()
    @State private var renameDraft: FolderRenameDraft
    @State private var trashRequest: FolderTrashRequest

    init() {
        self.init(renameDraft: FolderRenameDraft())
    }

    init(renameDraft: FolderRenameDraft) {
        self.init(renameDraft: renameDraft, trashRequest: FolderTrashRequest())
    }

    init(renameDraft: FolderRenameDraft, trashRequest: FolderTrashRequest) {
        _renameDraft = State(initialValue: renameDraft)
        _trashRequest = State(initialValue: trashRequest)
    }

    init(tree: FileTreeState) {
        _tree = State(initialValue: tree)
        _renameDraft = State(initialValue: FolderRenameDraft())
        _trashRequest = State(initialValue: FolderTrashRequest())
    }

    init(tree: FileTreeState, renameDraft: FolderRenameDraft) {
        _tree = State(initialValue: tree)
        _renameDraft = State(initialValue: renameDraft)
        _trashRequest = State(initialValue: FolderTrashRequest())
    }

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

            if let vault = model.vault {
                let treeRows = FileTreeState.visibleRows(filtered(model.fileTree), collapsed: tree.collapsedFolders)
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "tray")
                                        Text(vault.name)
                                        Spacer()
                                    }
                                    .font(.caption)
                                    .foregroundStyle(VGTheme.textMuted(dark: model.dark))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(rootDropTargeted ? VGTheme.dropTarget.opacity(0.18) : Color.clear)
                                    .contentShape(Rectangle())
                                    .onDrop(
                                        of: [.vulkanGlassNote],
                                        delegate: FolderDropDelegate(
                                            model: model,
                                            folderPath: vault.path,
                                            targeted: $rootDropTargeted
                                        )
                                    )

                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        ForEach(treeRows) { row in
                                            TreeRow(
                                                node: row.node,
                                                depth: row.depth,
                                                tree: tree,
                                                onRenameFolder: renameDraft.begin,
                                                onTrashFolder: trashRequest.begin,
                                                onMoveSelection: { offset in
                                                    tree.moveSelection(offset, from: row.node.path, in: treeRows)
                                                }
                                            )
                                        }
                                    }
                                }
                                .background {
                                    GeometryReader { rows in
                                        Color.clear.preference(key: FileTreeRowsHeightKey.self, value: rows.size.height)
                                    }
                                }

                                // Only free space below the rows accepts a root drop. The scroll view
                                // proposes no height, so the area is sized to fill the rest of the
                                // viewport explicitly rather than with a `Spacer`.
                                Color.clear
                                    .frame(maxWidth: .infinity)
                                    .frame(height: Self.rootDropAreaHeight(
                                        viewportHeight: geometry.size.height,
                                        rowsHeight: treeRowsHeight
                                    ))
                                    .contentShape(Rectangle())
                                    .onDrop(
                                        of: [.vulkanGlassNote],
                                        delegate: FolderDropDelegate(
                                            model: model,
                                            folderPath: vault.path,
                                            targeted: $rootDropTargeted
                                        )
                                    )
                            }
                        }
                        .onPreferenceChange(FileTreeRowsHeightKey.self) { treeRowsHeight = $0 }
                        // Brings the row the arrow keys moved to on screen, so it can take focus.
                        .onChange(of: tree.focusRequestPath) { _, path in
                            if let path { proxy.scrollTo(path) }
                        }
                        .onChange(of: treeRows.map(\.id)) { _, _ in
                            tree.reconcileVisibleRows(treeRows, activeTabID: model.activeTabID)
                        }
                        // Opening a note moves the highlight from a picked folder to that note.
                        .onChange(of: model.activeTabID) { _, path in
                            tree.activeTabChanged(to: path)
                        }
                    }
                }
            } else {
                Text("This window is editing a standalone Markdown file. Open a GitHub vault to see a file tree.")
                    .font(.caption)
                    .foregroundStyle(VGTheme.textMuted(dark: model.dark))
                    .padding(12)
                Spacer()
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
        .alert("Rename folder", isPresented: $renameDraft.isPresented) {
            TextField("Name", text: $renameDraft.name)
            Button("Rename") {
                if let path = renameDraft.path {
                    let name = renameDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let destination = URL(fileURLWithPath: path).deletingLastPathComponent()
                        .appendingPathComponent(name, isDirectory: true)
                    tree.beginFolderRename(from: path, to: FileService.canonicalURL(destination).path)
                }
                renameDraft.submit(into: model) { succeeded in
                    tree.finishFolderRename(succeeded: succeeded)
                }
            }
            Button("Cancel", role: .cancel) {
                renameDraft.cancel()
            }
        } message: {
            Text("Enter a new name for this folder.")
        }
        .confirmationDialog(
            trashRequest.title,
            isPresented: $trashRequest.isPresented,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                trashRequest.confirm(into: model)
            }
            Button("Cancel", role: .cancel) {
                trashRequest.cancel()
            }
        } message: {
            Text(trashRequest.message)
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

    static func rootDropAreaHeight(viewportHeight: CGFloat, rowsHeight: CGFloat) -> CGFloat {
        max(12, viewportHeight - rowsHeight)
    }
}

/// One row of the file tree: a folder that expands and collapses, or a note that opens.
struct TreeRow: View {
    @Environment(AppModel.self) private var model
    let node: FileNode
    let depth: Int
    var tree: FileTreeState = FileTreeState()
    let onRenameFolder: (FileNode) -> Void
    var onTrashFolder: (FileNode) -> Void = { _ in }
    /// Moves the keyboard selection this many notes up (negative) or down from this note.
    var onMoveSelection: (Int) -> Void = { _ in }
    @State private var confirmingDelete = false
    @State private var renaming = false
    @State private var dropTargeted = false

    private var open: Binding<Bool> {
        Binding(
            get: { tree.isOpen(node.path) },
            set: { tree.setOpen($0, folder: node.path) }
        )
    }

    var body: some View {
        if node.isDirectory {
            let selected = tree.selection(activeTabID: model.activeTabID) == node.path
            Button {
                tree.selectFolder(node.path)
                open.wrappedValue.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                    Image(systemName: "folder")
                    Text(node.name)
                    Spacer()
                }
                .foregroundStyle(VGTheme.textNormal(dark: model.dark))
                .padding(.leading, 8 + CGFloat(depth) * 12)
                .padding(.vertical, 3)
                .background(folderBackground(selected: selected))
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(VGTheme.dropTarget, lineWidth: 1.5)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A right-click selects the folder before its menu opens, so the row the menu (and
            // any confirmation it leads to) acts on is the highlighted one.
            .background {
                SecondaryClickObserver { [tree, path = node.path] in tree.selectFolder(path) }
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .onDrop(
                of: [.vulkanGlassNote],
                delegate: FolderDropDelegate(
                    model: model,
                    folderPath: node.path,
                    targeted: $dropTargeted,
                    onMove: { open.wrappedValue = true }
                )
            )
            .contextMenu {
                FolderContextMenu(path: node.path, open: open)
                Button("Rename") {
                    tree.selectFolder(node.path)
                    onRenameFolder(node)
                }
                Divider()
                Button("Move to Trash…") {
                    tree.selectFolder(node.path)
                    onTrashFolder(node)
                }
            }
        } else {
            let active = model.activeTabID == node.path
            let selected = tree.selection(activeTabID: model.activeTabID) == node.path
            let keyboardFocused = tree.isFocusedSelection(node.path)
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
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                        Text(displayName)
                        Spacer()
                    }
                    .foregroundStyle(VGTheme.textNormal(dark: model.dark))
                    .padding(.leading, 20 + CGFloat(depth) * 14)
                    .padding(.vertical, 3)
                    // Presses fall through to the AppKit drag source behind the row.
                    .allowsHitTesting(false)
                    .background {
                        FileDragSource(
                            path: node.path,
                            model: model,
                            preview: { [dark = model.dark] size in
                                TabDragPreview.image(
                                    title: displayName,
                                    dark: dark,
                                    size: size,
                                    scale: NSScreen.main?.backingScaleFactor ?? 2
                                )
                            },
                            // A click keeps keyboard focus on the row, so the arrow keys move on
                            // from it; Return takes the note into the editor.
                            onClick: { openNote(node.path, focusEditor: false) },
                            onActivate: {
                                guard tree.selectedFolderPath == nil else { return }
                                let selectedPath = tree.focusRequestPath ?? node.path
                                openNote(selectedPath, focusEditor: true)
                            },
                            onSpace: {
                                guard tree.selectedFolderPath == nil else { return }
                                let selectedPath = tree.focusRequestPath ?? node.path
                                openNote(selectedPath, focusEditor: false)
                            },
                            onMoveSelection: onMoveSelection,
                            focusRequested: tree.focusRequestPath == node.path,
                            isFocusStillRequested: { tree.focusRequestPath == node.path },
                            onPointerFocus: { tree.notePressed() },
                            onFocusChange: { [tree, path = node.path] focused in
                                tree.focusChanged(path, focused: focused)
                            },
                            menuItems: [
                                FileDragSourceView.MenuItem(title: "Rename") { renaming = true },
                                FileDragSourceView.MenuItem(title: "Move to Trash…") { confirmingDelete = true },
                            ]
                        )
                    }
                    .background(rowBackground(selected: selected, keyboardFocused: keyboardFocused))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(active ? VGTheme.accent : Color.clear)
                            .frame(width: 2)
                            .allowsHitTesting(false)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction {
                        tree.notePressed()
                        openNote(node.path, focusEditor: true)
                    }
                    .accessibilityAction(named: "Rename") { renaming = true }
                    .accessibilityAction(named: "Move to Trash") { confirmingDelete = true }
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

    private func openNote(_ path: String, focusEditor: Bool) {
        let previousActiveTabID = model.activeTabID
        let token = tree.beginNoteOpen(path)
        Task {
            await model.openTab(path: path, focusEditor: focusEditor)
            tree.finishNoteOpen(token, activeTabID: model.activeTabID, previousActiveTabID: previousActiveTabID)
        }
    }

    /// Tints the note the keyboard is on with the accent, and shades the selected note otherwise.
    private func rowBackground(selected: Bool, keyboardFocused: Bool) -> Color {
        if keyboardFocused { return selectionTint }
        return selected ? VGTheme.hover(dark: model.dark) : Color.clear
    }

    /// Tints a folder the note is being dragged onto, otherwise the picked folder.
    private func folderBackground(selected: Bool) -> Color {
        if dropTargeted { return VGTheme.dropTarget.opacity(0.18) }
        return selected ? selectionTint : Color.clear
    }

    private var selectionTint: Color {
        VGTheme.accent.opacity(model.dark ? 0.3 : 0.22)
    }
}

/// The height of the file tree's rows, so the root drop area can fill the space below them.
enum FileTreeRowsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Accepts a note dragged from the file explorer onto a folder row (or, for the vault root,
/// onto the tree's free space) and moves the note into that folder.
struct FolderDropDelegate: DropDelegate {
    let model: AppModel
    let folderPath: String
    @Binding var targeted: Bool
    var onMove: () -> Void = {}

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.vulkanGlassNote]) && model.draggedFilePath != nil
    }

    func dropEntered(info: DropInfo) {
        updateTarget()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: updateTarget() ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) {
        targeted = false
    }

    /// Highlights the folder while it would accept the dragged note, and reports whether it would.
    @discardableResult
    func updateTarget() -> Bool {
        let accepts = model.draggedFilePath.map { model.canMoveNote($0, toFolder: folderPath) } ?? false
        if targeted != accepts { targeted = accepts }
        return accepts
    }

    func performDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.vulkanGlassNote]) else { return false }
        return drop() != nil
    }

    /// Starts moving the dragged note into the folder; nil when the drop is refused.
    @discardableResult
    func drop() -> Task<Bool, Never>? {
        targeted = false
        guard let path = model.draggedFilePath, model.canMoveNote(path, toFolder: folderPath) else {
            return nil
        }
        model.draggedFilePath = nil
        onMove()
        return Task { [model, folderPath] in await model.moveNote(path: path, toFolder: folderPath) }
    }
}

/// Makes a note row in the file explorer clickable, draggable, and right-clickable through
/// AppKit, like the tab strip's `TabDragSource`: SwiftUI's `onDrag` also offers the note as a
/// file promise, which the note editor's text view would accept.
struct FileDragSource: NSViewRepresentable {
    let path: String
    let model: AppModel
    var preview: (CGSize) -> NSImage?
    var onClick: () -> Void
    var onActivate: (() -> Void)?
    var onSpace: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var focusRequested = false
    var isFocusStillRequested: (() -> Bool)?
    var onPointerFocus: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var menuItems: [FileDragSourceView.MenuItem]

    func makeNSView(context: Context) -> FileDragSourceView {
        let view = FileDragSourceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: FileDragSourceView, context: Context) {
        nsView.path = path
        nsView.model = model
        nsView.preview = preview
        nsView.onClick = onClick
        nsView.onActivate = onActivate
        nsView.onSpace = onSpace
        nsView.onMoveSelection = onMoveSelection
        nsView.isFocusStillRequested = isFocusStillRequested
        nsView.onPointerFocus = onPointerFocus
        nsView.onFocusChange = onFocusChange
        nsView.menuItems = menuItems
        nsView.focusRequested = focusRequested
    }
}

final class FileDragSourceView: NSControl, NSDraggingSource {
    struct MenuItem {
        let title: String
        let action: () -> Void
    }

    var path = ""
    weak var model: AppModel?
    var preview: ((CGSize) -> NSImage?)?
    var onClick: (() -> Void)?
    /// Return: opens the note for editing. Falls back to `onClick`.
    var onActivate: (() -> Void)?
    /// Space: opens the selected note without moving focus to the editor.
    var onSpace: (() -> Void)?
    /// The up and down arrow keys: moves the selection by -1 or 1 notes.
    var onMoveSelection: ((Int) -> Void)?
    var isFocusStillRequested: (() -> Bool)?
    var onPointerFocus: (() -> Void)?
    /// Reports the row gaining (true) or losing (false) keyboard focus.
    var onFocusChange: ((Bool) -> Void)?
    /// Whether the row should take keyboard focus, as soon as it is in a window.
    var focusRequested = false {
        didSet { if focusRequested, !oldValue { takeRequestedFocus() } }
    }
    var menuItems: [MenuItem] = []
    var presentContextMenu: (NSMenu, NSEvent, NSView) -> Void = { menu, event, view in
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
    /// Whether AppKit is still running a drag session this view started, which outlives the
    /// drop itself while AppKit finishes (or animates back) the drag.
    private(set) var isDragSessionActive = false
    private var pressEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        onFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        onFocusChange?(false)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeRequestedFocus()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, window?.firstResponder === self {
            let onFocusChange = onFocusChange
            DispatchQueue.main.async { onFocusChange?(false) }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Makes the row first responder on the next turn of the run loop, outside SwiftUI's update.
    private func takeRequestedFocus() {
        guard focusRequested, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusRequested, self.isFocusStillRequested?() ?? true,
                  let window = self.window,
                  window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modified = !event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        switch event.specialKey {
        case .upArrow where !modified && onMoveSelection != nil:
            onMoveSelection?(-1)
            return
        case .downArrow where !modified && onMoveSelection != nil:
            onMoveSelection?(1)
            return
        default:
            break
        }
        if event.charactersIgnoringModifiers == "\r" {
            (onActivate ?? onClick)?()
        } else if event.charactersIgnoringModifiers == " " {
            (onSpace ?? onClick)?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? {
        (path as NSString).lastPathComponent
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        menuItems.map { item in
            NSAccessibilityCustomAction(name: item.title, handler: {
                item.action()
                return true
            })
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(for: event)
            return
        }
        takePointerFocus()
        pressEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press = pressEvent else { return }
        let start = press.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) >= TabDragSourceView.dragThreshold else { return }
        pressEvent = nil
        beginFileDrag(with: press)
    }

    override func mouseUp(with event: NSEvent) {
        if pressEvent != nil { onClick?() }
        pressEvent = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(for: event)
    }

    /// Selects the note, without opening it, so the row the menu acts on is highlighted.
    private func showContextMenu(for event: NSEvent) {
        pressEvent = nil
        guard let menu = menu(for: event) else { return }
        takePointerFocus()
        presentContextMenu(menu, event, self)
    }

    private func takePointerFocus() {
        onPointerFocus?()
        window?.makeFirstResponder(self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !menuItems.isEmpty else { return nil }
        let menu = NSMenu()
        for item in menuItems {
            let menuItem = NSMenuItem(title: item.title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.action
            menu.addItem(menuItem)
        }
        return menu
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }

    private func beginFileDrag(with event: NSEvent) {
        guard let model else { return }
        let draggingItem = NSDraggingItem(pasteboardWriter: Self.pasteboardItem(for: path))
        draggingItem.setDraggingFrame(bounds, contents: preview?(bounds.size))
        model.draggedFilePath = path
        isDragSessionActive = true
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// The drag payload: the private note type alone, which no text view registers for.
    static func pasteboardItem(for path: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(path, forType: NSPasteboard.PasteboardType(UTType.vulkanGlassNote.identifier))
        return item
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDragSessionActive = false
        endFileDrag()
    }

    /// Clears the in-process drag lookup once this note's drag ends, dropped or cancelled,
    /// without erasing a newer drag that has since started.
    func endFileDrag() {
        if model?.draggedFilePath == path { model?.draggedFilePath = nil }
    }
}

/// Reports a right-click or Control-click on the area behind a SwiftUI view without consuming
/// it, so the view's `contextMenu` still opens.
struct SecondaryClickObserver: NSViewRepresentable {
    var onSecondaryClick: () -> Void

    func makeNSView(context: Context) -> SecondaryClickObserverView {
        let view = SecondaryClickObserverView()
        view.onSecondaryClick = onSecondaryClick
        return view
    }

    func updateNSView(_ nsView: SecondaryClickObserverView, context: Context) {
        nsView.onSecondaryClick = onSecondaryClick
    }

    static func dismantleNSView(_ nsView: SecondaryClickObserverView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

final class SecondaryClickObserverView: NSView {
    var onSecondaryClick: (() -> Void)?
    private var monitor: Any?
    var isMonitoring: Bool { monitor != nil }

    /// Lets presses through to the SwiftUI content in front of it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        stopMonitoring()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        // A local monitor sees the press before SwiftUI turns it into the context menu.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            _ = MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
    }

    /// Reports `event` if it is a secondary click on the visible part of this view.
    @discardableResult
    func observe(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let secondary = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard secondary, bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil)) else {
            return false
        }
        onSecondaryClick?()
        return true
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
