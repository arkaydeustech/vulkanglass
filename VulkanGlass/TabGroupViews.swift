import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// In-app drag payload for a note tab; the data is the tab's ID (its file path).
    static let vulkanGlassNoteTab = UTType(exportedAs: "app.vulkanglass.note-tab")
}

/// Makes a tab clickable and draggable through AppKit rather than SwiftUI's `onDrag`.
///
/// The tabs sit in the window title bar, where a SwiftUI drag usually moved the whole window
/// instead. `onDrag` also offers the tab as a file promise, which the note editor's text view
/// accepts, so it took the drag and hid the pane's split zones. This view never moves the
/// window, and its drag carries only the private tab type.
struct TabDragSource: NSViewRepresentable {
    let tabID: String
    let model: AppModel
    var preview: (CGSize) -> NSImage?
    var onClick: () -> Void

    func makeNSView(context: Context) -> TabDragSourceView {
        let view = TabDragSourceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: TabDragSourceView, context: Context) {
        nsView.tabID = tabID
        nsView.model = model
        nsView.preview = preview
        nsView.onClick = onClick
    }
}

/// An `NSControl` rather than a plain `NSView`: in the title bar AppKit lets a drag on any
/// non-control view move the window, whatever its `mouseDownCanMoveWindow` says.
final class TabDragSourceView: NSControl, NSDraggingSource {
    var tabID = ""
    weak var model: AppModel?
    var preview: ((CGSize) -> NSImage?)?
    var onClick: (() -> Void)?
    /// Pointer travel, in points, before a press on a tab becomes a drag.
    static let dragThreshold: CGFloat = 4
    private var pressEvent: NSEvent?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press = pressEvent else { return }
        let start = press.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) >= Self.dragThreshold else { return }
        pressEvent = nil
        beginTabDrag(with: press)
    }

    override func mouseUp(with event: NSEvent) {
        if pressEvent != nil { onClick?() }
        pressEvent = nil
    }

    private func beginTabDrag(with event: NSEvent) {
        guard let model else { return }
        let draggingItem = NSDraggingItem(pasteboardWriter: Self.pasteboardItem(for: tabID))
        draggingItem.setDraggingFrame(bounds, contents: preview?(bounds.size))
        model.draggedTabID = tabID
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// The drag payload: the private tab type alone, which no text view registers for.
    static func pasteboardItem(for tabID: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(tabID, forType: NSPasteboard.PasteboardType(UTType.vulkanGlassNoteTab.identifier))
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
        endTabDrag()
    }

    /// Clears the in-process drag lookup once this tab's drag ends, dropped or cancelled,
    /// without erasing a newer drag that has since started.
    func endTabDrag() {
        if model?.draggedTabID == tabID { model?.draggedTabID = nil }
    }
}

/// The image that follows the pointer while a tab is dragged.
struct TabDragPreview: View {
    let title: String
    let dark: Bool

    var body: some View {
        Text(title)
            .lineLimit(1)
            .font(.system(size: 13))
            .foregroundStyle(VGTheme.textNormal(dark: dark))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(VGTheme.backgroundPrimary(dark: dark))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(VGTheme.dropTarget, lineWidth: 1.5)
            )
            .opacity(0.9)
    }

    @MainActor
    static func image(title: String, dark: Bool, size: CGSize, scale: CGFloat) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let renderer = ImageRenderer(
            content: TabDragPreview(title: title, dark: dark)
                .frame(width: size.width, height: size.height)
        )
        renderer.scale = scale
        return renderer.nsImage
    }
}

/// Which outer edges of the main display area a pane touches. The pane along the top edge
/// holds its tab strip in the window title bar, and the outermost ones host the sidebar toggles.
struct PaneEdges: Equatable {
    var top = true
    var leading = true
    var trailing = true

    static let all = PaneEdges()

    /// Edges each half of a split inherits from the pane it divides.
    func children(for axis: SplitAxis) -> (first: PaneEdges, second: PaneEdges) {
        switch axis {
        case .horizontal:
            (
                PaneEdges(top: top, leading: leading, trailing: false),
                PaneEdges(top: top, leading: false, trailing: trailing)
            )
        case .vertical:
            (
                PaneEdges(top: top, leading: leading, trailing: trailing),
                PaneEdges(top: false, leading: leading, trailing: trailing)
            )
        }
    }
}

/// The main display area: one pane per tab group, divided by the layout's splits.
struct TabGroupsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneNodeView(node: model.tabGroupLayout.root, edges: .all)
    }
}

struct PaneNodeView: View {
    let node: PaneNode
    let edges: PaneEdges

    var body: some View {
        switch node {
        case let .group(id):
            TabGroupPane(groupID: id, edges: edges)
                .id(id)
        case let .split(split):
            // Type-erased so the recursive split does not define its opaque type in terms of itself.
            AnyView(PaneSplitView(split: split, edges: edges))
        }
    }
}

/// Two panes and the draggable divider between them.
struct PaneSplitView: View {
    @Environment(AppModel.self) private var model
    let split: PaneSplit
    let edges: PaneEdges
    @State private var resizeOrigin: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let horizontal = split.axis == .horizontal
            let total = max(0, (horizontal ? geo.size.width : geo.size.height) - VGTheme.splitLineWidth)
            let fraction = Self.clampedFraction(model.paneSplitFraction(split.id), total: total)
            let firstLength = total * fraction
            let childEdges = edges.children(for: split.axis)
            let handle = SplitHandle(
                dark: model.dark,
                resizable: true,
                axis: split.axis,
                onChanged: { translation in
                    guard total > 0 else { return }
                    if resizeOrigin == nil { resizeOrigin = firstLength }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        model.resizePaneSplit(
                            split.id,
                            fraction: Self.resizedFraction(
                                origin: resizeOrigin ?? firstLength,
                                translation: translation,
                                total: total
                            )
                        )
                    }
                },
                onEnded: { resizeOrigin = nil }
            )
            if horizontal {
                HStack(spacing: 0) {
                    PaneNodeView(node: split.first, edges: childEdges.first)
                        .frame(width: firstLength)
                    handle
                    PaneNodeView(node: split.second, edges: childEdges.second)
                        .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    PaneNodeView(node: split.first, edges: childEdges.first)
                        .frame(height: firstLength)
                    handle
                    PaneNodeView(node: split.second, edges: childEdges.second)
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }

    /// Keeps both panes at least `tabGroupMinLength` long when there is room for that.
    static func clampedFraction(_ fraction: CGFloat, total: CGFloat) -> CGFloat {
        guard total > 0 else { return 0.5 }
        let minimum = min(0.5, VGTheme.tabGroupMinLength / total)
        return min(max(fraction, minimum), 1 - minimum)
    }

    static func resizedFraction(origin: CGFloat, translation: CGFloat, total: CGFloat) -> CGFloat {
        guard total > 0 else { return 0.5 }
        return clampedFraction((origin + translation) / total, total: total)
    }
}

/// One tab group: its tab strip above the focused note (or the graph), accepting dropped tabs.
struct TabGroupPane: View {
    @Environment(AppModel.self) private var model
    let groupID: UUID
    let edges: PaneEdges
    @State private var dropZone: PaneDropZone?
    @State private var contentSize: CGSize = .zero

    private var isFocused: Bool { model.tabGroupLayout.focusedGroupID == groupID }

    var body: some View {
        VStack(spacing: 0) {
            TabGroupHeader(groupID: groupID, edges: edges)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { dropHighlight }
                .onDrop(
                    of: [.vulkanGlassNoteTab],
                    delegate: PaneDropDelegate(
                        model: model,
                        groupID: groupID,
                        paneSize: contentSize,
                        zone: $dropZone
                    )
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VGTheme.backgroundPrimary(dark: model.dark))
        .background(PaneMouseDownMonitor(
            canFocus: { !model.commandOpen && !model.switcherOpen },
            onMouseDown: {
                Task {
                    guard !model.commandOpen && !model.switcherOpen else { return }
                    await model.focusGroup(groupID, placement: .preserveSelection)
                }
            }
        ))
    }

    @ViewBuilder
    private var content: some View {
        if isFocused, model.centerView == .graph {
            GraphView()
        } else {
            NoteEditorView(groupID: groupID)
        }
    }

    /// The blue box over the half (or whole) of the pane that the dragged tab would take.
    private var dropHighlight: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear
                if let dropZone {
                    let rect = dropZone.highlightRect(in: geo.size).insetBy(dx: 4, dy: 4)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(VGTheme.dropTarget.opacity(0.18))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(VGTheme.dropTarget, lineWidth: 2)
                        }
                        .frame(width: max(0, rect.width), height: max(0, rect.height))
                        .offset(x: rect.minX, y: rect.minY)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: dropZone)
            .onAppear { contentSize = geo.size }
            .onChange(of: geo.size) { _, size in contentSize = size }
        }
        .allowsHitTesting(false)
    }
}

/// Tracks a dragged tab over a pane and splits or joins the group when it is released.
struct PaneDropDelegate: DropDelegate {
    let model: AppModel
    let groupID: UUID
    /// DropInfo carries only the pointer location, so the pane reports its own size.
    let paneSize: CGSize
    @Binding var zone: PaneDropZone?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.vulkanGlassNoteTab]) && model.draggedTabID != nil
    }

    func dropEntered(info: DropInfo) {
        zone = acceptedZone(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let accepted = acceptedZone(for: info)
        if zone != accepted { zone = accepted }
        return DropProposal(operation: accepted == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        zone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.vulkanGlassNoteTab]) else { return false }
        return performDrop(at: info.location)
    }

    /// Shared by the drop callback and interaction tests using the pane's live size.
    func performDrop(at location: CGPoint) -> Bool {
        let accepted = acceptedZone(at: location)
        zone = nil
        guard let accepted, let tabID = model.draggedTabID else { return false }
        model.draggedTabID = nil
        model.dropTab(tabID, on: groupID, zone: accepted)
        return true
    }

    private func acceptedZone(for info: DropInfo) -> PaneDropZone? {
        guard info.hasItemsConforming(to: [.vulkanGlassNoteTab]) else { return nil }
        return acceptedZone(at: info.location)
    }

    func acceptedZone(at location: CGPoint) -> PaneDropZone? {
        guard let tabID = model.draggedTabID else { return nil }
        let candidate = PaneDropZone.zone(for: location, in: paneSize)
        return model.canDropTab(tabID, on: groupID, zone: candidate) ? candidate : nil
    }
}

/// Tab strip, reading-view toggle, and (on the outer panes) sidebar toggles for one group.
struct TabGroupHeader: View {
    @Environment(AppModel.self) private var model
    let groupID: UUID
    let edges: PaneEdges

    private var activeTab: NoteTab? {
        guard let id = model.tabGroupLayout.group(groupID)?.activeTabID else { return nil }
        return model.tabs.first { $0.id == id }
    }

    private var editorMode: EditorMode { activeTab?.editorMode ?? model.editorMode }
    private var showLeftToggle: Bool { edges.top && edges.leading && !model.leftOpen }
    private var showRightToggle: Bool { edges.top && edges.trailing && !model.rightOpen }

    var body: some View {
        HStack(spacing: 0) {
            if showLeftToggle {
                TitleBarIcon(
                    symbol: "sidebar.left",
                    help: "Toggle left sidebar",
                    active: false
                ) {
                    model.leftOpen = true
                }
                .padding(.leading, VGTheme.collapsedLeftTitleBarInset + 8)
                .layoutPriority(1)
                VGTheme.divider(dark: model.dark)
                    .frame(width: 1)
                    .padding(.vertical, 8)
                    .padding(.trailing, 2)
            }
            TabGroupTabStrip(groupID: groupID, inTitleBar: edges.top)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                TitleBarIcon(symbol: "book", help: "Reading view", active: editorMode == .preview) {
                    show(.preview)
                }
                TitleBarIcon(symbol: "square.and.pencil", help: "Edit", active: editorMode == .source) {
                    show(.source)
                }
                TitleBarIcon(
                    symbol: "chevron.left.forwardslash.chevron.right",
                    help: "Raw Markdown",
                    active: editorMode == .raw
                ) {
                    show(.raw)
                }
            }
            .padding(.trailing, trailingPadding)
            if showRightToggle {
                TitleBarIcon(
                    symbol: "sidebar.right",
                    help: "Toggle right sidebar",
                    active: false
                ) {
                    model.rightOpen = true
                }
                .padding(.trailing, VGTheme.titleBarTrailingInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: VGTheme.titleBarHeight)
        // Above the fill, so empty space hit-tests to the region (see `TitleBarDoubleClick`).
        .background {
            if edges.top { WindowDragRegion() }
        }
        .background(VGTheme.backgroundSecondary(dark: model.dark))
        .overlay(alignment: .bottom) {
            VGTheme.divider(dark: model.dark).frame(height: 1)
        }
    }

    private func show(_ mode: EditorMode) {
        Task {
            await model.focusGroup(groupID)
            guard model.tabGroupLayout.focusedGroupID == groupID else { return }
            model.editorMode = mode
            model.centerView = .editor
        }
    }

    private var trailingPadding: CGFloat {
        if showRightToggle { return 0 }
        // The window-level sidebar divider needs room for its hit area; a pane divider less so.
        return edges.trailing ? VGTheme.paneDividerInset : 8
    }
}

/// Note tabs of one tab group. Tabs can be dragged to reorder them, onto another group's
/// strip to move them there, or onto a pane to split it.
struct TabGroupTabStrip: View {
    @Environment(AppModel.self) private var model
    let groupID: UUID
    /// Whether the strip sits in the window title bar, where its empty space behaves like it.
    var inTitleBar = false
    @State private var insertionIndex: Int?
    @State private var appending = false
    @State private var visibleWidth: CGFloat = 0

    private var group: TabGroup? { model.tabGroupLayout.group(groupID) }
    private var isFocused: Bool { model.tabGroupLayout.focusedGroupID == groupID }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    let tabs = model.tabs(inGroup: groupID)
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        tabView(tab)
                            .overlay(alignment: .leading) {
                                if insertionIndex == index {
                                    Rectangle()
                                        .fill(VGTheme.dropTarget)
                                        .frame(width: 2)
                                }
                            }
                            .onDrop(
                                of: [.vulkanGlassNoteTab],
                                delegate: TabStripDropDelegate(
                                    model: model,
                                    groupID: groupID,
                                    index: index,
                                    highlighted: insertionHighlight(for: index)
                                )
                            )
                    }
                }
                // The scroll view covers the space past the last tab, so the title bar's drag
                // region has to reach in there too.
                .frame(minWidth: inTitleBar ? visibleWidth : 0, alignment: .leading)
                .background {
                    if inTitleBar { WindowDragRegion() }
                }
            }
            .frame(minWidth: 0)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { visibleWidth = $0 }
            Button {
                Task {
                    await model.focusGroup(groupID)
                    await model.newNote(inGroup: groupID)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: VGTheme.titleBarIconFont))
                    .frame(width: VGTheme.titleBarIconSize, height: VGTheme.titleBarHeight)
                    .foregroundStyle(VGTheme.textMuted(dark: model.dark))
            }
            .buttonStyle(.plain)
            .help("New note")
        }
        .overlay {
            if appending {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(VGTheme.dropTarget, lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4).fill(VGTheme.dropTarget.opacity(0.12))
                    )
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [.vulkanGlassNoteTab],
            delegate: TabStripDropDelegate(
                model: model,
                groupID: groupID,
                index: nil,
                highlighted: $appending,
                preferredIndex: { insertionIndex }
            )
        )
    }

    /// Marks `index` as the insertion point while a tab hovers over it.
    private func insertionHighlight(for index: Int) -> Binding<Bool> {
        Binding(
            get: { insertionIndex == index },
            set: { hovering in
                if hovering {
                    insertionIndex = index
                } else if insertionIndex == index {
                    insertionIndex = nil
                }
            }
        )
    }

    private func tabView(_ tab: NoteTab) -> some View {
        let isGroupActive = tab.id == group?.activeTabID
        let showingGraph = isFocused && model.centerView == .graph
        let active = isGroupActive && !showingGraph
        return HStack(spacing: 6) {
            Text((tab.dirty ? "• " : "") + tab.title)
                .lineLimit(1)
                .font(.system(size: 13))
                .foregroundStyle(
                    active ? VGTheme.textNormal(dark: model.dark) : VGTheme.textMuted(dark: model.dark)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                // Presses on the title fall through to the AppKit drag source behind it.
                .allowsHitTesting(false)
            Button {
                Task { await model.closeTab(tab.id) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(VGTheme.textFaint(dark: model.dark))
        }
        .padding(.horizontal, 10)
        .frame(height: VGTheme.titleBarHeight)
        .frame(minWidth: 100, maxWidth: 200)
        .background {
            TabDragSource(
                tabID: tab.id,
                model: model,
                preview: { [dark = model.dark] size in
                    TabDragPreview.image(
                        title: tab.title,
                        dark: dark,
                        size: size,
                        scale: NSScreen.main?.backingScaleFactor ?? 2
                    )
                },
                onClick: { Task { await model.setActiveTab(tab.id) } }
            )
        }
        .background(active ? VGTheme.backgroundPrimary(dark: model.dark) : Color.clear)
        .overlay(alignment: .bottom) {
            // Only the focused group's tab carries the accent, so the focused pane is obvious.
            Rectangle()
                .fill(active && isFocused ? VGTheme.accent : Color.clear)
                .frame(height: 2)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            VGTheme.divider(dark: model.dark).frame(width: 1).allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(tab.title)
        .accessibilityAction { Task { await model.setActiveTab(tab.id) } }
    }
}

/// Accepts a dragged tab on a tab strip: over a tab it is inserted before that tab, over the
/// strip's free space it is appended.
struct TabStripDropDelegate: DropDelegate {
    let model: AppModel
    let groupID: UUID
    let index: Int?
    @Binding var highlighted: Bool
    var preferredIndex: () -> Int? = { nil }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.vulkanGlassNoteTab]) && model.draggedTabID != nil
    }

    func dropEntered(info: DropInfo) {
        updateHighlight()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateHighlight()
        return DropProposal(operation: .move)
    }

    func updateHighlight() {
        let shouldHighlight = model.draggedTabID != nil && preferredIndex() == nil
        if highlighted != shouldHighlight { highlighted = shouldHighlight }
    }

    func dropExited(info: DropInfo) {
        highlighted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.vulkanGlassNoteTab]) else { return false }
        return performDrop()
    }

    func performDrop() -> Bool {
        highlighted = false
        guard let tabID = model.draggedTabID else { return false }
        model.draggedTabID = nil
        model.moveTab(tabID, toGroup: groupID, at: index ?? preferredIndex())
        return true
    }
}

/// Reports mouse-downs anywhere inside its frame without intercepting them, so clicking into a
/// pane's editor (an AppKit text view that swallows SwiftUI gestures) focuses that pane.
struct PaneMouseDownMonitor: NSViewRepresentable {
    var canFocus: () -> Bool
    var onMouseDown: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.canFocus = canFocus
        view.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.canFocus = canFocus
        nsView.onMouseDown = onMouseDown
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var canFocus: (() -> Bool)?
        var onMouseDown: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        func handle(_ event: NSEvent) {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor,
                  canFocus?() == true else { return }
            let point = convert(event.locationInWindow, from: nil)
            if bounds.contains(point) { onMouseDown?() }
        }
    }
}
