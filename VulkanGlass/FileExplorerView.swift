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

struct FileExplorerView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var folderDraft = FolderCreationDraft()
    @State private var askingFolder = false
    @State private var rootDropTargeted = false
    @State private var treeRowsHeight: CGFloat = 0

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
                GeometryReader { geometry in
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
                                    ForEach(filtered(model.fileTree)) { node in
                                        TreeRow(node: node, depth: 0)
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
                                .frame(height: max(12, geometry.size.height - treeRowsHeight))
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
    @State private var dropTargeted = false

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
                .background(dropTargeted ? VGTheme.dropTarget.opacity(0.18) : Color.clear)
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
            .onDrop(
                of: [.vulkanGlassNote],
                delegate: FolderDropDelegate(
                    model: model,
                    folderPath: node.path,
                    targeted: $dropTargeted,
                    onMove: { open = true }
                )
            )
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
                            onClick: { Task { await model.openTab(path: node.path) } },
                            menuItems: [
                                FileDragSourceView.MenuItem(title: "Rename") { renaming = true },
                                FileDragSourceView.MenuItem(title: "Move to Trash…") { confirmingDelete = true },
                            ]
                        )
                    }
                    .background(active ? VGTheme.hover(dark: model.dark) : Color.clear)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(active ? VGTheme.accent : Color.clear)
                            .frame(width: 2)
                            .allowsHitTesting(false)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { Task { await model.openTab(path: node.path) } }
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
}

/// The height of the file tree's rows, so the root drop area can fill the space below them.
private enum FileTreeRowsHeightKey: PreferenceKey {
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
        nsView.menuItems = menuItems
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

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == " " {
            onClick?()
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
            pressEvent = nil
            if let menu = menu(for: event) {
                presentContextMenu(menu, event, self)
            }
            return
        }
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
