import AppKit
import SwiftUI

/// Native NSTextView source editor with `[[` wiki-link completion.
struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    var notes: [NoteMeta]
    var dark: Bool
    var baseURL: URL?
    var loadRemoteImages = false
    var focusRequestID: UUID?
    var focusPlacement: EditorFocusRequest.Placement = .end
    var onFocusRequestFulfilled: (UUID) -> Void = { _ in }
    var headingScrollRequest: HeadingScrollRequest?
    var onHeadingScrollRequestFulfilled: (UUID) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: { text = $0 })
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = DocumentScrollView()
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
        textView.textContainerInset = NSSize(width: VGTheme.documentHorizontalPadding, height: 8)
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
        context.coordinator.onFocusRequestFulfilled = onFocusRequestFulfilled
        context.coordinator.updateFocusRequest(focusRequestID, placement: focusPlacement)
        context.coordinator.onHeadingScrollRequestFulfilled = onHeadingScrollRequestFulfilled
        context.coordinator.reveal(headingScrollRequest)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onChange = { text = $0 }
        context.coordinator.notes = notes
        let darkChanged = context.coordinator.dark != dark
        context.coordinator.dark = dark
        context.coordinator.baseURL = baseURL
        context.coordinator.loadRemoteImages = loadRemoteImages
        context.coordinator.onFocusRequestFulfilled = onFocusRequestFulfilled
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
        context.coordinator.updateFocusRequest(focusRequestID, placement: focusPlacement)
        context.coordinator.onHeadingScrollRequestFulfilled = onHeadingScrollRequestFulfilled
        context.coordinator.reveal(headingScrollRequest)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.prepareForDismantle()
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
        var onFocusRequestFulfilled: (UUID) -> Void = { _ in }
        var onHeadingScrollRequestFulfilled: (UUID) -> Void = { _ in }
        private var revealedHeadingID: UUID?
        private var cachedText: String?
        private var cachedTokens: [LivePreview.Token] = []
        private let popup = WikiLinkPopupController()
        private var session: WikiLinkSession?
        private var suggestions: [NoteMeta] = []
        private var selected = 0
        private var dismissedMarker: Int?
        private var restyling = false
        private var pendingRestyle: DispatchWorkItem?
        private var fulfilledFocusRequestID: UUID?
        private var activeFocusRequestID: UUID?
        private var pendingFocusRequestID: UUID?
        private var focusPlacement: EditorFocusRequest.Placement = .end
        private var dismantling = false
        private let focus: (SourceTextView) -> Bool

        var isPopupVisible: Bool { popup.isVisible }
        var selectedSuggestionIndex: Int { selected }

        init(
            onChange: @escaping (String) -> Void,
            focus: @escaping (SourceTextView) -> Bool = {
                guard let window = $0.window else { return false }
                return window.makeFirstResponder($0)
            }
        ) {
            self.onChange = onChange
            self.focus = focus
            super.init()
            popup.onChoose = { [weak self] note in
                self?.insert(note)
            }
        }

        func updateFocusRequest(
            _ id: UUID?,
            placement: EditorFocusRequest.Placement = .end
        ) {
            activeFocusRequestID = id
            focusPlacement = placement
            guard let id else {
                pendingFocusRequestID = nil
                return
            }
            requestFocus(id: id)
        }

        private func requestFocus(id: UUID, remainingAttempts: Int = 8) {
            guard activeFocusRequestID == id,
                  fulfilledFocusRequestID != id,
                  pendingFocusRequestID != id,
                  !dismantling
            else { return }
            pendingFocusRequestID = id
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.activeFocusRequestID == id,
                      let textView = self.textView,
                      !self.dismantling
                else {
                    if self?.pendingFocusRequestID == id {
                        self?.pendingFocusRequestID = nil
                    }
                    return
                }
                self.pendingFocusRequestID = nil
                switch self.focusPlacement {
                case .start:
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                case .end:
                    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                case .preserveSelection:
                    break
                }
                if self.focus(textView) {
                    self.fulfilledFocusRequestID = id
                    self.onFocusRequestFulfilled(id)
                } else if remainingAttempts > 1 {
                    self.requestFocus(id: id, remainingAttempts: remainingAttempts - 1)
                }
            }
        }

        /// Scrolls a heading's line to the top once per request.
        func reveal(_ request: HeadingScrollRequest?) {
            guard let request, revealedHeadingID != request.id else { return }
            revealedHeadingID = request.id
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView, !self.dismantling else { return }
                let location = Self.location(ofLine: request.heading.line, in: textView.string)
                textView.scrollLineToTop(containingCharacterAt: location)
                self.onHeadingScrollRequestFulfilled(request.id)
            }
        }

        /// The UTF-16 offset where a one-based line starts, clamped to the text.
        static func location(ofLine line: Int, in text: String) -> Int {
            let ns = text as NSString
            var location = 0
            for _ in 1..<max(line, 1) {
                let next = ns.range(of: "\n", range: NSRange(location: location, length: ns.length - location))
                guard next.location != NSNotFound else { return ns.length }
                location = next.location + 1
            }
            return location
        }

        func prepareForDismantle() {
            dismantling = true
            activeFocusRequestID = nil
            pendingFocusRequestID = nil
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
    private struct MarkdownLinePair: Hashable {
        let header: String
        let separator: String
    }

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
    var linkEditErrorHandler: ((String) -> Void)?
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEditable, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let ignoredFlags: NSEvent.ModifierFlags = [.capsLock, .numericPad, .function]
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(ignoredFlags)
        let key = event.charactersIgnoringModifiers?.lowercased()

        switch (key, modifiers) {
        case ("b", [.command]):
            toggleBold(nil)
        case ("i", [.command]):
            toggleItalic(nil)
        case ("u", [.command]):
            toggleUnderline(nil)
        case ("k", [.command]):
            editLink(nil)
        case ("1", [.command, .option]):
            applyHeading(level: 1)
        case ("2", [.command, .option]):
            applyHeading(level: 2)
        case ("3", [.command, .option]):
            applyHeading(level: 3)
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    @objc func toggleBold(_ sender: Any?) {
        guard isEditable else { return }
        toggleAsteriskStyle(markerLength: 2)
    }

    @objc func toggleItalic(_ sender: Any?) {
        guard isEditable else { return }
        toggleAsteriskStyle(markerLength: 1)
    }

    @objc func toggleUnderline(_ sender: Any?) {
        guard isEditable else { return }
        toggleDelimitedStyle(
            preferred: (opening: "<u>", closing: "</u>"),
            accepted: [
                (opening: "<u>", closing: "</u>"),
                (opening: "<ins>", closing: "</ins>"),
            ]
        )
    }

    @objc func applyHeading1(_ sender: Any?) { applyHeading(level: 1) }
    @objc func applyHeading2(_ sender: Any?) { applyHeading(level: 2) }
    @objc func applyHeading3(_ sender: Any?) { applyHeading(level: 3) }

    @objc func editLink(_ sender: Any?) {
        guard isEditable else { return }
        let context = linkEditingContext()
        guard !context.isImage else {
            reportLinkEditError("Command-K edits links, not image destinations.")
            return
        }
        let alert = NSAlert()
        alert.messageText = context.isExistingLink ? "Edit link" : "Add link"
        alert.informativeText = "Enter the URL for the selected text."
        alert.addButton(withTitle: context.isExistingLink ? "Update Link" : "Add Link")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = context.url ?? ""
        field.placeholderString = "https://example.com"
        alert.accessoryView = field

        let complete: (NSApplication.ModalResponse) -> Void = { [weak self, weak field] response in
            guard let self, let field else { return }
            self.handleLinkResponse(response, url: field.stringValue, context: context)
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: complete)
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(field)
                field.selectText(nil)
            }
        } else {
            complete(alert.runModal())
        }
    }

    @discardableResult
    func applyLink(url: String) -> Bool {
        completeLinkEdit(url: url, context: linkEditingContext())
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
        let plain = plainText(from: pasteboard)
        for (pasteboardType, documentType) in Self.richPasteboardTypes {
            if let data = pasteboard.data(forType: pasteboardType) {
                guard data.count <= Self.maximumRichPasteboardBytes else { break }
                if pasteboardType == .html,
                   let plain,
                   let html = RichTextMarkdownConverter.decodedHTML(data),
                   RichTextMarkdownConverter.isSourceEditorHTML(html) {
                    // Source editors place syntax-highlighted presentation HTML beside
                    // the exact source selection. The plain representation is already
                    // Markdown and must win so wrapper divs and br elements cannot alter it.
                    return plain
                }
                guard let markdown = RichTextMarkdownConverter.markdown(
                    from: data,
                    documentType: documentType
                ) else { continue }
                if let plain {
                    // Source editors such as VS Code put faithful Markdown beside a
                    // presentation-oriented rich representation. Prefer that source only
                    // when conversion demonstrably split a table's header and separator
                    // into separate paragraphs. Semantic rich code blocks retain adjacent
                    // lines inside their fence and continue through the rich path.
                    if richConversionBreaksMarkdownTable(markdown, from: plain) {
                        return plain
                    }
                    return markdownPreservingBoundaryWhitespace(markdown, from: plain)
                }
                return markdown
            }
        }
        return plain
    }

    private func richConversionBreaksMarkdownTable(_ converted: String, from plain: String) -> Bool {
        let plainLines = markdownLines(in: plain)
        guard plainLines.count >= 2 else { return false }
        let convertedLines = markdownLines(in: converted)
        var separatedRichLinePairs: Set<MarkdownLinePair> = []

        for convertedHeaderIndex in convertedLines.indices {
            let convertedHeader = normalizedMarkdownLine(convertedLines[convertedHeaderIndex])
            guard !convertedHeader.isEmpty else { continue }
            var nextContentIndex = convertedHeaderIndex + 1
            while nextContentIndex < convertedLines.count,
                  normalizedMarkdownLine(convertedLines[nextContentIndex]).isEmpty {
                nextContentIndex += 1
            }
            guard nextContentIndex > convertedHeaderIndex + 1,
                  nextContentIndex < convertedLines.count else { continue }
            separatedRichLinePairs.insert(MarkdownLinePair(
                header: convertedHeader,
                separator: normalizedMarkdownLine(convertedLines[nextContentIndex])
            ))
        }

        for separatorIndex in plainLines.indices.dropFirst() {
            let header = plainLines[separatorIndex - 1]
            let separator = plainLines[separatorIndex]
            guard GFM.isTable(header: header, separator: separator) else { continue }
            if separatedRichLinePairs.contains(MarkdownLinePair(
                header: normalizedMarkdownLine(header),
                separator: normalizedMarkdownLine(separator)
            )) {
                return true
            }
        }
        return false
    }

    private func markdownLines(in text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    private func normalizedMarkdownLine(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
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

    private func toggleAsteriskStyle(markerLength: Int) {
        let source = string as NSString
        let selection = selectedRange()
        guard isValid(selection, in: source) else { return }
        let selected = source.substring(with: selection) as NSString
        for marker: unichar in [42, 95] {
            let selectedLeading = delimiterCount(after: 0, marker: marker, in: selected)
            let selectedTrailing = delimiterCount(before: selected.length, marker: marker, in: selected)
            if selection.length > markerLength * 2,
               styleIsActive(markerLength: markerLength, leftCount: selectedLeading, rightCount: selectedTrailing),
               delimiterRunIsMarkup(
                   marker: marker,
                   openingLocation: selection.location,
                   closingEnd: NSMaxRange(selection),
                   in: source
               ) {
                let innerLength = selection.length - (markerLength * 2)
                let replacement = selected.substring(
                    with: NSRange(location: markerLength, length: innerLength)
                )
                _ = replaceSource(
                    in: selection,
                    with: replacement,
                    selecting: NSRange(location: selection.location, length: innerLength)
                )
                return
            }

            let leftCount = delimiterCount(before: selection.location, marker: marker, in: source)
            let rightCount = delimiterCount(after: NSMaxRange(selection), marker: marker, in: source)
            let openingLocation = selection.location - markerLength
            if styleIsActive(markerLength: markerLength, leftCount: leftCount, rightCount: rightCount),
               delimiterRunIsMarkup(
                   marker: marker,
                   openingLocation: selection.location - leftCount,
                   closingEnd: NSMaxRange(selection) + rightCount,
                   in: source
               ) {
                let replacementRange = NSRange(
                    location: openingLocation,
                    length: selection.length + (markerLength * 2)
                )
                _ = replaceSource(
                    in: replacementRange,
                    with: selected as String,
                    selecting: NSRange(location: replacementRange.location, length: selection.length)
                )
                return
            }
        }

        let marker = String(repeating: "*", count: markerLength)
        _ = replaceSource(
            in: selection,
            with: marker + (selected as String) + marker,
            selecting: NSRange(location: selection.location + markerLength, length: selection.length)
        )
    }

    private func styleIsActive(markerLength: Int, leftCount: Int, rightCount: Int) -> Bool {
        if markerLength == 1 {
            return leftCount % 2 == 1 && rightCount % 2 == 1
        }
        return leftCount >= markerLength && rightCount >= markerLength
    }

    private func delimiterCount(before location: Int, marker: unichar, in source: NSString) -> Int {
        var index = location
        while index > 0, source.character(at: index - 1) == marker { index -= 1 }
        return location - index
    }

    private func delimiterCount(after location: Int, marker: unichar, in source: NSString) -> Int {
        var index = location
        while index < source.length, source.character(at: index) == marker { index += 1 }
        return index - location
    }

    private func delimiterRunIsMarkup(
        marker: unichar,
        openingLocation: Int,
        closingEnd: Int,
        in source: NSString
    ) -> Bool {
        guard openingLocation >= 0, closingEnd <= source.length,
              !isEscaped(openingLocation, in: source) else { return false }
        guard marker == 95 else { return true }
        let beforeIsWord = openingLocation > 0 && isMarkdownWordCharacter(source.character(at: openingLocation - 1))
        let afterIsWord = closingEnd < source.length && isMarkdownWordCharacter(source.character(at: closingEnd))
        return !beforeIsWord && !afterIsWord
    }

    private func isEscaped(_ location: Int, in source: NSString) -> Bool {
        var cursor = location
        var slashes = 0
        while cursor > 0, source.character(at: cursor - 1) == 92 {
            slashes += 1
            cursor -= 1
        }
        return !slashes.isMultiple(of: 2)
    }

    private func isMarkdownWordCharacter(_ character: unichar) -> Bool {
        guard character != 95 else { return true }
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private func toggleDelimitedStyle(
        preferred: (opening: String, closing: String),
        accepted: [(opening: String, closing: String)]
    ) {
        let source = string as NSString
        let selection = selectedRange()
        guard isValid(selection, in: source) else { return }

        for delimiter in accepted {
            let openingLength = (delimiter.opening as NSString).length
            let closingLength = (delimiter.closing as NSString).length
            if selection.length >= openingLength + closingLength {
                let selected = source.substring(with: selection) as NSString
                let openingRange = NSRange(location: 0, length: openingLength)
                let closingRange = NSRange(location: selected.length - closingLength, length: closingLength)
                if selected.substring(with: openingRange).caseInsensitiveCompare(delimiter.opening) == .orderedSame,
                   selected.substring(with: closingRange).caseInsensitiveCompare(delimiter.closing) == .orderedSame {
                    let contentLength = selected.length - openingLength - closingLength
                    let content = selected.substring(
                        with: NSRange(location: openingLength, length: contentLength)
                    )
                    _ = replaceSource(
                        in: selection,
                        with: content,
                        selecting: NSRange(location: selection.location, length: contentLength)
                    )
                    return
                }
            }

            let openingRange = NSRange(
                location: selection.location - openingLength,
                length: openingLength
            )
            let closingRange = NSRange(location: NSMaxRange(selection), length: closingLength)
            if openingRange.location >= 0,
               NSMaxRange(closingRange) <= source.length,
               source.substring(with: openingRange).caseInsensitiveCompare(delimiter.opening) == .orderedSame,
               source.substring(with: closingRange).caseInsensitiveCompare(delimiter.closing) == .orderedSame {
                let replacementRange = NSRange(
                    location: openingRange.location,
                    length: openingLength + selection.length + closingLength
                )
                let content = source.substring(with: selection)
                _ = replaceSource(
                    in: replacementRange,
                    with: content,
                    selecting: NSRange(location: replacementRange.location, length: selection.length)
                )
                return
            }
        }

        let content = source.substring(with: selection)
        _ = replaceSource(
            in: selection,
            with: preferred.opening + content + preferred.closing,
            selecting: NSRange(
                location: selection.location + (preferred.opening as NSString).length,
                length: selection.length
            )
        )
    }

    private func applyHeading(level: Int) {
        guard isEditable, (1...3).contains(level) else { return }
        let source = string as NSString
        let selection = selectedRange()
        guard isValid(selection, in: source) else { return }

        let probe = NSRange(location: selection.location, length: max(0, selection.length - 1))
        let affectedRange = source.lineRange(for: probe)
        let replacementPrefix = String(repeating: "#", count: level) + " "
        let replacementPrefixLength = (replacementPrefix as NSString).length
        var output = ""
        var edits: [(location: Int, oldLength: Int, newLength: Int)] = []
        var cursor = affectedRange.location

        repeat {
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            let clipped = NSIntersectionRange(lineRange, affectedRange)
            let line = source.substring(with: clipped) as NSString
            let visibleLine = (line as String).replacingOccurrences(
                of: #"[\r\n]+$"#,
                with: "",
                options: .regularExpression
            )
            if visibleLine.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty {
                output += line as String
                edits.append((cursor, 0, 0))
                cursor = NSMaxRange(clipped)
                continue
            }
            let oldPrefixLength = markdownHeadingPrefixLength(in: line)
            output += replacementPrefix
            output += line.substring(from: oldPrefixLength)
            edits.append((cursor, oldPrefixLength, replacementPrefixLength))
            cursor = NSMaxRange(clipped)
        } while cursor < NSMaxRange(affectedRange)

        func mapped(_ position: Int) -> Int {
            var delta = 0
            for edit in edits {
                if position < edit.location { break }
                if position <= edit.location + edit.oldLength {
                    return edit.location + delta + edit.newLength
                }
                delta += edit.newLength - edit.oldLength
            }
            return position + delta
        }

        let mappedStart = mapped(selection.location)
        let mappedEnd = mapped(NSMaxRange(selection))
        _ = replaceSource(
            in: affectedRange,
            with: output,
            selecting: NSRange(location: mappedStart, length: max(0, mappedEnd - mappedStart))
        )
    }

    private func markdownHeadingPrefixLength(in line: NSString) -> Int {
        var hashes = 0
        while hashes < min(6, line.length), line.character(at: hashes) == 35 { hashes += 1 }
        guard hashes > 0 else { return 0 }
        if hashes == line.length { return hashes }
        let firstWhitespace = line.character(at: hashes)
        if firstWhitespace == 10 || firstWhitespace == 13 { return hashes }
        guard firstWhitespace == 32 || firstWhitespace == 9 else { return 0 }
        var end = hashes + 1
        while end < line.length {
            let character = line.character(at: end)
            guard character == 32 || character == 9 else { break }
            end += 1
        }
        return end
    }

    struct LinkEditingContext {
        var range: NSRange
        var label: String
        var url: String?
        var original: String
        var isExistingLink: Bool
        var isImage: Bool
    }

    func linkEditingContext() -> LinkEditingContext {
        let source = string as NSString
        let selection = selectedRange()
        for link in GFM.inlineLinks(in: string, includingImages: true) {
            let selectionIsInside = selection.length == 0
                ? selection.location >= link.range.location && selection.location < NSMaxRange(link.range)
                : selection.location >= link.range.location && NSMaxRange(selection) <= NSMaxRange(link.range)
            guard selectionIsInside else { continue }
            return LinkEditingContext(
                range: link.range,
                label: link.label,
                url: link.destination,
                original: source.substring(with: link.range),
                isExistingLink: !link.isImage,
                isImage: link.isImage
            )
        }
        let safeSelection = isValid(selection, in: source) ? selection : NSRange(location: source.length, length: 0)
        return LinkEditingContext(
            range: safeSelection,
            label: source.substring(with: safeSelection),
            url: nil,
            original: source.substring(with: safeSelection),
            isExistingLink: false,
            isImage: false
        )
    }

    @discardableResult
    func handleLinkResponse(
        _ response: NSApplication.ModalResponse,
        url: String,
        context: LinkEditingContext
    ) -> Bool {
        guard response == .alertFirstButtonReturn else { return false }
        return completeLinkEdit(url: url, context: context)
    }

    @discardableResult
    func completeLinkEdit(url: String, context: LinkEditingContext) -> Bool {
        guard !context.isImage else {
            reportLinkEditError("Command-K edits links, not image destinations.")
            return false
        }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard context.isExistingLink else {
                reportLinkEditError("Enter a URL before adding the link.")
                return false
            }
            return replaceExistingLinkWithLabel(context)
        }
        guard applyLink(url: trimmed, context: context) else {
            reportLinkEditError("The note changed while the link editor was open. Reopen it and try again.")
            return false
        }
        return true
    }

    @discardableResult
    func applyLink(url: String, context: LinkEditingContext) -> Bool {
        let source = string as NSString
        guard isValid(context.range, in: source),
              source.substring(with: context.range) == context.original else { return false }
        let label = context.label.isEmpty ? url : context.label
        let replacement = GFM.serializeInlineLink(label: label, destination: url)
        guard let serialized = GFM.inlineLinks(in: replacement).first else { return false }
        return replaceSource(
            in: context.range,
            with: replacement,
            selecting: NSRange(
                location: context.range.location + serialized.labelRange.location,
                length: serialized.labelRange.length
            )
        )
    }

    private func replaceExistingLinkWithLabel(_ context: LinkEditingContext) -> Bool {
        let source = string as NSString
        guard isValid(context.range, in: source),
              source.substring(with: context.range) == context.original else {
            reportLinkEditError("The note changed while the link editor was open. Reopen it and try again.")
            return false
        }
        return replaceSource(
            in: context.range,
            with: context.label,
            selecting: NSRange(location: context.range.location, length: (context.label as NSString).length)
        )
    }

    private func reportLinkEditError(_ message: String) {
        if let linkEditErrorHandler {
            linkEditErrorHandler(message)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Link not changed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func isValid(_ range: NSRange, in source: NSString) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length >= 0 && NSMaxRange(range) <= source.length
    }

    @discardableResult
    private func replaceSource(in range: NSRange, with replacement: String, selecting selection: NSRange) -> Bool {
        guard shouldChangeText(in: range, replacementString: replacement) else { return false }
        replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(selection)
        scrollRangeToVisible(selection)
        return true
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
            guard let rect = codeBlockRect(for: decoration.range),
                  rect.intersects(dirtyRect) else { continue }
            CodeHighlight.blockFill(dark: decoration.dark).setFill()
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

    struct CodeBadge {
        let label: String
        let origin: NSPoint
        let clipRect: NSRect
    }

    static func codeBadge(language: String, in rect: NSRect) -> CodeBadge? {
        let label = CodeHighlight.displayName(for: language)
        guard !label.isEmpty else { return nil }
        let size = (label as NSString).size(withAttributes: [.font: CodeHighlight.labelFont])
        let clipRect = rect.insetBy(dx: 8, dy: 0)
        guard clipRect.width > 0, clipRect.height > 0 else { return nil }
        return CodeBadge(
            label: label,
            origin: NSPoint(x: clipRect.maxX - 4 - size.width, y: rect.minY + 6),
            clipRect: clipRect
        )
    }

    private func drawLiveOverlays(in dirtyRect: NSRect) {
        guard let layoutManager, let textContainer else { return }
        for decoration in liveDecorations.codeBlocks where decoration.showBadge {
            guard let rect = codeBlockRect(for: decoration.range),
                  rect.intersects(dirtyRect) else { continue }
            guard let badge = Self.codeBadge(language: decoration.language, in: rect) else { continue }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: CodeHighlight.labelFont,
                .foregroundColor: CodeHighlight.labelColor(dark: decoration.dark)
            ]
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: badge.clipRect).addClip()
            (badge.label as NSString).draw(at: badge.origin, withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
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

    /// The filled rectangle behind a live code block, in view coordinates.
    func codeBlockRect(for range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        return blockRect(
            for: range,
            layoutManager: layoutManager,
            textContainer: textContainer,
            includingTrailingEmptyLine: true
        )
    }

    private func blockRect(
        for range: NSRange,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        includingTrailingEmptyLine: Bool = false
    ) -> NSRect? {
        let source = string as NSString
        let length = source.length
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
        // A block running to the end of a document that ends in a newline (an unclosed
        // fence after pressing Return) owns the empty last line. That line has no glyphs;
        // it is the layout manager's extra line fragment, so cover it explicitly.
        if includingTrailingEmptyLine, !union.isNull, NSMaxRange(range) >= length {
            let last = source.character(at: length - 1)
            let extra = layoutManager.extraLineFragmentRect
            if (last == 10 || last == 13), !extra.isEmpty {
                union = union.union(extra)
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
    var onRowsMeasured: (([WikiLinkPickerRowLayout]) -> Void)? = nil

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
                        // Eager stack with a single identity per row: mixing lazy cell reuse with a
                        // second `.id` modifier showed stale rows (duplicates / missing notes).
                        VStack(spacing: 0) {
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
                                .background {
                                    if onRowsMeasured != nil {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: WikiLinkPickerRowsKey.self,
                                                value: [WikiLinkPickerRowLayout(
                                                    path: note.path,
                                                    frame: geometry.frame(in: .named("WikiLinkPickerScroll"))
                                                )]
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .coordinateSpace(name: "WikiLinkPickerScroll")
                    .onPreferenceChange(WikiLinkPickerRowsKey.self) { rows in
                        onRowsMeasured?(rows)
                    }
                    .onChange(of: selected) { _, value in
                        scroll(proxy, to: value)
                    }
                    .onAppear { scroll(proxy, to: selected) }
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

    private func scroll(_ proxy: ScrollViewProxy, to index: Int) {
        guard notes.indices.contains(index) else { return }
        proxy.scrollTo(notes[index].id, anchor: .center)
    }
}

struct WikiLinkPickerRowLayout: Equatable {
    var path: String
    var frame: CGRect
}

private struct WikiLinkPickerRowsKey: PreferenceKey {
    static var defaultValue: [WikiLinkPickerRowLayout] = []

    static func reduce(value: inout [WikiLinkPickerRowLayout], nextValue: () -> [WikiLinkPickerRowLayout]) {
        value += nextValue()
    }
}

private enum NoteEditorLayoutPreferenceKey: PreferenceKey {
    static var defaultValue: CGSize?

    static func reduce(value: inout CGSize?, nextValue: () -> CGSize?) {
        value = nextValue() ?? value
    }
}

enum NoteEditorLeadingElement {
    case title
    case previewBody
    case sourceBody
}

struct NoteEditorView: View {
    @Environment(AppModel.self) private var model
    /// The tab group whose active tab to show; nil shows the app-wide active tab.
    var groupID: UUID? = nil
    var onDocumentLeading: ((NoteEditorLeadingElement, CGFloat) -> Void)? = nil
    var onLayout: ((CGSize) -> Void)? = nil

    private var displayedTabID: String? {
        if let groupID {
            model.tabGroupLayout.group(groupID)?.activeTabID
        } else {
            model.activeTabID
        }
    }

    var body: some View {
        if let id = displayedTabID, let index = model.tabs.firstIndex(where: { $0.id == id }) {
            let tab = model.tabs[index]
            VStack(alignment: .leading, spacing: 0) {
                titleRow(tab)
                if tab.editorMode == .preview {
                    MarkdownPreviewView(
                        text: tab.content,
                        noteTitles: Set(model.notes.map { $0.title.lowercased() }),
                        baseURL: URL(fileURLWithPath: tab.path).deletingLastPathComponent(),
                        dark: model.dark,
                        loadRemoteImages: model.settings.loadRemoteImages,
                        layoutCoordinateSpace: "NoteEditorLayout",
                        headingTarget: headingScrollRequest(for: tab).map {
                            ReadingHeadingTarget(
                                id: $0.id,
                                level: $0.heading.level,
                                text: $0.heading.text,
                                occurrence: $0.occurrence
                            )
                        },
                        onHeadingTargetFulfilled: { model.fulfillHeadingScrollRequest($0) },
                        onLayout: onDocumentLeading == nil ? nil : { metrics in
                            if let leading = metrics.contentLeading {
                                onDocumentLeading?(.previewBody, leading)
                            }
                        }
                    ) { target in
                        Task { await model.followWikiLink(target, inGroup: groupID) }
                    }
                } else {
                    SourceEditor(
                        text: Bindable(model).tabs[index].content,
                        notes: model.notes,
                        dark: model.dark,
                        baseURL: URL(fileURLWithPath: tab.path).deletingLastPathComponent(),
                        loadRemoteImages: model.settings.loadRemoteImages,
                        focusRequestID: model.editorFocusRequest?.tabID == tab.id
                            ? model.editorFocusRequest?.id
                            : nil,
                        focusPlacement: model.editorFocusRequest?.placement ?? .end,
                        onFocusRequestFulfilled: { model.fulfillEditorFocusRequest($0) },
                        headingScrollRequest: headingScrollRequest(for: tab),
                        onHeadingScrollRequestFulfilled: { model.fulfillHeadingScrollRequest($0) }
                    )
                        .background {
                            if onDocumentLeading != nil {
                                GeometryReader { geometry in
                                    let leading = geometry.frame(
                                        in: .named("NoteEditorLayout")
                                    ).minX + VGTheme.documentHorizontalInset(
                                        paneWidth: geometry.size.width
                                    )
                                    Color.clear
                                        .onAppear {
                                            onDocumentLeading?(.sourceBody, leading)
                                        }
                                        .onChange(of: leading) { _, newLeading in
                                            onDocumentLeading?(.sourceBody, newLeading)
                                        }
                                }
                            }
                        }
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
            .coordinateSpace(name: "NoteEditorLayout")
        } else {
            Text("No file is open. Create a note or open a Markdown file.")
                .foregroundStyle(VGTheme.textFaint(dark: model.dark))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The outline's scroll request, for the focused group's view of its tab only.
    private func headingScrollRequest(for tab: NoteTab) -> HeadingScrollRequest? {
        guard let request = model.headingScrollRequest, request.tabID == tab.id,
              groupID == nil || groupID == model.tabGroupLayout.focusedGroupID
        else { return nil }
        return request
    }

    private func titleRow(_ tab: NoteTab) -> some View {
        Group {
            if model.titleEditingTabID == tab.id {
                InlineRenameField(
                    text: model.titleEditingDraft,
                    font: .systemFont(ofSize: 34, weight: .bold),
                    commitOnDisappear: true,
                    onChange: { model.updateTitleDraft(for: tab.id, draft: $0) },
                    onSubmit: { name in
                        Task { await model.submitTitleEditing(for: tab.id, draft: name) }
                    }
                ) { name in
                    Task {
                        model.updateTitleDraft(for: tab.id, draft: name)
                        await model.commitTitleEditing(for: tab.id)
                    }
                } onCancel: {
                    Task { model.endEditingTitle(for: tab.id) }
                }
                .id(tab.id)
                // The borderless NSTextField bridge renders two points left of its SwiftUI frame.
                .padding(.leading, 2)
            } else {
                NoteTitleRenameButton(
                    title: tab.title,
                    color: NSColor(VGTheme.textNormal(dark: model.dark))
                ) {
                    model.beginEditingTitle(for: tab.id)
                }
                .fixedSize()
            }
        }
        .tracking(-0.4)
        .background {
            if onDocumentLeading != nil {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            onDocumentLeading?(
                                .title,
                                geometry.frame(in: .named("NoteEditorLayout")).minX
                            )
                        }
                        .onChange(of: geometry.frame(in: .named("NoteEditorLayout")).minX) { _, leading in
                            onDocumentLeading?(.title, leading)
                        }
                }
            }
        }
        .padding(.horizontal, VGTheme.documentHorizontalPadding)
        // Share the body's centred reading column so the title keeps its leading edge.
        .frame(maxWidth: VGTheme.readingColumnMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 4)
    }
}

final class NoteTitleRenameNSButton: NSButton {}

struct NoteTitleRenameButton: NSViewRepresentable {
    let title: String
    let color: NSColor
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NoteTitleRenameNSButton {
        let button = NoteTitleRenameNSButton()
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.font = .systemFont(ofSize: 34, weight: .bold)
        button.target = context.coordinator
        button.action = #selector(Coordinator.activate(_:))
        button.toolTip = "Rename"
        button.setAccessibilityRole(.button)
        button.setAccessibilityHelp("Renames this note")
        update(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ nsView: NoteTitleRenameNSButton, context: Context) {
        context.coordinator.action = action
        update(nsView, coordinator: context.coordinator)
    }

    private func update(_ button: NoteTitleRenameNSButton, coordinator: Coordinator) {
        button.title = title
        button.contentTintColor = color
        button.setAccessibilityLabel(title)
        button.sizeToFit()
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func activate(_ sender: Any?) {
            action()
        }
    }
}

/// Inline text field used to rename a note title or file tree entry.
struct InlineRenameField: View {
    let text: String
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var commitOnDisappear: Bool
    var onChange: (String) -> Void
    var onSubmit: ((String) -> Void)?
    var onCommit: (String) -> Void
    var onCancel: () -> Void
    @State private var draft: String

    init(
        text: String,
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        commitOnDisappear: Bool = false,
        onChange: @escaping (String) -> Void = { _ in },
        onSubmit: ((String) -> Void)? = nil,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.text = text
        self.font = font
        self.commitOnDisappear = commitOnDisappear
        self.onChange = onChange
        self.onSubmit = onSubmit
        self.onCommit = onCommit
        self.onCancel = onCancel
        _draft = State(initialValue: text)
    }

    var body: some View {
        InlineRenameTextField(
            text: $draft,
            font: font,
            commitOnDismantle: commitOnDisappear,
            onChange: onChange,
            onSubmit: onSubmit,
            onCommit: onCommit,
            onCancel: onCancel
        )
    }
}

/// An NSTextField with field-editor access scoped to this specific control.
final class InlineRenameNSTextField: NSTextField {
    @discardableResult
    func focusAndSelectAll() -> Bool {
        guard let window,
              window.makeFirstResponder(self),
              let editor = currentEditor()
        else { return false }
        editor.selectAll(nil)
        return true
    }
}

/// Native backing for InlineRenameField. AppKit exposes the owning control's currentEditor(),
/// avoiding accidental selection in the window's shared field editor for another text field.
struct InlineRenameTextField: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var commitOnDismantle: Bool = false
    var onChange: (String) -> Void = { _ in }
    /// Receives a nonempty name committed with Return. Other commits (blur, teardown) and
    /// callers without this handler use `onCommit`.
    var onSubmit: ((String) -> Void)?
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> InlineRenameNSTextField {
        let field = InlineRenameNSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.placeholderString = "Name"
        field.setAccessibilityLabel("Name")
        field.font = font
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        context.coordinator.attach(field)
        return field
    }

    func updateNSView(_ nsView: InlineRenameNSTextField, context: Context) {
        context.coordinator.parent = self
        nsView.font = font
        if nsView.currentEditor() == nil, nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.requestFocus()
    }

    static func dismantleNSView(_ nsView: InlineRenameNSTextField, coordinator: Coordinator) {
        coordinator.prepareForDismantle()
        nsView.delegate = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineRenameTextField
        weak var textField: InlineRenameNSTextField?
        private let focus: (InlineRenameNSTextField) -> Bool
        private var finished = false
        private var dismantling = false
        private var focusRequested = false
        private(set) var focusRequestPending = false

        init(
            parent: InlineRenameTextField,
            focus: @escaping (InlineRenameNSTextField) -> Bool = { $0.focusAndSelectAll() }
        ) {
            self.parent = parent
            self.focus = focus
        }

        func attach(_ textField: InlineRenameNSTextField) {
            self.textField = textField
            requestFocus()
        }

        func requestFocus(remainingAttempts: Int = 8) {
            guard !focusRequested, !focusRequestPending, !finished, !dismantling else { return }
            // makeNSView and updateNSView can run before this asynchronous request executes.
            // Mark it pending now so they cannot enqueue a second makeFirstResponder call, which
            // would end the field editor session we just started and immediately commit the name.
            focusRequestPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let textField = self.textField,
                      !self.finished, !self.dismantling
                else {
                    self?.focusRequestPending = false
                    return
                }
                if self.focus(textField) {
                    self.focusRequested = true
                    self.focusRequestPending = false
                } else {
                    self.focusRequestPending = false
                    if remainingAttempts > 1 {
                        self.requestFocus(remainingAttempts: remainingAttempts - 1)
                    }
                }
            }
        }

        func prepareForDismantle() {
            if parent.commitOnDismantle {
                complete(commit: true)
            }
            dismantling = true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue
            parent.onChange(textField.stringValue)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            textField?.currentEditor()?.selectAll(nil)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            // Defer until AppKit/SwiftUI have finished their responder and hierarchy updates.
            // A normal blur leaves the field attached and commits. Teardown behavior is chosen by
            // the caller so a document title can save during navigation without changing tree edits.
            DispatchQueue.main.async { [weak self] in
                guard let self, let textField = self.textField,
                      textField.window != nil, textField.superview != nil,
                      !self.dismantling
                else { return }
                self.complete(commit: true)
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                complete(commit: false)
                control.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                complete(commit: true, submitted: true)
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }

        private func complete(commit: Bool, submitted: Bool = false) {
            guard !finished, !dismantling else { return }
            finished = true
            guard commit else {
                parent.onCancel()
                return
            }
            let value = (textField?.stringValue ?? parent.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                parent.onCancel()
            } else if submitted, let onSubmit = parent.onSubmit {
                onSubmit(value)
            } else {
                parent.onCommit(value)
            }
        }
    }
}
