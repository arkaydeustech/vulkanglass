import SwiftUI

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                RibbonView()
                if model.leftOpen {
                    VStack(spacing: 0) {
                        sidebarHeader
                        if model.leftPanel == .search {
                            SearchPanelView()
                        } else {
                            FileExplorerView()
                        }
                    }
                    .frame(width: VGTheme.sidebarWidth)
                    .background(VGTheme.backgroundSecondary(dark: model.dark))
                    VGTheme.divider(dark: model.dark).frame(width: 1)
                }
                VStack(spacing: 0) {
                    if model.centerView == .graph {
                        graphHeader
                        GraphView()
                    } else {
                        TabBarView()
                        NoteEditorView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VGTheme.backgroundPrimary(dark: model.dark))
                if model.rightOpen {
                    VGTheme.divider(dark: model.dark).frame(width: 1)
                    RightSidebarView()
                        .frame(width: VGTheme.sidebarWidth)
                        .background(VGTheme.backgroundSecondary(dark: model.dark))
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

    private var sidebarHeader: some View {
        HStack(spacing: 4) {
            headerIcon("folder", active: model.leftPanel == .files) {
                model.leftPanel = .files
            }
            headerIcon("magnifyingglass", active: model.leftPanel == .search) {
                model.leftPanel = .search
            }
            Spacer()
            headerIcon("sidebar.left", active: model.leftOpen) {
                model.leftOpen.toggle()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: VGTheme.titleBarHeight)
        .overlay(alignment: .bottom) { VGTheme.divider(dark: model.dark).frame(height: 1) }
    }

    private var graphHeader: some View {
        HStack {
            Text("Graph")
                .font(.system(size: 13))
                .foregroundStyle(VGTheme.textMuted(dark: model.dark))
            Spacer()
            headerIcon("book", active: false) {
                model.centerView = .editor
            }
        }
        .padding(.horizontal, 12)
        .frame(height: VGTheme.titleBarHeight)
        .background(VGTheme.backgroundSecondary(dark: model.dark))
        .overlay(alignment: .bottom) { VGTheme.divider(dark: model.dark).frame(height: 1) }
    }

    private func headerIcon(_ symbol: String, active: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(active ? VGTheme.textAccent : VGTheme.textMuted(dark: model.dark))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
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
        .sheet(isPresented: Bindable(model).settingsOpen) { SettingsSheet() }
        .sheet(isPresented: Bindable(model).cloneOpen) { CloneVaultSheet() }
        .sheet(isPresented: Bindable(model).createOpen) { CreateVaultSheet() }
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
