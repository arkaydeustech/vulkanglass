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

    /// Vertical nudges so symbols with extra ink below their box (the pencil's square ends 1pt
    /// lower than sidebar.right's) share a baseline with their title bar neighbours.
    static let opticalOffsets: [String: CGFloat] = ["square.and.pencil": -1]

    var body: some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: VGTheme.titleBarIconFont))
                .offset(y: Self.opticalOffsets[symbol] ?? 0)
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

/// Hairline pane boundary that glows teal on hover, matching Obsidian's split. A horizontal
/// axis divides side-by-side panes with a vertical line; a vertical axis divides stacked panes.
struct SplitHandle: View {
    var dark: Bool
    var resizable: Bool = false
    var axis: SplitAxis = .horizontal
    var onChanged: (CGFloat) -> Void = { _ in }
    var onEnded: () -> Void = {}

    @State private var hovering = false
    @State private var dragging = false

    private var glowing: Bool { hovering || dragging }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(VGTheme.accent)
                .frame(width: across(4), height: along(4))
                .blur(radius: 7)
                .opacity(glowing ? 0.7 : 0)
                .animation(.easeInOut(duration: VGTheme.splitGlowDuration), value: glowing)
            Rectangle()
                .fill(VGTheme.textAccent)
                .frame(width: across(VGTheme.splitLineWidth), height: along(VGTheme.splitLineWidth))
                .shadow(color: VGTheme.accent.opacity(glowing ? 1 : 0), radius: 5)
                .opacity(glowing ? 1 : 0)
                .animation(.easeInOut(duration: VGTheme.splitGlowDuration), value: glowing)
            Rectangle()
                .fill(glowing ? VGTheme.textAccent : VGTheme.divider(dark: dark))
                .frame(width: across(VGTheme.splitLineWidth), height: along(VGTheme.splitLineWidth))
                .animation(.easeInOut(duration: VGTheme.splitGlowDuration), value: glowing)
        }
        .frame(width: across(VGTheme.splitLineWidth), height: along(VGTheme.splitLineWidth))
        .frame(
            maxWidth: axis == .vertical ? .infinity : nil,
            maxHeight: axis == .horizontal ? .infinity : nil
        )
        .overlay {
            Rectangle()
                .fill(.white.opacity(0.001))
                .frame(width: across(VGTheme.splitHandleWidth), height: along(VGTheme.splitHandleWidth))
                .contentShape(Rectangle())
                .onHover { inside in
                    hovering = inside
                    updateCursor()
                }
                .highPriorityGesture(dragGesture, including: resizable ? .all : .none)
        }
        .zIndex(1)
    }

    /// Thickness for a vertical line; nil lets a horizontal line stretch.
    private func across(_ thickness: CGFloat) -> CGFloat? {
        axis == .horizontal ? thickness : nil
    }

    /// Thickness for a horizontal line; nil lets a vertical line stretch.
    private func along(_ thickness: CGFloat) -> CGFloat? {
        axis == .vertical ? thickness : nil
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                guard resizable else { return }
                dragging = true
                updateCursor()
                onChanged(Self.translation(value.translation, for: axis))
            }
            .onEnded { _ in
                guard resizable else { return }
                dragging = false
                updateCursor()
                onEnded()
            }
    }

    static func translation(_ size: CGSize, for axis: SplitAxis) -> CGFloat {
        axis == .horizontal ? size.width : size.height
    }

    private func updateCursor() {
        guard resizable else { return }
        if hovering || dragging {
            (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        } else {
            NSCursor.arrow.set()
        }
    }
}

/// Lets empty title-bar space drag the window, without eating clicks on buttons. A double-click
/// on it follows the system title-bar action (see `TitleBarDoubleClick`).
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragRegionView {
        let view = WindowDragRegionView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: WindowDragRegionView, context: Context) {}
}

/// Marks title-bar space with nothing on it, so a double-click there can be told apart from
/// one on a tab or button.
final class WindowDragRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// What a double-click on empty title-bar space does, following the "Double-click a window's
/// title bar to" setting in System Settings › Desktop & Dock.
enum TitleBarDoubleClickAction: Equatable {
    case zoom
    case fill
    case minimize
    case none

    /// `preference` is the global `AppleActionOnDoubleClick` value: "Maximize" (Zoom), "Fill",
    /// "Minimize", or "None". Unset falls back to the older `AppleMiniaturizeOnDoubleClick` switch.
    init(preference: String?, legacyMinimize: Bool = false) {
        switch preference?.lowercased() {
        case "fill": self = .fill
        case "minimize": self = .minimize
        case "none": self = .none
        case nil: self = legacyMinimize ? .minimize : .zoom
        default: self = .zoom
        }
    }

    static func current(defaults: UserDefaults = .standard) -> Self {
        Self(
            preference: defaults.string(forKey: "AppleActionOnDoubleClick"),
            legacyMinimize: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick")
        )
    }
}

/// The window draws its own title bar over a hidden system one, so AppKit no longer zooms the
/// window when that bar is double-clicked. This restores it for space holding no tab or button.
@MainActor
enum TitleBarDoubleClick {
    /// Weak keys keep a filled window's restore frame only for that window's lifetime.
    private static let fillRestoreFrames = NSMapTable<NSWindow, NSValue>.weakToStrongObjects()

    /// Performs the double-click action when `event` is a double-click on empty title-bar space
    /// in `window`, returning whether it did.
    static func handle(
        _ event: NSEvent,
        in window: NSWindow,
        action: TitleBarDoubleClickAction = .current()
    ) -> Bool {
        guard event.type == .leftMouseDown,
              event.clickCount == 2,
              event.window === window,
              isEmptyTitleBarSpace(at: event.locationInWindow, in: window)
        else { return false }
        perform(action, on: window)
        return true
    }

    /// Whether `point`, in window coordinates, lands on a `WindowDragRegion` rather than on a
    /// tab, a button, or the traffic lights drawn above it.
    static func isEmptyTitleBarSpace(at point: NSPoint, in window: NSWindow) -> Bool {
        guard let root = window.contentView?.superview ?? window.contentView else { return false }
        return root.hitTest(point) is WindowDragRegionView
    }

    static func perform(_ action: TitleBarDoubleClickAction, on window: NSWindow) {
        switch action {
        case .zoom: window.zoom(nil)
        case .fill:
            guard let visibleFrame = window.screen?.visibleFrame else { return }
            if let restoreFrame = fillRestoreFrames.object(forKey: window)?.rectValue,
               window.frame == visibleFrame
            {
                fillRestoreFrames.removeObject(forKey: window)
                window.setFrame(restoreFrame, display: true, animate: false)
            } else {
                fillRestoreFrames.setObject(NSValue(rect: window.frame), forKey: window)
                window.setFrame(visibleFrame, display: true, animate: false)
            }
        case .minimize: window.miniaturize(nil)
        case .none: break
        }
    }
}

/// Puts SwiftUI content in the same row as the macOS traffic lights.
final class WindowChromeView: NSView {
    private var doubleClickMonitor: Any?
    var doubleClickAction: () -> TitleBarDoubleClickAction = { .current() }
    var isMonitoringDoubleClicks: Bool { doubleClickMonitor != nil }

    func stopMonitoring() {
        if let doubleClickMonitor { NSEvent.removeMonitor(doubleClickMonitor) }
        doubleClickMonitor = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        stopMonitoring()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard let window else { return }
        WindowChromeConfigurator.apply(to: window)
        DispatchQueue.main.async {
            WindowChromeConfigurator.centerTrafficLights(in: window)
        }
        // A local monitor sees the press before AppKit starts a window drag from the title bar,
        // which would otherwise swallow it.
        doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window,
                      TitleBarDoubleClick.handle(event, in: window, action: self.doubleClickAction())
                else { return event }
                return nil
            }
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

    static func dismantleNSView(_ nsView: WindowChromeView, coordinator: ()) {
        nsView.stopMonitoring()
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
            if let tab = model.activeTab, tab.dirty, !tab.savesAutomatically {
                Text("Unsaved — ⌘S to save")
                    .foregroundStyle(VGTheme.textNormal(dark: model.dark))
            }
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
