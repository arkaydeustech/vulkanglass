import AppKit
import SwiftUI

/// Native NSTextView source editor with `[[` wiki-link completion.
struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    var notes: [NoteMeta]
    var dark: Bool
    var baseURL: URL?
    var loadRemoteImages = false

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: { text = $0 })
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = SourceTextView()
        textView.delegate = context.coordinator
        textView.wikiHandler = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.font = .systemFont(ofSize: 16)
        textView.textContainerInset = NSSize(width: 40, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.drawsBackground = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.notes = notes
        context.coordinator.dark = dark
        context.coordinator.baseURL = baseURL
        context.coordinator.loadRemoteImages = loadRemoteImages
        textView.onGeometryChange = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleRestyle()
        }
        applyChrome(textView)
        context.coordinator.restyle()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onChange = { text = $0 }
        context.coordinator.notes = notes
        let darkChanged = context.coordinator.dark != dark
        context.coordinator.dark = dark
        context.coordinator.baseURL = baseURL
        context.coordinator.loadRemoteImages = loadRemoteImages
        guard let textView = nsView.documentView as? SourceTextView else { return }
        textView.configureImages(baseURL: baseURL, loadRemoteImages: loadRemoteImages)
        if textView.string != text {
            textView.string = text
            context.coordinator.restyle()
        } else if darkChanged {
            context.coordinator.restyle()
        }
        applyChrome(textView)
        context.coordinator.refreshWikiPopup()
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelPendingRestyle()
        coordinator.dismissPopup()
        if let textView = nsView.documentView as? SourceTextView {
            textView.delegate = nil
            textView.wikiHandler = nil
            textView.onGeometryChange = nil
        }
        coordinator.textView = nil
    }

    private func applyChrome(_ textView: NSTextView) {
        textView.insertionPointColor = NSColor(red: 0.08, green: 0.72, blue: 0.65, alpha: 1)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(red: 0.08, green: 0.72, blue: 0.65, alpha: 0.28)
        ]
    }

    final class Coordinator: NSObject, NSTextViewDelegate, WikiLinkKeyHandling {
        var onChange: (String) -> Void
        weak var textView: SourceTextView?
        var notes: [NoteMeta] = []
        var dark = true
        var baseURL: URL?
        var loadRemoteImages = false
        private var cachedText: String?
        private var cachedTokens: [LivePreview.Token] = []
        private let popup = WikiLinkPopupController()
        private var session: WikiLinkSession?
        private var suggestions: [NoteMeta] = []
        private var selected = 0
        private var dismissedMarker: Int?
        private var restyling = false
        private var pendingRestyle: DispatchWorkItem?

        var isPopupVisible: Bool { popup.isVisible }
        var selectedSuggestionIndex: Int { selected }

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
            super.init()
            popup.onChoose = { [weak self] note in
                self?.insert(note)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !restyling, let tv = notification.object as? NSTextView else { return }
            onChange(tv.string)
            scheduleRestyle()
            refreshWikiPopup()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !restyling else { return }
            scheduleRestyle()
            refreshWikiPopup()
        }

        func scheduleRestyle() {
            pendingRestyle?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.restyle() }
            pendingRestyle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work)
        }

        func cancelPendingRestyle() {
            pendingRestyle?.cancel()
            pendingRestyle = nil
        }

        func restyle() {
            guard !restyling, let textView, let storage = textView.textStorage else { return }
            pendingRestyle?.cancel()
            pendingRestyle = nil
            restyling = true
            let undo = textView.undoManager
            undo?.disableUndoRegistration()
            defer {
                undo?.enableUndoRegistration()
                restyling = false
            }
            let selection = textView.selectedRange()
            let text = storage.string
            if cachedText != text {
                cachedText = text
                cachedTokens = LivePreview.tokens(in: text)
            }
            textView.liveDecorations = LivePreview.apply(
                to: storage,
                caret: selection.location,
                selection: selection,
                dark: dark,
                maximumTableWidth: textView.maximumTableWidth,
                tokens: cachedTokens
            )
            textView.configureImages(baseURL: baseURL, loadRemoteImages: loadRemoteImages)
            textView.preloadImages()
            textView.setSelectedRange(selection)
            textView.typingAttributes = LivePreview.typingAttributes(
                at: selection.location,
                tokens: cachedTokens,
                dark: dark
            )
        }

        func refreshWikiPopup() {
            guard let textView else {
                popup.dismiss()
                return
            }
            let next = WikiLinkSuggest.session(in: textView.string, utf16Cursor: textView.selectedRange().location)
            guard let next, next.allowsNoteSuggestions, !notes.isEmpty else {
                session = nil
                dismissedMarker = nil
                popup.dismiss()
                return
            }
            if next.query != session?.query {
                selected = 0
                dismissedMarker = nil
            }
            if dismissedMarker == next.markerRange.location {
                session = next
                popup.dismiss()
                return
            }
            suggestions = WikiLinkSuggest.suggestions(from: notes, query: next.query)
            session = next
            if selected >= suggestions.count { selected = max(0, suggestions.count - 1) }
            let caret = textView.firstRect(
                forCharacterRange: NSRange(location: next.markerRange.location, length: 2),
                actualRange: nil
            )
            popup.show(notes: suggestions, selected: selected, caret: caret, dark: dark)
        }

        func handleCommand(_ selector: Selector) -> Bool {
            guard popup.isVisible else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                moveSelection(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                moveSelection(-1)
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                confirmSelection()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                dismissedMarker = session?.markerRange.location
                popup.dismiss()
                return true
            default:
                return false
            }
        }

        func dismissPopup() {
            session = nil
            suggestions = []
            dismissedMarker = nil
            popup.dismiss()
        }

        func dismissWikiPopup() {
            dismissPopup()
        }

        private func moveSelection(_ delta: Int) {
            guard !suggestions.isEmpty else { return }
            selected = min(max(selected + delta, 0), suggestions.count - 1)
            popup.updateSelection(selected)
        }

        private func confirmSelection() {
            if suggestions.indices.contains(selected) {
                insert(suggestions[selected])
            } else if let session, !session.query.isEmpty {
                insert(raw: session.query)
            } else {
                popup.dismiss()
            }
        }

        private func insert(_ note: NoteMeta) {
            insert(raw: WikiLinkSuggest.insertTarget(for: note, among: notes))
        }

        private func insert(raw target: String) {
            guard let textView, let session else { return }
            let replacement = WikiLinkSuggest.replacement(target: target, in: session)
            let range = session.queryRange
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
                let end = range.location + (replacement as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
            }
            popup.dismiss()
        }
    }
}

/// Forwards movement keys to wiki-link completion while the popup is open.
final class SourceTextView: NSTextView {
    private static let legacyStringPasteboardType = NSPasteboard.PasteboardType("NSStringPboardType")
    private static let maximumRichPasteboardBytes = 2 * 1_024 * 1_024
    private static let richPasteboardTypes: [(NSPasteboard.PasteboardType, NSAttributedString.DocumentType)] = [
        (.html, .html),
        (.rtf, .rtf),
        (.rtfd, .rtfd),
    ]
    static let tableControlThickness: CGFloat = 28

    weak var wikiHandler: WikiLinkKeyHandling?
    private(set) var baseURL: URL?
    private(set) var loadRemoteImages = false
    var liveDecorations = LivePreview.Decorations() {
        didSet {
            invalidateTableLayoutCache()
            if let range = controlledTableRange {
                if let updated = liveDecorations.tables.first(where: { $0.range.location == range.location }) {
                    controlledTableRange = updated.range
                } else {
                    hideTableControls()
                }
            }
            needsDisplay = true
        }
    }
    private var imageCache: [URL: NSImage] = [:]
    private var loadingImages: Set<URL> = []
    private var failedImages: [URL: Date] = [:]
    private var imageGeneration = 0
    private(set) var imageLoadAttempts: [URL: Int] = [:]
    var imageLoadHandler: ((URL, Bool) -> Void)?
    var onGeometryChange: (() -> Void)?
    private var tableTrackingArea: NSTrackingArea?
    private var controlledTableRange: NSRange?
    private var cachedTableLayoutKey: TableLayoutCacheKey?
    private var cachedTableLayouts: [TableLayout] = []
    private(set) var tableLayoutComputationCount = 0
    private lazy var addColumnButton = makeTableControl(
        help: "Add column to the right",
        action: #selector(addTableColumn(_:))
    )
    private lazy var addRowButton = makeTableControl(
        help: "Add row below",
        action: #selector(addTableRow(_:))
    )

    var cachedImageURLs: Set<URL> { Set(imageCache.keys) }

    var maximumTableWidth: CGFloat {
        max(1, bounds.width - (textContainerInset.width * 2) - Self.tableControlThickness - 8)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        guard widthChanged else { return }
        invalidateTableLayoutCache()
        onGeometryChange?()
    }

    func configureImages(baseURL: URL?, loadRemoteImages: Bool) {
        let normalizedBase = baseURL?.standardizedFileURL
        guard self.baseURL != normalizedBase || self.loadRemoteImages != loadRemoteImages else { return }
        self.baseURL = normalizedBase
        self.loadRemoteImages = loadRemoteImages
        imageGeneration &+= 1
        imageCache.removeAll()
        loadingImages.removeAll()
        failedImages.removeAll()
        imageLoadAttempts.removeAll()
        needsDisplay = true
    }

    override func doCommand(by selector: Selector) {
        if wikiHandler?.handleCommand(selector) == true { return }
        super.doCommand(by: selector)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tableTrackingArea { removeTrackingArea(tableTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tableTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateTableControls(at: convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hideTableControls()
        super.mouseExited(with: event)
    }

    override func characterIndexForInsertion(at point: NSPoint) -> Int {
        let proposed = super.characterIndexForInsertion(at: point)
        guard let hit = tableCell(at: point) else { return proposed }
        return min(max(proposed, hit.range.location), NSMaxRange(hit.range))
    }

    override func draw(_ dirtyRect: NSRect) {
        drawLiveChrome(in: dirtyRect)
        super.draw(dirtyRect)
        drawLiveOverlays(in: dirtyRect)
    }

    override func paste(_ sender: Any?) {
        pasteMarkdown(from: .general)
    }

    /// Converts rich clipboard content to Markdown, with plain Markdown text as a fallback,
    /// and inserts it through the normal text-system change hooks.
    @discardableResult
    func pasteMarkdown(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable, let pastedText = markdownText(from: pasteboard) else { return false }
        let replacementRange = selectedRange()
        guard shouldChangeText(in: replacementRange, replacementString: pastedText) else { return false }

        replaceCharacters(in: replacementRange, with: pastedText)
        didChangeText()
        let insertionPoint = replacementRange.location + (pastedText as NSString).length
        setSelectedRange(NSRange(location: insertionPoint, length: 0))
        return true
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let plain = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        super.insertText(plain, replacementRange: replacementRange)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        Self.richPasteboardTypes.map(\.0) + [.string, Self.legacyStringPasteboardType]
    }

    override func readSelection(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> Bool {
        if Self.richPasteboardTypes.contains(where: { $0.0 == type }) {
            return pasteMarkdown(from: pasteboard)
        }
        return super.readSelection(from: pasteboard, type: type)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            return isEditable && NSPasteboard.general.availableType(from: readablePasteboardTypes) != nil
        }
        if item.action == #selector(addTableColumn(_:)) || item.action == #selector(addTableRow(_:)) {
            return isEditable && tableRangeContainingSelection() != nil
        }
        return super.validateUserInterfaceItem(item)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let range = selectedRange()
        guard range.location != NSNotFound else { return false }
        pboard.declareTypes([.string], owner: nil)
        pboard.setString((string as NSString).substring(with: range), forType: .string)
        return true
    }

    private func markdownText(from pasteboard: NSPasteboard) -> String? {
        for (pasteboardType, documentType) in Self.richPasteboardTypes {
            if let data = pasteboard.data(forType: pasteboardType) {
                guard data.count <= Self.maximumRichPasteboardBytes else { break }
                guard let markdown = RichTextMarkdownConverter.markdown(
                    from: data,
                    documentType: documentType
                ) else { continue }
                if let plain = plainText(from: pasteboard) {
                    return markdownPreservingBoundaryWhitespace(markdown, from: plain)
                }
                return markdown
            }
        }
        return plainText(from: pasteboard)
    }

    private func plainText(from pasteboard: NSPasteboard) -> String? {
        for type in [NSPasteboard.PasteboardType.string, Self.legacyStringPasteboardType] {
            if let text = pasteboard.string(forType: type) { return text }
        }
        return nil
    }

    private func markdownPreservingBoundaryWhitespace(_ markdown: String, from plainText: String) -> String {
        guard let firstContent = plainText.firstIndex(where: { !$0.isWhitespace }),
              let lastContent = plainText.lastIndex(where: { !$0.isWhitespace }) else {
            return markdown
        }
        let leading = plainText[..<firstContent]
        let trailing = plainText[plainText.index(after: lastContent)...]
        let body = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(leading) + body + String(trailing)
    }

    override func changeFont(_ sender: Any?) {}

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { wikiHandler?.dismissWikiPopup() }
        return resigned
    }

    func preloadImages() {
        for decoration in liveDecorations.images {
            _ = image(for: decoration.url)
        }
    }

    private func drawLiveChrome(in dirtyRect: NSRect) {
        guard let layoutManager, let textContainer else { return }
        for decoration in liveDecorations.codeBlocks {
            guard let rect = blockRect(for: decoration.range, layoutManager: layoutManager, textContainer: textContainer),
                  rect.intersects(dirtyRect) else { continue }
            let fill = decoration.dark
                ? NSColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1)
                : NSColor(red: 0.94, green: 0.94, blue: 0.95, alpha: 1)
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }
        for decoration in liveDecorations.tables {
            guard let table = tableLayout(for: decoration, layoutManager: layoutManager, textContainer: textContainer),
                  table.rect.intersects(dirtyRect) else { continue }
            let rect = table.rect
            let fill = decoration.dark
                ? NSColor(white: 1, alpha: 0.018)
                : NSColor(white: 0, alpha: 0.018)
            fill.setFill()
            let path = NSBezierPath(rect: rect)
            path.fill()
            let stroke = decoration.dark
                ? NSColor(white: 1, alpha: 0.16)
                : NSColor(white: 0, alpha: 0.16)
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
            for rowRect in table.rowRects.dropFirst() {
                stroke.setStroke()
                let line = NSBezierPath()
                line.move(to: NSPoint(x: rect.minX, y: rowRect.minY))
                line.line(to: NSPoint(x: rect.maxX, y: rowRect.minY))
                line.lineWidth = 1
                line.stroke()
            }
            var x = rect.minX
            for width in table.columnWidths.dropLast() {
                x += width
                stroke.setStroke()
                let line = NSBezierPath()
                line.move(to: NSPoint(x: x, y: rect.minY))
                line.line(to: NSPoint(x: x, y: rect.maxY))
                line.lineWidth = 1
                line.stroke()
            }
        }
        for decoration in liveDecorations.bars {
            guard let rect = blockRect(for: decoration.range, layoutManager: layoutManager, textContainer: textContainer),
                  rect.intersects(dirtyRect) else { continue }
            switch decoration.kind {
            case .quote:
                NSColor(red: 0.08, green: 0.72, blue: 0.65, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height), xRadius: 1, yRadius: 1).fill()
            case .alert(let kind):
                let color = alertColor(kind, dark: decoration.dark)
                color.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: 4, height: rect.height), xRadius: 2, yRadius: 2).fill()
            case .rule:
                let stroke = decoration.dark
                    ? NSColor(white: 1, alpha: 0.18)
                    : NSColor(white: 0, alpha: 0.18)
                stroke.setStroke()
                let line = NSBezierPath()
                let y = rect.midY
                line.move(to: NSPoint(x: rect.minX + 8, y: y))
                line.line(to: NSPoint(x: rect.maxX - 8, y: y))
                line.lineWidth = 1
                line.stroke()
            }
        }
        for decoration in liveDecorations.images where decoration.collapsed {
            guard let rect = blockRect(for: decoration.range, layoutManager: layoutManager, textContainer: textContainer),
                  rect.intersects(dirtyRect) else { continue }
            let inset = rect.insetBy(dx: 12, dy: 8)
            if let image = image(for: decoration.url) {
                let fitted = fittedRect(image.size, in: inset)
                image.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                NSColor.gray.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6).fill()
            }
        }
    }

    private func drawLiveOverlays(in dirtyRect: NSRect) {
        guard let layoutManager, let textContainer else { return }
        for decoration in liveDecorations.codeBlocks where decoration.showBadge {
            let label = CodeHighlight.displayName(for: decoration.language)
            guard !label.isEmpty else { continue }
            guard let rect = blockRect(for: decoration.range, layoutManager: layoutManager, textContainer: textContainer),
                  rect.intersects(dirtyRect) else { continue }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: decoration.dark
                    ? NSColor(red: 0.52, green: 0.54, blue: 0.56, alpha: 1)
                    : NSColor(red: 0.48, green: 0.50, blue: 0.52, alpha: 1)
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: NSPoint(x: rect.maxX - 12 - size.width, y: rect.minY + 6), withAttributes: attrs)
        }
        for decoration in liveDecorations.bars {
            if case .alert(let kind) = decoration.kind, decoration.collapsed {
                guard let rect = blockRect(for: decoration.range, layoutManager: layoutManager, textContainer: textContainer),
                      rect.intersects(dirtyRect) else { continue }
                let color = alertColor(kind, dark: decoration.dark)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: color
                ]
                (kind.title as NSString).draw(at: NSPoint(x: rect.minX + 14, y: rect.minY + 6), withAttributes: attrs)
            }
        }
        for decoration in liveDecorations.emojis {
            let glyphs = layoutManager.glyphRange(forCharacterRange: decoration.range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            guard rect.intersects(dirtyRect) else { continue }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16)]
            (decoration.emoji as NSString).draw(at: rect.origin, withAttributes: attrs)
        }
    }

    private struct TableLayout {
        var decoration: LivePreview.TableDecoration
        var rect: NSRect
        var rowRects: [NSRect]
        var columnWidths: [CGFloat]
    }

    private struct TableCellHit {
        var range: NSRange
    }

    private struct TableLayoutCacheKey: Equatable {
        var decorations: [LivePreview.TableDecoration]
        var visibleRect: NSRect
        var origin: NSPoint
        var containerSize: NSSize
    }

    private func tableLayouts() -> [TableLayout] {
        guard !liveDecorations.tables.isEmpty, let layoutManager, let textContainer else { return [] }
        let key = TableLayoutCacheKey(
            decorations: liveDecorations.tables,
            visibleRect: visibleRect,
            origin: textContainerOrigin,
            containerSize: textContainer.containerSize
        )
        if key == cachedTableLayoutKey { return cachedTableLayouts }

        var containerRect = visibleRect
        containerRect.origin.x -= textContainerOrigin.x
        containerRect.origin.y -= textContainerOrigin.y
        layoutManager.ensureLayout(forBoundingRect: containerRect, in: textContainer)
        let glyphs = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let visibleTables = liveDecorations.tables.filter {
            NSIntersectionRange($0.range, characters).length > 0
        }
        let layouts = visibleTables.compactMap {
            tableLayout(for: $0, layoutManager: layoutManager, textContainer: textContainer)
        }
        tableLayoutComputationCount += 1
        cachedTableLayoutKey = key
        cachedTableLayouts = layouts
        return layouts
    }

    private func invalidateTableLayoutCache() {
        cachedTableLayoutKey = nil
        cachedTableLayouts = []
    }

    private func tableLayout(
        for decoration: LivePreview.TableDecoration,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> TableLayout? {
        let rows = decoration.rows.compactMap { row -> NSRect? in
            guard let rect = lineRect(for: row.range, layoutManager: layoutManager, textContainer: textContainer) else {
                return nil
            }
            return rect
        }
        guard let first = rows.first, let last = rows.last, !decoration.columnWidths.isEmpty else { return nil }
        let width = decoration.columnWidths.reduce(0, +)
        let rect = NSRect(
            x: textContainerOrigin.x,
            y: first.minY,
            width: width,
            height: last.maxY - first.minY
        )
        let normalizedRows = rows.map {
            NSRect(x: rect.minX, y: $0.minY, width: width, height: $0.height)
        }
        return TableLayout(
            decoration: decoration,
            rect: rect,
            rowRects: normalizedRows,
            columnWidths: decoration.columnWidths
        )
    }

    private func lineRect(
        for range: NSRange,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        guard range.length > 0 else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var result = NSRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
            result = result.union(rect)
        }
        guard !result.isNull else { return nil }
        result.origin.x += textContainerOrigin.x
        result.origin.y += textContainerOrigin.y
        return result
    }

    private func tableCell(at point: NSPoint) -> TableCellHit? {
        for table in tableLayouts() where table.rect.contains(point) {
            guard let rowIndex = table.rowRects.firstIndex(where: { $0.contains(point) }),
                  table.decoration.rows.indices.contains(rowIndex)
            else { continue }
            var boundary = table.rect.minX
            for (column, width) in table.columnWidths.enumerated() {
                boundary += width
                if point.x <= boundary,
                   table.decoration.rows[rowIndex].cellRanges.indices.contains(column) {
                    return TableCellHit(range: table.decoration.rows[rowIndex].cellRanges[column])
                }
            }
        }
        return nil
    }

    private func updateTableControls(at point: NSPoint) {
        for table in tableLayouts() {
            let reachableRight = max(table.rect.minX, visibleRect.maxX - Self.tableControlThickness)
            let reachableBottom = max(table.rect.minY, visibleRect.maxY - Self.tableControlThickness)
            let columnFrame = NSRect(
                x: min(table.rect.maxX, reachableRight),
                y: table.rect.minY,
                width: Self.tableControlThickness,
                height: table.rect.height
            )
            let rowFrame = NSRect(
                x: table.rect.minX,
                y: min(table.rect.maxY, reachableBottom),
                width: min(table.rect.width, max(0, visibleRect.maxX - table.rect.minX)),
                height: Self.tableControlThickness
            )
            if columnFrame.insetBy(dx: -6, dy: 0).contains(point) {
                showTableControl(addColumnButton, frame: columnFrame, table: table.decoration.range)
                addRowButton.isHidden = true
                return
            }
            if rowFrame.insetBy(dx: 0, dy: -6).contains(point) {
                showTableControl(addRowButton, frame: rowFrame, table: table.decoration.range)
                addColumnButton.isHidden = true
                return
            }
        }
        hideTableControls()
    }

    private func showTableControl(_ button: TableInsertButton, frame: NSRect, table: NSRange) {
        ensureTableControls()
        controlledTableRange = table
        button.frame = frame
        button.isHidden = false
    }

    private func hideTableControls() {
        if addColumnButton.superview != nil { addColumnButton.isHidden = true }
        if addRowButton.superview != nil { addRowButton.isHidden = true }
        controlledTableRange = nil
    }

    private func ensureTableControls() {
        if addColumnButton.superview == nil {
            addSubview(addColumnButton)
            addColumnButton.isHidden = true
        }
        if addRowButton.superview == nil {
            addSubview(addRowButton)
            addRowButton.isHidden = true
        }
    }

    private func makeTableControl(help: String, action: Selector) -> TableInsertButton {
        let button = TableInsertButton(frame: .zero)
        button.target = self
        button.action = action
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.setAccessibilityHelp(help)
        return button
    }

    @objc func addTableColumn(_ sender: Any?) {
        mutateTableAtCurrentTarget(using: GFM.addingTableColumn)
    }

    @objc func addTableRow(_ sender: Any?) {
        mutateTableAtCurrentTarget(using: GFM.addingTableRow)
    }

    private func tableRangeContainingSelection() -> NSRange? {
        let caret = selectedRange().location
        return liveDecorations.tables.first {
            caret >= $0.range.location && caret <= NSMaxRange($0.range)
        }?.range
    }

    private func mutateTableAtCurrentTarget(
        using mutation: (String) -> GFM.TableMutation?
    ) {
        guard let range = controlledTableRange ?? tableRangeContainingSelection(),
              NSMaxRange(range) <= (string as NSString).length,
              let result = mutation((string as NSString).substring(with: range)),
              shouldChangeText(in: range, replacementString: result.replacement)
        else { return }

        replaceCharacters(in: range, with: result.replacement)
        didChangeText()
        let caret = range.location + result.selectionOffset
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: caret, length: 0))
        scrollRangeToVisible(NSRange(location: caret, length: 0))
        hideTableControls()
    }

    private func image(for raw: String) -> NSImage? {
        guard let url = resolveURL(raw) else { return nil }
        if let cached = imageCache[url] { return cached }
        if let retryAfter = failedImages[url] {
            guard retryAfter <= Date() else { return nil }
            failedImages.removeValue(forKey: url)
        }
        guard loadingImages.insert(url).inserted else { return nil }
        let generation = imageGeneration
        if url.isFileURL {
            imageLoadAttempts[url, default: 0] += 1
            Task { [weak self] in
                let data = await Task.detached(priority: .utility) {
                    try? Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                self?.finishImageLoad(data: data, url: url, generation: generation)
            }
        } else if MarkdownResourceResolver.mayLoadImage(url, loadRemoteImages: loadRemoteImages) {
            imageLoadAttempts[url, default: 0] += 1
            Task { [weak self] in
                let data = try? await RemoteImageLoader.data(from: url)
                self?.finishImageLoad(data: data, url: url, generation: generation)
            }
        } else {
            loadingImages.remove(url)
            failedImages[url] = .distantFuture
        }
        return nil
    }

    private func finishImageLoad(data: Data?, url: URL, generation: Int) {
        guard generation == imageGeneration else { return }
        loadingImages.remove(url)
        guard let data, let image = NSImage(data: data) else {
            failedImages[url] = url.isFileURL ? .distantFuture : Date().addingTimeInterval(30)
            imageLoadHandler?(url, false)
            return
        }
        failedImages.removeValue(forKey: url)
        imageCache[url] = image
        imageLoadHandler?(url, true)
        needsDisplay = true
    }

    private func resolveURL(_ raw: String) -> URL? {
        MarkdownResourceResolver.imageURL(raw, relativeTo: baseURL)
    }

    private func fittedRect(_ size: NSSize, in bounds: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height, 1)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(
            x: bounds.minX + (bounds.width - fitted.width) / 2,
            y: bounds.minY + (bounds.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private func alertColor(_ kind: GFM.AlertKind, dark: Bool) -> NSColor {
        switch kind {
        case .note:
            return NSColor(red: 0.35, green: 0.62, blue: 0.95, alpha: 1)
        case .tip:
            return NSColor(red: 0.08, green: 0.72, blue: 0.65, alpha: 1)
        case .important:
            return NSColor(red: 0.72, green: 0.48, blue: 0.95, alpha: 1)
        case .warning:
            return NSColor(red: 0.95, green: 0.68, blue: 0.22, alpha: 1)
        case .caution:
            return NSColor(red: 0.90, green: 0.32, blue: 0.32, alpha: 1)
        }
    }

    private func blockRect(
        for range: NSRange,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        let length = (string as NSString).length
        guard length > 0 else { return nil }
        let clamped = NSRange(
            location: min(range.location, length - 1),
            length: max(0, min(range.length, length - min(range.location, length - 1)))
        )
        let glyphs = layoutManager.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
        var union = NSRect.null
        if glyphs.length > 0 {
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                union = union.union(rect)
            }
        }
        guard !union.isNull else { return nil }
        union.origin.x = textContainerOrigin.x - 8
        union.origin.y += textContainerOrigin.y - 6
        union.size.width = max(textContainer.containerSize.width + 16, 80)
        union.size.height += 12
        if union.height < 28 { union.size.height = 28 }
        return union
    }
}

/// A quiet edge affordance that becomes tangible only while the pointer is on it.
private final class TableInsertButton: NSButton {
    private var pointerInside = false
    private var pointerTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        contentTintColor = .secondaryLabelColor
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .default
        wantsLayer = true
        layer?.cornerRadius = 3
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        updateAppearance()
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        updateAppearance()
        NSCursor.arrow.set()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let alpha: CGFloat = pointerInside ? 0.15 : 0.07
        layer?.backgroundColor = (dark ? NSColor.white : NSColor.black)
            .withAlphaComponent(alpha)
            .cgColor
        contentTintColor = pointerInside ? .labelColor : .secondaryLabelColor
    }
}

protocol WikiLinkKeyHandling: AnyObject {
    func handleCommand(_ selector: Selector) -> Bool
    func dismissWikiPopup()
}

/// Floating candidate list anchored to the caret, matching Obsidian's wiki-link picker.
final class WikiLinkPopupController {
    var onChoose: ((NoteMeta) -> Void)?
    private let panel: NSPanel
    private var hosting: NSHostingView<WikiLinkPickerView>?

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }

    func show(notes: [NoteMeta], selected: Int, caret: NSRect, dark: Bool) {
        let root = WikiLinkPickerView(
            notes: notes,
            selected: selected,
            dark: dark,
            onChoose: { [weak self] note in self?.onChoose?(note) }
        )
        let host: NSHostingView<WikiLinkPickerView>
        if let hosting {
            hosting.rootView = root
            host = hosting
        } else {
            host = NSHostingView(rootView: root)
            hosting = host
            panel.contentView = host
        }
        let height = min(300, CGFloat(max(notes.count, 1)) * 44 + 36)
        let size = NSSize(width: 360, height: height)
        host.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)

        let screen = NSScreen.main?.visibleFrame ?? caret
        var origin = NSPoint(x: caret.minX, y: caret.minY - 6 - size.height)
        if origin.y < screen.minY {
            origin.y = caret.maxY + 6
        }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    func updateSelection(_ selected: Int) {
        guard let hosting else { return }
        var root = hosting.rootView
        root.selected = selected
        hosting.rootView = root
    }

    func dismiss() {
        panel.orderOut(nil)
    }
}

struct WikiLinkPickerView: View {
    var notes: [NoteMeta]
    var selected: Int
    var dark: Bool
    var onChoose: (NoteMeta) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if notes.isEmpty {
                Text("No matching notes")
                    .font(.caption)
                    .foregroundStyle(VGTheme.textMuted(dark: dark))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                                Button {
                                    onChoose(note)
                                } label: {
                                    HStack(spacing: 0) {
                                        Rectangle()
                                            .fill(index == selected ? VGTheme.accent : Color.clear)
                                            .frame(width: 2)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(note.title)
                                                .foregroundStyle(VGTheme.textNormal(dark: dark))
                                            let folder = WikiLinkSuggest.folderLabel(for: note)
                                            if !folder.isEmpty {
                                                Text(folder)
                                                    .font(.caption2)
                                                    .foregroundStyle(VGTheme.textFaint(dark: dark))
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(index == selected ? VGTheme.hover(dark: dark) : Color.clear)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                    }
                    .onChange(of: selected) { _, value in
                        proxy.scrollTo(value, anchor: .center)
                    }
                    .onAppear { proxy.scrollTo(selected, anchor: .center) }
                }
            }
            VGTheme.divider(dark: dark).frame(height: 1)
            Text("Enter to insert · Esc to dismiss")
                .font(.caption2)
                .foregroundStyle(VGTheme.textFaint(dark: dark))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .frame(width: 360)
        .background(VGTheme.backgroundSecondary(dark: dark))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(VGTheme.divider(dark: dark), lineWidth: 1)
        )
        .preferredColorScheme(dark ? .dark : .light)
    }
}

private enum NoteEditorLayoutPreferenceKey: PreferenceKey {
    static var defaultValue: CGSize?

    static func reduce(value: inout CGSize?, nextValue: () -> CGSize?) {
        value = nextValue() ?? value
    }
}

struct NoteEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming = false
    var onLayout: ((CGSize) -> Void)? = nil

    var body: some View {
        if let tab = model.activeTab, let index = model.tabs.firstIndex(where: { $0.id == tab.id }) {
            VStack(alignment: .leading, spacing: 0) {
                titleRow(tab)
                if model.editorMode == .preview {
                    MarkdownPreviewView(
                        text: tab.content,
                        noteTitles: Set(model.notes.map { $0.title.lowercased() }),
                        baseURL: URL(fileURLWithPath: tab.path).deletingLastPathComponent(),
                        dark: model.dark,
                        loadRemoteImages: model.settings.loadRemoteImages
                    ) { target in
                        Task { await model.followWikiLink(target) }
                    }
                } else {
                    SourceEditor(
                        text: Bindable(model).tabs[index].content,
                        notes: model.notes,
                        dark: model.dark,
                        baseURL: URL(fileURLWithPath: tab.path).deletingLastPathComponent(),
                        loadRemoteImages: model.settings.loadRemoteImages
                    )
                        .onChange(of: model.tabs[index].content) { _, newValue in
                            model.updateContent(tab.id, newValue)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                if onLayout != nil {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: NoteEditorLayoutPreferenceKey.self,
                            value: geometry.size
                        )
                    }
                }
            }
            .onPreferenceChange(NoteEditorLayoutPreferenceKey.self) { size in
                if let size { onLayout?(size) }
            }
            .onChange(of: tab.path) { _, _ in
                renaming = false
            }
        } else {
            Text("No file is open. Create a note or open a Markdown file.")
                .foregroundStyle(VGTheme.textFaint(dark: model.dark))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func titleRow(_ tab: NoteTab) -> some View {
        Group {
            if renaming {
                InlineRenameField(
                    text: tab.title,
                    font: .system(size: 34, weight: .bold)
                ) { name in
                    renaming = false
                    Task { await model.renameNote(path: tab.path, newName: name) }
                } onCancel: {
                    renaming = false
                }
            } else {
                Text(tab.title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(VGTheme.textNormal(dark: model.dark))
                    .contentShape(Rectangle())
                    .onTapGesture { renaming = true }
                    .help("Rename")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Renames this note")
            }
        }
        .tracking(-0.4)
        .padding(.horizontal, 56)
        .padding(.top, 24)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inline text field used to rename a note title or file tree entry.
struct InlineRenameField: View {
    let text: String
    var font: Font = .body
    var onCommit: (String) -> Void
    var onCancel: () -> Void
    @State private var draft: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(
        text: String,
        font: Font = .body,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.text = text
        self.font = font
        self.onCommit = onCommit
        self.onCancel = onCancel
        _draft = State(initialValue: text)
    }

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit { commit() }
            .onExitCommand { cancel() }
            .onChange(of: focused) { _, on in
                if !on { commit() }
            }
    }

    private func commit() {
        guard !finished else { return }
        finished = true
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            onCancel()
        } else {
            onCommit(value)
        }
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        onCancel()
    }
}
