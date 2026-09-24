import SwiftUI

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var leftResizeOrigin: CGFloat?
    @State private var rightResizeOrigin: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let rightWidth = model.rightOpen
                    ? VGTheme.clampedRightSidebarWidth(
                        model.settings.rightSidebarWidth,
                        windowWidth: geo.size.width,
                        leftSidebarVisible: model.leftOpen,
                        leftSidebarWidth: model.settings.leftSidebarWidth
                    )
                    : 0
                let leftWidth = VGTheme.clampedLeftSidebarWidth(
                    model.settings.leftSidebarWidth,
                    windowWidth: geo.size.width,
                    rightSidebarVisible: model.rightOpen,
                    rightSidebarWidth: model.settings.rightSidebarWidth
                )
                HStack(spacing: 0) {
                    ribbonColumn
                    if model.leftOpen {
                        leftColumn(width: leftWidth)
                        SplitHandle(
                            dark: model.dark,
                            resizable: true,
                            onChanged: { translation in
                                resizeSidebar(&leftResizeOrigin, current: leftWidth) { origin in
                                    model.settings.leftSidebarWidth = VGTheme.clampedLeftSidebarWidth(
                                        origin + translation,
                                        windowWidth: geo.size.width,
                                        rightSidebarVisible: model.rightOpen,
                                        rightSidebarWidth: model.settings.rightSidebarWidth
                                    )
                                }
                            },
                            onEnded: {
                                leftResizeOrigin = nil
                                SettingsStore.save(model.settings)
                            }
                        )
                    }
                    mainColumn
                    if model.rightOpen {
                        SplitHandle(
                            dark: model.dark,
                            resizable: true,
                            onChanged: { translation in
                                resizeSidebar(&rightResizeOrigin, current: rightWidth) { origin in
                                    model.settings.rightSidebarWidth = VGTheme.clampedRightSidebarWidth(
                                        origin - translation,
                                        windowWidth: geo.size.width,
                                        leftSidebarVisible: model.leftOpen,
                                        leftSidebarWidth: model.settings.leftSidebarWidth
                                    )
                                }
                            },
                            onEnded: {
                                rightResizeOrigin = nil
                                SettingsStore.save(model.settings)
                            }
                        )
                        rightColumn(width: rightWidth)
                    }
                }
            }
            StatusBarView()
        }
        .background(VGTheme.backgroundPrimary(dark: model.dark))
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
                Color.clear
                    .frame(width: max(0, VGTheme.trafficLightsInset - VGTheme.ribbonWidth))
                    .fixedSize()
                    .layoutPriority(1)
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
            .padding(.trailing, VGTheme.paneDividerInset)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            .padding(.trailing, VGTheme.paneDividerInset)
        }
        .frame(width: width)
        .background(VGTheme.backgroundSecondary(dark: model.dark))
    }

    /// Tab groups fill the main column, each with its own tab strip; the panes along the top
    /// carry their strips in the window title bar.
    private var mainColumn: some View {
        TabGroupsView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .background(VGTheme.backgroundPrimary(dark: model.dark))
    }

    private func rightColumn(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                RightSidebarPanelPicker()
                Spacer(minLength: 0)
                TitleBarIcon(
                    symbol: "sidebar.right",
                    help: "Toggle right sidebar",
                    active: true
                ) {
                    model.rightOpen = false
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, VGTheme.titleBarTrailingInset)
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

    /// Records the width at drag start and applies each update without implicit animation.
    private func resizeSidebar(
        _ origin: inout CGFloat?,
        current: CGFloat,
        apply: (CGFloat) -> Void
    ) {
        if origin == nil { origin = current }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            apply(origin ?? current)
        }
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
    @ObservedObject var updater: AppUpdater

    static let gitInstallInstructions = """
        Vulkan Glass uses Git to sync vaults with GitHub. You can still open and edit notes, \
        but syncing, cloning, and creating vaults won't work until Git is installed.

        Install it either way from Terminal:

        Command Line Tools (Apple): run xcode-select --install and follow the installer.

        Homebrew: run brew install git.

        Vulkan Glass picks Git up as soon as it is installed.
        """

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
        .sheet(isPresented: Bindable(model).settingsOpen) { SettingsSheet(updater: updater) }
        .sheet(isPresented: Bindable(model).cloneOpen) { CloneVaultSheet() }
        .sheet(isPresented: Bindable(model).createOpen) { CreateVaultSheet() }
        .alert("Git is not installed", isPresented: Bindable(model).gitMissingWarningOpen) {
            Button("OK") {}
        } message: {
            Text(Self.gitInstallInstructions)
        }
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
        .preferredColorScheme(model.settings.appearanceMode.preferredColorScheme)
    }
}

extension AppearanceMode {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .inherit: nil
        case .light: .light
        case .dark: .dark
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
