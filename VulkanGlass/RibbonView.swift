import SwiftUI

/// Vertical left ribbon matching Obsidian's icon rail. Traffic lights sit above it.
struct RibbonView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 4) {
            Color.clear.frame(height: VGTheme.titleBarHeight)
            ribbon("New note", "square.and.pencil") { Task { await model.newNote() } }
            ribbon("Files", "folder", active: model.leftOpen && model.leftPanel == .files && model.centerView == .editor) {
                model.leftPanel = .files
                model.leftOpen = true
                model.centerView = .editor
            }
            ribbon("Search", "magnifyingglass", active: model.leftOpen && model.leftPanel == .search) {
                model.leftPanel = .search
                model.leftOpen = true
            }
            ribbon("Graph view", "point.3.connected.trianglepath.dotted", active: model.centerView == .graph) {
                model.centerView = .graph
            }
            ribbon("Daily note", "calendar") { Task { await model.dailyNote() } }
            Spacer()
            Button {
                Task { await model.closeVault() }
            } label: {
                LogoView(size: 18)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("Switch vault")
            ribbon("Settings", "gearshape") { model.settingsOpen = true }
        }
        .padding(.bottom, 8)
        .frame(width: VGTheme.ribbonWidth)
        .background(VGTheme.backgroundTertiary(dark: model.dark))
    }

    private func ribbon(_ title: String, _ symbol: String, active: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(active ? VGTheme.textAccent : VGTheme.textMuted(dark: model.dark))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? VGTheme.accent.opacity(0.22) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
