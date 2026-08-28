import AppKit
import SwiftUI

/// Compact title-bar button used by the window chrome and right-pane header.
struct TitleBarIcon: View {
    @Environment(AppModel.self) private var model
    let symbol: String
    var help: String
    var active: Bool = false
    var run: () -> Void

    init(symbol: String, help: String, active: Bool = false, run: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.active = active
        self.run = run
    }

    var body: some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: VGTheme.titleBarIconFont))
                .foregroundStyle(active ? VGTheme.textAccent : VGTheme.textMuted(dark: model.dark))
                .frame(width: VGTheme.titleBarIconSize, height: VGTheme.titleBarIconSize)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? VGTheme.accent.opacity(0.18) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Note tabs that sit in the main-column title bar.
struct TitleBarTabStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.tabs) { tab in
                        let active = tab.id == model.activeTabID && model.centerView == .editor
                        HStack(spacing: 6) {
                            Button {
                                model.setActiveTab(tab.id)
                            } label: {
                                Text((tab.dirty ? "• " : "") + tab.title)
                                    .lineLimit(1)
                                    .font(.system(size: 13))
                                    .foregroundStyle(
                                        active ? VGTheme.textNormal(dark: model.dark) : VGTheme.textMuted(dark: model.dark)
                                    )
                            }
                            .buttonStyle(.plain)
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
                        .background(active ? VGTheme.backgroundPrimary(dark: model.dark) : Color.clear)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(active ? VGTheme.accent : Color.clear)
                                .frame(height: 2)
                        }
                        .overlay(alignment: .trailing) {
                            VGTheme.divider(dark: model.dark).frame(width: 1)
                        }
                    }
                }
            }
            Button {
                Task { await model.newNote() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: VGTheme.titleBarIconFont))
                    .frame(width: VGTheme.titleBarIconSize, height: VGTheme.titleBarHeight)
                    .foregroundStyle(VGTheme.textMuted(dark: model.dark))
            }
            .buttonStyle(.plain)
            .help("New note")
        }
    }
}

/// Full-height drag handle between the left sidebar and the editor.
struct SplitHandle: View {
    var dark: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void

    var body: some View {
        ZStack {
            VGTheme.divider(dark: dark).frame(width: 1)
            Color.clear
                .frame(width: VGTheme.splitHandleWidth)
                .contentShape(Rectangle())
        }
        .frame(width: VGTheme.splitHandleWidth)
        .onHover { inside in
            if inside {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { onChanged($0.translation.width) }
                .onEnded { _ in onEnded() }
        )
    }
}

/// Lets empty title-bar space drag the window, without eating clicks on buttons.
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Puts SwiftUI content in the same row as the macOS traffic lights.
final class WindowChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { WindowChromeConfigurator.apply(to: window) }
    }
}

struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowChromeView {
        WindowChromeView()
    }

    func updateNSView(_ nsView: WindowChromeView, context: Context) {
        if let window = nsView.window { Self.apply(to: window) }
    }

    static func apply(to window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
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
