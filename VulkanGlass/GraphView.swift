import AppKit
import SwiftUI

/// Force-directed graph with Obsidian-style pan, node drag, and zoom.
struct GraphView: View {
    @Environment(AppModel.self) private var model
    var localOnly = false
    var showCaption = true

    var body: some View {
        GeometryReader { geo in
            GraphCanvasRepresentable(
                notes: includedNotes,
                allNotes: model.notes,
                activeID: model.activeTabID,
                linkedTitles: linkedTitles,
                dark: model.dark,
                onOpen: { path in
                    Task { await model.openTab(path: path) }
                }
            )
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipped()
        .background(VGTheme.backgroundPrimary(dark: model.dark))
        .overlay(alignment: .topLeading) {
            if showCaption {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localOnly ? "Local graph" : "Graph of \(model.notes.count) notes")
                    Text("Drag to pan · Drag a node to move it · Scroll to zoom")
                        .foregroundStyle(VGTheme.textFaint(dark: model.dark))
                }
                .font(.caption)
                .foregroundStyle(VGTheme.textMuted(dark: model.dark))
                .padding(10)
                .allowsHitTesting(false)
            }
        }
    }

    private var includedNotes: [NoteMeta] {
        guard localOnly, let focus = model.activeTab else { return model.notes }
        let neighbors = Set(
            focus.content.wikiTargets
                + model.notes.filter {
                    $0.wikiLinks.contains { $0.caseInsensitiveCompare(focus.title) == .orderedSame }
                }.map { $0.title.lowercased() }
                + [focus.title.lowercased()]
        )
        return model.notes.filter { neighbors.contains($0.title.lowercased()) }
    }

    private var linkedTitles: Set<String> {
        guard let focus = model.activeTab else { return [] }
        return Set(Markdown.wikiLinks(in: focus.content).map { $0.lowercased() })
    }
}

private extension String {
    var wikiTargets: [String] {
        Markdown.wikiLinks(in: self).map { $0.lowercased() }
    }
}

struct GraphCanvasRepresentable: NSViewRepresentable {
    var notes: [NoteMeta]
    var allNotes: [NoteMeta]
    var activeID: String?
    var linkedTitles: Set<String>
    var dark: Bool
    var onOpen: (String) -> Void

    func makeNSView(context: Context) -> GraphCanvasView {
        let view = GraphCanvasView()
        view.onOpen = onOpen
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        view.setContentCompressionResistancePriority(.fittingSizeCompression, for: .vertical)
        return view
    }

    func updateNSView(_ view: GraphCanvasView, context: Context) {
        view.dark = dark
        view.activeID = activeID
        view.onOpen = onOpen
        view.apply(notes: notes, allNotes: allNotes, linkedTitles: linkedTitles)
    }
}

/// Native canvas so mouse-drag, trackpad pan, and scroll-zoom match Obsidian.
final class GraphCanvasView: NSView {
    var sim = GraphSim()
    var pan = CGPoint.zero
    var zoom: CGFloat = 1
    var dark = true
    var activeID: String?
    var onOpen: ((String) -> Void)?

    private var timer: Timer?
    private var scrollMonitor: Any?
    private var dragIndex: Int?
    private var draggingCanvas = false
    private var dragMoved = false
    private var lastMouse = CGPoint.zero
    private var lastGraphSignature: [String] = []
    private var didFrameCamera = false
    private var framedSize: CGSize = .zero
    private var userMovedCamera = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureCanvas()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureCanvas()
    }

    private func configureCanvas() {
        wantsLayer = true
        clipsToBounds = true
        setupTimer()
        setupTracking()
    }

    deinit {
        timer?.invalidate()
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
    }

    override var intrinsicContentSize: NSSize { .zero }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        installScrollMonitor()
    }

    /// Reloads nodes when the vault set changes, keeping camera if the IDs are unchanged.
    func apply(notes: [NoteMeta], allNotes: [NoteMeta], linkedTitles: Set<String>) {
        let signature = notes.map { $0.path + "\u{1f}" + $0.wikiLinks.joined(separator: "\u{1e}") }
        if signature != lastGraphSignature {
            sim.rebuild(notes: notes, allNotes: allNotes, linkedTitles: linkedTitles)
            lastGraphSignature = signature
            didFrameCamera = false
            userMovedCamera = false
            framedSize = .zero
            startSimulation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, !self.userMovedCamera else { return }
                self.didFrameCamera = false
                self.frameCameraIfNeeded()
                self.needsDisplay = true
            }
        } else {
            for i in sim.nodes.indices {
                sim.nodes[i].linked = linkedTitles.contains(sim.nodes[i].title.lowercased())
            }
        }
        frameCameraIfNeeded()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        frameCameraIfNeeded()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        (dark ? NSColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1) : NSColor.white).setFill()
        dirtyRect.fill()

        ctx.saveGState()
        ctx.translateBy(x: pan.x, y: pan.y)
        ctx.scaleBy(x: zoom, y: zoom)

        let map = Dictionary(uniqueKeysWithValues: sim.nodes.map { ($0.id, $0) })
        let line = dark ? NSColor(white: 0.28, alpha: 1) : NSColor(white: 0.75, alpha: 1)
        ctx.setStrokeColor(line.cgColor)
        ctx.setLineWidth(1 / zoom)
        for edge in sim.edges {
            guard let a = map[edge.source], let b = map[edge.target] else { continue }
            ctx.beginPath()
            ctx.move(to: CGPoint(x: a.x, y: a.y))
            ctx.addLine(to: CGPoint(x: b.x, y: b.y))
            ctx.strokePath()
        }

        let labelColor = dark ? NSColor(white: 0.65, alpha: 1) : NSColor(white: 0.35, alpha: 1)
        let font = NSFont.systemFont(ofSize: CGFloat(min(14, max(9, 11 / zoom))))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: labelColor
        ]

        for node in sim.nodes {
            let active = node.id == activeID
            let radius: CGFloat = active ? 8 : (node.linked ? 6 : 4.5)
            let color: NSColor
            if active {
                color = NSColor(red: 0.08, green: 0.72, blue: 0.65, alpha: 1)
            } else if node.linked {
                color = NSColor(red: 0.27, green: 0.81, blue: 0.43, alpha: 1)
            } else {
                color = dark ? NSColor(white: 0.72, alpha: 1) : NSColor(white: 0.35, alpha: 1)
            }
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: node.x - radius, y: node.y - radius, width: radius * 2, height: radius * 2))
            if node.pinned {
                ctx.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
                ctx.setLineWidth(1.5 / zoom)
                ctx.strokeEllipse(in: CGRect(
                    x: node.x - radius - 3,
                    y: node.y - radius - 3,
                    width: (radius + 3) * 2,
                    height: (radius + 3) * 2
                ))
            }
            (node.title as NSString).draw(
                at: CGPoint(x: node.x + radius + 4, y: node.y - 7),
                withAttributes: attrs
            )
        }
        ctx.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let loc = convert(event.locationInWindow, from: nil)
        lastMouse = loc
        dragMoved = false
        if let index = hitNode(at: loc) {
            dragIndex = index
            sim.nodes[index].pinned = true
            sim.nodes[index].vx = 0
            sim.nodes[index].vy = 0
            NSCursor.closedHand.push()
            startSimulation()
        } else {
            dragIndex = nil
            draggingCanvas = true
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let dx = loc.x - lastMouse.x
        let dy = loc.y - lastMouse.y
        if hypot(dx, dy) > 2 { dragMoved = true }
        if let index = dragIndex {
            let world = worldPoint(loc)
            sim.nodes[index].x = Double(world.x)
            sim.nodes[index].y = Double(world.y)
            sim.nodes[index].vx = 0
            sim.nodes[index].vy = 0
        } else if draggingCanvas {
            pan.x += dx
            pan.y += dy
            userMovedCamera = true
        }
        lastMouse = loc
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        if let index = dragIndex {
            if !dragMoved {
                sim.nodes[index].pinned = false
                onOpen?(sim.nodes[index].id)
            }
            // Dragged nodes stay pinned so they remain where you dropped them, like Obsidian.
        }
        dragIndex = nil
        draggingCanvas = false
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func scrollWheel(with event: NSEvent) {
        handleScroll(event)
    }

    override func magnify(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        zoom(by: 1 + event.magnification, around: loc)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if hitNode(at: loc) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        setupTracking()
    }

    private func setupTracking() {
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                owner: self
            )
        )
    }

    private func setupTimer() {
        startSimulation()
    }

    private func startSimulation() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.sim.tick() else {
                self.timer?.invalidate()
                self.timer = nil
                return
            }
            self.needsDisplay = true
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// SwiftUI often swallows `scrollWheel` on representable views; intercept at the window.
    private func installScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        guard window != nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window == window else { return event }
            let loc = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(loc) else { return event }
            self.handleScroll(event)
            return nil
        }
    }

    private func handleScroll(_ event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.shift) {
            pan.x += event.scrollingDeltaX
            pan.y += event.scrollingDeltaY
            userMovedCamera = true
            needsDisplay = true
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.008 : event.scrollingDeltaY * 0.08
        zoom(by: 1 + delta, around: loc)
    }

    private func worldPoint(_ screen: CGPoint) -> CGPoint {
        CGPoint(x: (screen.x - pan.x) / zoom, y: (screen.y - pan.y) / zoom)
    }

    private func hitNode(at screen: CGPoint) -> Int? {
        for (index, node) in sim.nodes.enumerated().reversed() {
            let sx = node.x * zoom + pan.x
            let sy = node.y * zoom + pan.y
            if hypot(sx - screen.x, sy - screen.y) < 16 {
                return index
            }
        }
        return nil
    }

    private func zoom(by factor: CGFloat, around screen: CGPoint) {
        let world = worldPoint(screen)
        let next = min(max(zoom * factor, 0.15), 8)
        zoom = next
        pan.x = screen.x - world.x * zoom
        pan.y = screen.y - world.y * zoom
        userMovedCamera = true
        needsDisplay = true
    }

    private func frameCameraIfNeeded() {
        guard !userMovedCamera, !sim.nodes.isEmpty, bounds.width > 10, bounds.height > 10 else { return }
        let sizeChanged = abs(framedSize.width - bounds.width) > 8 || abs(framedSize.height - bounds.height) > 8
        guard !didFrameCamera || sizeChanged else { return }
        let xs = sim.nodes.map(\.x)
        let ys = sim.nodes.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
        let worldW = CGFloat(max(maxX - minX, 40)) + 96
        let worldH = CGFloat(max(maxY - minY, 40)) + 80
        let fit = min(bounds.width / worldW, bounds.height / worldH)
        zoom = min(max(fit, 0.35), 1.8)
        let cx = CGFloat((minX + maxX) / 2)
        let cy = CGFloat((minY + maxY) / 2)
        pan = CGPoint(x: bounds.midX - cx * zoom, y: bounds.midY - cy * zoom)
        framedSize = bounds.size
        didFrameCamera = true
    }
}

final class GraphSim {
    var nodes: [SimNode] = []
    var edges: [SimEdge] = []

    func rebuild(notes: [NoteMeta], allNotes: [NoteMeta], linkedTitles: Set<String>) {
        let byPath = Dictionary(
            allNotes.map { (normalized($0.relativePath), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let byTitle = Dictionary(grouping: allNotes, by: { $0.title.lowercased() })
        nodes = notes.enumerated().map { index, note in
            SimNode(
                id: note.path,
                title: note.title,
                linked: linkedTitles.contains(note.title.lowercased()),
                x: cos(Double(index) * 1.7) * 120,
                y: sin(Double(index) * 1.7) * 120,
                vx: 0,
                vy: 0,
                pinned: false
            )
        }
        let ids = Set(notes.map(\.path))
        var next: [SimEdge] = []
        for note in notes {
            for link in note.wikiLinks {
                let normalizedLink = normalized(link)
                let target = byPath[normalizedLink]
                    ?? byTitle[normalizedLink]?.sorted {
                        $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
                    }.first
                if let target, ids.contains(target.path) {
                    next.append(SimEdge(source: note.path, target: target.path))
                }
            }
        }
        edges = next
    }

    @discardableResult
    func tick() -> Bool {
        guard nodes.count > 1 else { return false }
        let cellSize = 180.0
        let cutoff = 260.0
        var grid: [Cell: [Int]] = [:]
        for index in nodes.indices {
            let cell = Cell(x: Int(floor(nodes[index].x / cellSize)), y: Int(floor(nodes[index].y / cellSize)))
            grid[cell, default: []].append(index)
        }
        for i in nodes.indices {
            let cell = Cell(x: Int(floor(nodes[i].x / cellSize)), y: Int(floor(nodes[i].y / cellSize)))
            for x in (cell.x - 1)...(cell.x + 1) {
                for y in (cell.y - 1)...(cell.y + 1) {
                    for j in grid[Cell(x: x, y: y)] ?? [] where j > i {
                let dx = nodes[i].x - nodes[j].x
                let dy = nodes[i].y - nodes[j].y
                let dist = max(hypot(dx, dy), 0.01)
                guard dist < cutoff else { continue }
                let force = 800 / (dist * dist)
                nodes[i].vx += (dx / dist) * force
                nodes[i].vy += (dy / dist) * force
                nodes[j].vx -= (dx / dist) * force
                nodes[j].vy -= (dy / dist) * force
                    }
                }
            }
        }
        let map = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        for edge in edges {
            guard let ai = map[edge.source], let bi = map[edge.target] else { continue }
            let dx = nodes[bi].x - nodes[ai].x
            let dy = nodes[bi].y - nodes[ai].y
            nodes[ai].vx += dx * 0.012
            nodes[ai].vy += dy * 0.012
            nodes[bi].vx -= dx * 0.012
            nodes[bi].vy -= dy * 0.012
        }
        let cx = nodes.map(\.x).reduce(0, +) / Double(nodes.count)
        let cy = nodes.map(\.y).reduce(0, +) / Double(nodes.count)
        var kineticEnergy = 0.0
        for i in nodes.indices {
            if nodes[i].pinned {
                nodes[i].vx = 0
                nodes[i].vy = 0
                continue
            }
            nodes[i].vx += (cx - nodes[i].x) * 0.003
            nodes[i].vy += (cy - nodes[i].y) * 0.003
            nodes[i].vx *= 0.82
            nodes[i].vy *= 0.82
            nodes[i].x += nodes[i].vx
            nodes[i].y += nodes[i].vy
            kineticEnergy += nodes[i].vx * nodes[i].vx + nodes[i].vy * nodes[i].vy
        }
        return kineticEnergy / Double(nodes.count) > 0.002
    }

    private func normalized(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".md") { value.removeLast(3) }
        return value
    }

    private struct Cell: Hashable {
        var x: Int
        var y: Int
    }
}

struct SimNode: Identifiable, Equatable {
    var id: String
    var title: String
    var linked: Bool
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var pinned: Bool
}

struct SimEdge: Equatable {
    var source: String
    var target: String
}
