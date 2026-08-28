import SwiftUI

struct TitleBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: VGTheme.trafficLightsInset - 12)
            icon("sidebar.left", active: model.leftOpen) { model.leftOpen.toggle() }
            icon("sidebar.right", active: model.rightOpen) { model.rightOpen.toggle() }
            Spacer()
            Text(model.vault?.name ?? model.activeTab?.title ?? "Vulkan Glass")
                .font(.system(size: 13))
                .foregroundStyle(VGTheme.textMuted(dark: model.dark))
            Spacer()
            icon(model.editorMode == .source ? "book" : "chevron.left.forwardslash.chevron.right",
                 active: model.editorMode == .preview) {
                model.editorMode = model.editorMode == .source ? .preview : .source
                model.centerView = .editor
            }
            icon("plus") { Task { await model.newNote() } }
        }
        .padding(.trailing, 8)
        .frame(height: VGTheme.titleBarHeight)
        .background(VGTheme.backgroundSecondary(dark: model.dark))
        .overlay(alignment: .bottom) {
            VGTheme.divider(dark: model.dark).frame(height: 1)
        }
    }

    private func icon(_ symbol: String, active: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(active ? VGTheme.textAccent : VGTheme.textMuted(dark: model.dark))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
    }
}

struct StatusBarView: View {
    @Environment(AppModel.self) private var model

    var backlinks: Int {
        guard let tab = model.activeTab else { return 0 }
        return model.notes.filter { $0.wikiLinks.contains { $0.caseInsensitiveCompare(tab.title) == .orderedSame } }.count
    }

    var body: some View {
        HStack {
            Button {
                Task { await model.syncNow() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.vault == nil ? "lock" : (model.gitStatus?.state == .syncing ? "arrow.triangle.2.circlepath" : "icloud"))
                    Text(model.gitStatus?.message ?? (model.vault == nil ? "Standalone" : "GitHub vault"))
                        .lineLimit(1)
                    if let branch = model.vault?.branch {
                        Text(branch).foregroundStyle(VGTheme.textFaint(dark: model.dark))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(VGTheme.textMuted(dark: model.dark))
            }
            .buttonStyle(.plain)
            Spacer()
            if model.activeTab != nil {
                Text("\(backlinks) backlink\(backlinks == 1 ? "" : "s")")
            }
            Text("\(model.wordCount) words")
            Text(model.editorMode == .source ? "Source" : "Reading")
        }
        .font(.system(size: 11))
        .foregroundStyle(VGTheme.textMuted(dark: model.dark))
        .padding(.horizontal, 12)
        .frame(height: VGTheme.statusBarHeight)
        .background(VGTheme.backgroundSecondary(dark: model.dark))
        .overlay(alignment: .top) {
            VGTheme.divider(dark: model.dark).frame(height: 1)
        }
    }
}
