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
            .frame(minWidth: 0)
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

/// Hairline pane boundary that glows teal on hover, matching Obsidian's split.
struct SplitHandle: View {
    var dark: Bool
    var resizable: Bool = false
    var onChanged: (CGFloat) -> Void = { _ in }
    var onEnded: () -> Void = {}

    @State private var hovering = false
    @State private var dragging = false

    private var glowing: Bool { hovering || dragging }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(VGTheme.accent)
                .frame(width: 4)
                .blur(radius: 7)
                .opacity(glowing ? 0.7 : 0)
                .animation(.easeInOut(duration: VGTheme.splitGlowDuration), value: glowing)
            Rectangle()
                .fill(VGTheme.textAccent)
                .frame(width: VGTheme.splitLineWidth)
                .shadow(color: VGTheme.accent.opacity(glowing ? 1 : 0), radius: 5)
                .opacity(glowing ? 1 : 0)
                .animation(.easeInOut(duration: VGTheme.splitGlowDuration), value: glowing)
            Rectangle()
                .fill(glowing ? VGTheme.textAccent : VGTheme.divider(dark: dark))
                .frame(width: VGTheme.splitLineWidth)
                .animation(.easeInOut(duration: VGTheme.splitGlowDuration), value: glowing)
        }
        .frame(width: VGTheme.splitLineWidth)
        .frame(maxHeight: .infinity)
        .overlay {
            Rectangle()
                .fill(.white.opacity(0.001))
                .frame(width: VGTheme.splitHandleWidth)
                .contentShape(Rectangle())
                .onHover { inside in
                    hovering = inside
                    updateCursor()
                }
                .highPriorityGesture(dragGesture, including: resizable ? .all : .none)
        }
        .zIndex(1)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                guard resizable else { return }
                dragging = true
                updateCursor()
                onChanged(value.translation.width)
            }
            .onEnded { _ in
                guard resizable else { return }
                dragging = false
                updateCursor()
                onEnded()
            }
    }

    private func updateCursor() {
        guard resizable else { return }
        if hovering || dragging {
            NSCursor.resizeLeftRight.set()
        } else {
            NSCursor.arrow.set()
        }
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
        guard let window else { return }
        WindowChromeConfigurator.apply(to: window)
        DispatchQueue.main.async {
            WindowChromeConfigurator.centerTrafficLights(in: window)
        }
    }

    override func layout() {
        super.layout()
        if let window { WindowChromeConfigurator.centerTrafficLights(in: window) }
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
        centerTrafficLights(in: window)
    }

    /// Vertical origin for window buttons so they sit in the custom title bar, not the compact system bar.
    static func trafficLightY(
        buttonHeight: CGFloat,
        containerHeight: CGFloat,
        flipped: Bool
    ) -> CGFloat {
        let fromTop = max(0, (VGTheme.titleBarHeight - buttonHeight) / 2)
        let y = flipped ? fromTop : containerHeight - fromTop - buttonHeight
        return min(max(0, y), max(0, containerHeight - buttonHeight))
    }

    static func centerTrafficLights(in window: NSWindow) {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        guard let closeButton = window.standardWindowButton(.closeButton),
              let container = closeButton.superview
        else { return }

        let y = trafficLightY(
            buttonHeight: closeButton.frame.height,
            containerHeight: container.bounds.height,
            flipped: container.isFlipped
        )
        for type in types {
            guard let button = window.standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y))
        }
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
