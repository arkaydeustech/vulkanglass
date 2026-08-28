import SwiftUI

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var leftResizeOrigin: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let leftWidth = VGTheme.clampedLeftSidebarWidth(
                    model.settings.leftSidebarWidth,
                    windowWidth: geo.size.width,
                    rightSidebarVisible: model.rightOpen
                )
                HStack(spacing: 0) {
                    ribbonColumn
                    if model.leftOpen {
                        leftColumn(width: leftWidth)
                        SplitHandle(
                            dark: model.dark,
                            onChanged: { translation in
                                if leftResizeOrigin == nil { leftResizeOrigin = leftWidth }
                                model.settings.leftSidebarWidth = VGTheme.clampedLeftSidebarWidth(
                                    (leftResizeOrigin ?? leftWidth) + translation,
                                    windowWidth: geo.size.width,
                                    rightSidebarVisible: model.rightOpen
                                )
                            },
                            onEnded: {
                                leftResizeOrigin = nil
                                SettingsStore.save(model.settings)
                            }
                        )
                    }
                    mainColumn(showRightToggle: !model.rightOpen)
                    if model.rightOpen {
                        VGTheme.divider(dark: model.dark).frame(width: 1)
                        rightColumn(width: VGTheme.cappedSidebarWidth(windowWidth: geo.size.width))
                    }
                }
            }
            StatusBarView()
        }
        .background(VGTheme.backgroundPrimary(dark: model.dark))
        .preferredColorScheme(model.dark ? .dark : .light)
        .alert(
            "Vulkan Glass",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "An unexpected error occurred.")
        }
    }

    private var ribbonColumn: some View {
        VStack(spacing: 0) {
            titleBarBackground
            RibbonView()
        }
        .frame(width: VGTheme.ribbonWidth)
    }

    private func leftColumn(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Color.clear.frame(width: max(0, VGTheme.trafficLightsInset - VGTheme.ribbonWidth))
                TitleBarIcon(
                    symbol: "folder",
                    help: "Files",
                    active: model.leftPanel == .files
                ) {
                    model.leftPanel = .files
                    model.centerView = .editor
                }
                TitleBarIcon(
                    symbol: "magnifyingglass",
                    help: "Search",
                    active: model.leftPanel == .search
                ) {
                    model.leftPanel = .search
                }
                Spacer(minLength: 0)
                TitleBarIcon(
                    symbol: "sidebar.left",
                    help: "Toggle left sidebar",
                    active: true
                ) {
                    model.leftOpen = false
                }
            }
            .padding(.trailing, 2)
            .frame(height: VGTheme.titleBarHeight)
            .background(VGTheme.backgroundSecondary(dark: model.dark))
            .background(WindowDragRegion())
            .overlay(alignment: .bottom) {
                VGTheme.divider(dark: model.dark).frame(height: 1)
            }

            Group {
                if model.leftPanel == .search {
                    SearchPanelView()
                } else {
                    FileExplorerView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width)
        .background(VGTheme.backgroundSecondary(dark: model.dark))
    }

    private func mainColumn(showRightToggle: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !model.leftOpen {
                    Color.clear.frame(width: VGTheme.collapsedLeftTitleBarInset)
                    TitleBarIcon(
                        symbol: "sidebar.left",
                        help: "Toggle left sidebar",
                        active: false
                    ) {
                        model.leftOpen = true
                    }
                    .padding(.leading, 4)
                    VGTheme.divider(dark: model.dark)
                        .frame(width: 1)
                        .padding(.vertical, 6)
                        .padding(.trailing, 2)
                }
                TitleBarTabStrip()
                Spacer(minLength: 8)
                TitleBarIcon(
                    symbol: model.editorMode == .source ? "book" : "square.and.pencil",
                    help: "Toggle reading view",
                    active: model.editorMode == .preview
                ) {
                    model.editorMode = model.editorMode == .source ? .preview : .source
                    model.centerView = .editor
                }
                if showRightToggle {
                    TitleBarIcon(
                        symbol: "sidebar.right",
                        help: "Toggle right sidebar",
                        active: false
                    ) {
                        model.rightOpen = true
                    }
                    .padding(.trailing, 6)
                }
            }
            .frame(height: VGTheme.titleBarHeight)
            .background(VGTheme.backgroundSecondary(dark: model.dark))
            .background(WindowDragRegion())
            .overlay(alignment: .bottom) {
                VGTheme.divider(dark: model.dark).frame(height: 1)
            }

            Group {
                if model.centerView == .graph {
                    GraphView()
                } else {
                    NoteEditorView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .background(VGTheme.backgroundPrimary(dark: model.dark))
    }

    private func rightColumn(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                TitleBarIcon(
                    symbol: "sidebar.right",
                    help: "Toggle right sidebar",
                    active: true
                ) {
                    model.rightOpen = false
                }
            }
            .padding(.trailing, 6)
            .frame(height: VGTheme.titleBarHeight)
            .background(VGTheme.backgroundSecondary(dark: model.dark))
            .background(WindowDragRegion())
            .overlay(alignment: .bottom) {
                VGTheme.divider(dark: model.dark).frame(height: 1)
            }

            RightSidebarView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width)
        .clipped()
        .background(VGTheme.backgroundSecondary(dark: model.dark))
    }

    private var titleBarBackground: some View {
        Color.clear
            .frame(height: VGTheme.titleBarHeight)
            .frame(maxWidth: .infinity)
            .background(VGTheme.backgroundSecondary(dark: model.dark))
            .background(WindowDragRegion())
            .overlay(alignment: .bottom) {
                VGTheme.divider(dark: model.dark).frame(height: 1)
            }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if model.inWorkspace {
                WorkspaceView()
            } else {
                WelcomeView()
            }
            if model.commandOpen {
                CommandPaletteView()
            }
            if model.switcherOpen {
                QuickSwitcherView()
            }
        }
        .foregroundStyle(VGTheme.textNormal(dark: model.dark))
        .background(WindowChromeConfigurator())
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: Bindable(model).settingsOpen) { SettingsSheet() }
        .sheet(isPresented: Bindable(model).cloneOpen) { CloneVaultSheet() }
        .sheet(isPresented: Bindable(model).createOpen) { CreateVaultSheet() }
        .overlay(alignment: .top) {
            if let message = model.errorMessage, !model.inWorkspace {
                ErrorToastView(message: message) {
                    if model.errorMessage == message { model.errorMessage = nil }
                }
                .padding(.top, VGTheme.titleBarHeight + 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.errorMessage)
        .overlay(alignment: .bottom) {
            if let busy = model.busyMessage {
                Text(busy)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 36)
            }
        }
    }
}

/// Transient banner shown on the welcome screen when a vault cannot be opened.
struct ErrorToastView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 480, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .task(id: message) {
            if await Self.shouldAutoDismiss() { dismiss() }
        }
    }

    static func shouldAutoDismiss(after duration: Duration = .seconds(5)) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}
