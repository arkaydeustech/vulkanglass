import AppKit
import ImageIO
import SwiftUI

struct MarkdownPreviewLayoutMetrics: Equatable {
    var scrollSurfaceSize: CGSize?
    var readingColumnSize: CGSize?
    var contentLeading: CGFloat?
}

private enum MarkdownPreviewLayoutPreferenceKey: PreferenceKey {
    static var defaultValue = MarkdownPreviewLayoutMetrics()

    static func reduce(
        value: inout MarkdownPreviewLayoutMetrics,
        nextValue: () -> MarkdownPreviewLayoutMetrics
    ) {
        let next = nextValue()
        value.scrollSurfaceSize = next.scrollSurfaceSize ?? value.scrollSurfaceSize
        value.readingColumnSize = next.readingColumnSize ?? value.readingColumnSize
        value.contentLeading = next.contentLeading ?? value.contentLeading
    }
}

/// Reading view: headings, lists, teal wiki links, and tag pills.
struct MarkdownPreviewView: View {
    let text: String
    let noteTitles: Set<String>
    var baseURL: URL? = nil
    var dark = true
    var loadLocalImages = true
    var loadRemoteImages = false
    var hidesLeadingTitle = true
    var layoutCoordinateSpace: String? = nil
    var onLayout: ((MarkdownPreviewLayoutMetrics) -> Void)? = nil
    var onWiki: (String) -> Void
    let displayBlocks: [MDBlock]

    init(
        text: String,
        noteTitles: Set<String>,
        baseURL: URL? = nil,
        dark: Bool = true,
        loadLocalImages: Bool = true,
        loadRemoteImages: Bool = false,
        hidesLeadingTitle: Bool = true,
        parsedBlocks: [MDBlock]? = nil,
        layoutCoordinateSpace: String? = nil,
        onLayout: ((MarkdownPreviewLayoutMetrics) -> Void)? = nil,
        onWiki: @escaping (String) -> Void
    ) {
        self.text = text
        self.noteTitles = noteTitles
        self.baseURL = baseURL
        self.dark = dark
        self.loadLocalImages = loadLocalImages
        self.loadRemoteImages = loadRemoteImages
        self.hidesLeadingTitle = hidesLeadingTitle
        self.layoutCoordinateSpace = layoutCoordinateSpace
        self.onLayout = onLayout
        self.onWiki = onWiki

        var blocks = parsedBlocks ?? MDBlock.parse(text)
        if hidesLeadingTitle, case .heading(1, _) = blocks.first {
            blocks.removeFirst()
        }
        displayBlocks = blocks
    }

    var body: some View {
        unifiedTextPreview
    }

    private var unifiedTextPreview: some View {
        GeometryReader { geometry in
            let paneWidth = max(0, geometry.size.width)
            UnifiedReadingTextView(
                blocks: displayBlocks,
                noteTitles: noteTitles,
                baseURL: baseURL,
                dark: dark,
                loadLocalImages: loadLocalImages,
                loadRemoteImages: loadRemoteImages,
                onWiki: onWiki
            )
            .frame(
                width: VGTheme.readingColumnWidth(paneWidth: paneWidth),
                height: geometry.size.height,
                alignment: .topLeading
            )
            .background {
                if onLayout != nil {
                    GeometryReader { columnGeometry in
                        Color.clear.preference(
                            key: MarkdownPreviewLayoutPreferenceKey.self,
                            value: MarkdownPreviewLayoutMetrics(
                                readingColumnSize: columnGeometry.size,
                                contentLeading: columnGeometry.frame(
                                    in: .named(layoutCoordinateSpace ?? "MarkdownPreviewLayout")
                                ).minX + VGTheme.documentHorizontalPadding
                            )
                        )
                    }
                }
            }
            .frame(minWidth: paneWidth, alignment: .leading)
            .background {
                if onLayout != nil {
                    Color.clear.preference(
                        key: MarkdownPreviewLayoutPreferenceKey.self,
                        value: MarkdownPreviewLayoutMetrics(scrollSurfaceSize: geometry.size)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: "MarkdownPreviewLayout")
        .onPreferenceChange(MarkdownPreviewLayoutPreferenceKey.self) { metrics in
            guard metrics.scrollSurfaceSize != nil, metrics.readingColumnSize != nil else { return }
            onLayout?(metrics)
        }
    }
}

/// One native text system owns a prose document's selection. That lets a drag cross
/// paragraphs and inline styles, and keeps contextual actions scoped to this note.
struct ReadingRenderConfiguration: Equatable {
    let blocks: [MDBlock]
    let noteTitles: Set<String>
    let baseURL: URL?
    let dark: Bool
    let loadLocalImages: Bool
    let loadRemoteImages: Bool
}

struct UnifiedReadingTextView: NSViewRepresentable {
    let blocks: [MDBlock]
    let noteTitles: Set<String>
    let baseURL: URL?
    let dark: Bool
    let loadLocalImages: Bool
    let loadRemoteImages: Bool
    let onWiki: (String) -> Void

    private var configuration: ReadingRenderConfiguration {
        ReadingRenderConfiguration(
            blocks: blocks,
            noteTitles: noteTitles,
            baseURL: baseURL,
            dark: dark,
            loadLocalImages: loadLocalImages,
            loadRemoteImages: loadRemoteImages
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onWiki: onWiki)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = ReadingNSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: VGTheme.documentHorizontalPadding, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        context.coordinator.textView = textView
        update(textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onWiki = onWiki
        guard let textView = nsView.documentView as? ReadingNSTextView else { return }
        update(textView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        (nsView.documentView as? ReadingNSTextView)?.delegate = nil
        coordinator.stop()
    }

    private func update(_ textView: ReadingNSTextView, coordinator: Coordinator) {
        coordinator.render(configuration, in: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        typealias ImageLoader = @Sendable (URL) async -> ReadingDecodedImage?

        var onWiki: (String) -> Void
        weak var textView: ReadingNSTextView?
        private(set) var documentSetCount = 0
        private var lastConfiguration: ReadingRenderConfiguration?
        private var detailsStates: [String: Bool] = [:]
        private var generation = 0
        private var imageTasks: [Task<Void, Never>] = []
        private let imageLoader: ImageLoader

        init(
            onWiki: @escaping (String) -> Void,
            imageLoader: @escaping ImageLoader = { url in
                await ReadingImageLoader.shared.image(for: url)
            }
        ) {
            self.onWiki = onWiki
            self.imageLoader = imageLoader
        }

        func render(
            _ configuration: ReadingRenderConfiguration,
            in textView: ReadingNSTextView,
            force: Bool = false
        ) {
            self.textView = textView
            applyTextViewAttributes(to: textView)
            guard force || lastConfiguration != configuration else { return }

            if let previous = lastConfiguration, previous.blocks != configuration.blocks {
                detailsStates.removeAll()
            }
            lastConfiguration = configuration
            generation += 1
            let currentGeneration = generation
            imageTasks.forEach { $0.cancel() }
            imageTasks.removeAll(keepingCapacity: true)

            let attributedText = ReadingAttributedDocument.make(
                blocks: configuration.blocks,
                noteTitles: configuration.noteTitles,
                baseURL: configuration.baseURL,
                dark: configuration.dark,
                loadLocalImages: configuration.loadLocalImages,
                loadRemoteImages: configuration.loadRemoteImages,
                expandedDetails: detailsStates
            )
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(attributedText)
            documentSetCount += 1
            let boundedLocation = min(selection.location, attributedText.length)
            let boundedLength = min(selection.length, attributedText.length - boundedLocation)
            textView.setSelectedRange(NSRange(location: boundedLocation, length: boundedLength))
            scheduleImageLoads(in: attributedText, generation: currentGeneration)
        }

        func stop() {
            generation += 1
            imageTasks.forEach { $0.cancel() }
            imageTasks.removeAll()
            textView = nil
        }

        private func applyTextViewAttributes(to textView: ReadingNSTextView) {
            textView.linkTextAttributes = [
                .foregroundColor: NSColor(VGTheme.textAccent),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand,
            ]
            textView.selectedTextAttributes = [
                .backgroundColor: NSColor(VGTheme.accent).withAlphaComponent(0.28)
            ]
        }

        private func scheduleImageLoads(
            in attributedText: NSAttributedString,
            generation currentGeneration: Int
        ) {
            var urls: Set<URL> = []
            attributedText.enumerateAttribute(
                .readingImageURL,
                in: NSRange(location: 0, length: attributedText.length)
            ) { value, _, _ in
                guard let raw = value as? String, let url = URL(string: raw) else { return }
                urls.insert(url)
            }

            for url in urls {
                let task = Task { [weak self] in
                    guard let self, let decoded = await imageLoader(url), !Task.isCancelled else {
                        return
                    }
                    apply(decoded, for: url, generation: currentGeneration)
                }
                imageTasks.append(task)
            }
        }

        private func apply(
            _ decoded: ReadingDecodedImage,
            for url: URL,
            generation expectedGeneration: Int
        ) {
            guard generation == expectedGeneration,
                  let textStorage = textView?.textStorage else { return }
            let fullRange = NSRange(location: 0, length: textStorage.length)
            var ranges: [NSRange] = []
            textStorage.enumerateAttribute(.readingImageURL, in: fullRange) { value, range, _ in
                guard value as? String == url.absoluteString else { return }
                ranges.append(range)
            }
            guard !ranges.isEmpty else { return }

            let image = NSImage(cgImage: decoded.image, size: decoded.size)
            textStorage.beginEditing()
            for range in ranges {
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(
                    origin: .zero,
                    size: ReadingAttributedDocument.fittedImageSize(decoded.size)
                )
                textStorage.addAttribute(.attachment, value: attachment, range: range)
            }
            textStorage.endEditing()
        }

        func textView(
            _ textView: NSTextView,
            clickedOnLink link: Any,
            at charIndex: Int
        ) -> Bool {
            guard let url = (link as? URL) ?? (link as? NSURL).map({ $0 as URL }) else {
                return false
            }
            if url.scheme?.lowercased() == "vulkanglass-details" {
                let id = String(url.path.drop(while: { $0 == "/" }))
                guard !id.isEmpty,
                      let configuration = lastConfiguration,
                      let readingTextView = textView as? ReadingNSTextView else { return false }
                let initial = (textView.attributedString().attribute(
                    .readingDetailsInitiallyOpen,
                    at: charIndex,
                    effectiveRange: nil
                ) as? NSNumber)?.boolValue ?? false
                detailsStates[id] = !(detailsStates[id] ?? initial)
                render(configuration, in: readingTextView, force: true)
                return true
            }
            if url.scheme?.lowercased() == "wiki" {
                let encodedTarget = String(url.absoluteString.dropFirst("wiki://".count))
                onWiki(encodedTarget.removingPercentEncoding ?? encodedTarget)
                return true
            }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}

final class ReadingNSTextView: NSTextView {
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = selectedRange().length > 0
        menu.addItem(copyItem)
        menu.addItem(.separator())
        let selectAllItem = NSMenuItem(
            title: "Select All",
            action: #selector(selectAll(_:)),
            keyEquivalent: ""
        )
        selectAllItem.target = self
        selectAllItem.isEnabled = !string.isEmpty
        menu.addItem(selectAllItem)
        return menu
    }
}

extension NSAttributedString.Key {
    static let readingImageURL = NSAttributedString.Key("VulkanGlassReadingImageURL")
    static let readingDetailsInitiallyOpen = NSAttributedString.Key(
        "VulkanGlassReadingDetailsInitiallyOpen"
    )
}

struct ReadingDecodedImage: @unchecked Sendable {
    let image: CGImage
    let size: CGSize
}

actor ReadingImageLoader {
    static let shared = ReadingImageLoader()

    private var cache: [String: ReadingDecodedImage] = [:]

    func image(for url: URL) async -> ReadingDecodedImage? {
        let key = cacheKey(for: url)
        if let cached = cache[key] { return cached }

        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url, options: .mappedIfSafe)
        } else {
            data = try? await RemoteImageLoader.data(from: url)
        }
        guard !Task.isCancelled, let data else { return nil }
        let decoded = await Task.detached(priority: .utility) {
            Self.decode(data)
        }.value
        guard !Task.isCancelled, let decoded else { return nil }
        cache[key] = decoded
        return decoded
    }

    private func cacheKey(for url: URL) -> String {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [
                  .contentModificationDateKey,
                  .fileSizeKey,
              ]) else { return url.absoluteString }
        return "\(url.absoluteString)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)"
    }

    nonisolated private static func decode(_ data: Data) -> ReadingDecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 640,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return ReadingDecodedImage(
            image: image,
            size: CGSize(width: image.width, height: image.height)
        )
    }
}

enum ReadingAttributedDocument {
    private struct TableCell {
        let row: Int
        let column: Int
        let rowSpan: Int
        let columnSpan: Int
        let content: String
        let isHeader: Bool
        let alignment: GFM.Alignment
    }

    static func make(
        blocks: [MDBlock],
        noteTitles: Set<String>,
        baseURL: URL?,
        dark: Bool,
        loadLocalImages: Bool = true,
        loadRemoteImages: Bool = false,
        includesBottomPadding: Bool = true,
        expandedDetails: [String: Bool] = [:],
        pathPrefix: String = ""
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let textColor = NSColor(VGTheme.textNormal(dark: dark))
        let mutedColor = NSColor(VGTheme.textMuted(dark: dark))
        let bodyFont = NSFont.systemFont(ofSize: 16)

        func appendInline(
            _ source: String,
            font: NSFont = NSFont.systemFont(ofSize: 16),
            color: NSColor? = nil
        ) {
            result.append(inline(
                source,
                noteTitles: noteTitles,
                baseURL: baseURL,
                font: font,
                color: color ?? textColor,
                loadLocalImages: loadLocalImages,
                loadRemoteImages: loadRemoteImages
            ))
        }

        func appendBreak() {
            guard result.length > 0 else { return }
            let separator = result.string.hasSuffix("\n\n")
                ? ""
                : (result.string.hasSuffix("\n") ? "\n" : "\n\n")
            result.append(NSAttributedString(string: separator, attributes: [
                .font: bodyFont,
                .foregroundColor: textColor,
            ]))
        }

        func appendTable(
            cells: [TableCell],
            columnCount: Int,
            caption: String? = nil
        ) {
            guard columnCount > 0 else { return }
            if let caption, !caption.isEmpty {
                appendInline(caption, font: .systemFont(ofSize: 14, weight: .semibold))
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: bodyFont,
                    .foregroundColor: textColor,
                ]))
            }

            let table = NSTextTable()
            table.numberOfColumns = columnCount
            table.layoutAlgorithm = .automatic
            table.collapsesBorders = true
            table.hidesEmptyCells = false
            table.setValue(100, type: .percentage, for: .width)

            for cell in cells.sorted(by: {
                $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row
            }) {
                let tableBlock = NSTextTableBlock(
                    table: table,
                    startingRow: cell.row,
                    rowSpan: cell.rowSpan,
                    startingColumn: cell.column,
                    columnSpan: cell.columnSpan
                )
                tableBlock.setWidth(8, type: .absolute, for: .padding)
                tableBlock.setWidth(0.5, type: .absolute, for: .border)
                tableBlock.setBorderColor(NSColor(VGTheme.divider(dark: dark)))
                tableBlock.verticalAlignment = .middle
                if cell.isHeader {
                    tableBlock.backgroundColor = NSColor(
                        VGTheme.backgroundSecondary(dark: dark)
                    ).withAlphaComponent(0.85)
                }

                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [tableBlock]
                paragraph.alignment = textAlignment(cell.alignment)
                let font = cell.isHeader
                    ? NSFont.systemFont(ofSize: 16, weight: .semibold)
                    : bodyFont
                let content = NSMutableAttributedString(attributedString: inline(
                    cell.content,
                    noteTitles: noteTitles,
                    baseURL: baseURL,
                    font: font,
                    color: textColor,
                    loadLocalImages: loadLocalImages,
                    loadRemoteImages: loadRemoteImages
                ))
                content.append(NSAttributedString(string: "\n", attributes: [
                    .font: font,
                    .foregroundColor: textColor,
                ]))
                content.addAttribute(
                    .paragraphStyle,
                    value: paragraph,
                    range: NSRange(location: 0, length: content.length)
                )
                result.append(content)
            }
        }

        for (blockIndex, block) in blocks.enumerated() {
            if blockIndex > 0 { appendBreak() }
            switch block {
            case .code(_, let code):
                let paragraph = NSMutableParagraphStyle()
                paragraph.paragraphSpacing = 4
                result.append(NSAttributedString(string: code, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                    .foregroundColor: textColor,
                    .backgroundColor: NSColor(VGTheme.backgroundSecondary(dark: dark)).withAlphaComponent(0.85),
                    .paragraphStyle: paragraph,
                ]))
            case .heading(let level, let source):
                appendInline(source, font: headingFont(level))
            case .alert(let kind, let lines):
                let color = alertColor(kind)
                result.append(NSAttributedString(string: "\(kind.title)\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                    .foregroundColor: color,
                ]))
                for (index, line) in lines.enumerated() {
                    if index > 0 { result.append(NSAttributedString(string: "\n")) }
                    appendInline(line)
                }
            case .quote(let lines):
                for (index, line) in lines.enumerated() {
                    if index > 0 { result.append(NSAttributedString(string: "\n")) }
                    result.append(NSAttributedString(string: "▏ ", attributes: [
                        .font: bodyFont,
                        .foregroundColor: NSColor(VGTheme.accent),
                    ]))
                    appendInline(line, color: mutedColor)
                }
            case .rule:
                result.append(NSAttributedString(string: "────────────────────────", attributes: [
                    .font: bodyFont,
                    .foregroundColor: NSColor(VGTheme.divider(dark: dark)),
                ]))
            case .lines(let lines):
                for (index, line) in lines.enumerated() {
                    if index > 0 { result.append(NSAttributedString(string: "\n")) }
                    let displayLine = normalizedLine(line)
                    appendInline(displayLine)
                }
            case .table(let rows, let alignments, let hasHeader):
                let cells = rows.enumerated().flatMap { row, values in
                    values.enumerated().map { column, content in
                        TableCell(
                            row: row,
                            column: column,
                            rowSpan: 1,
                            columnSpan: 1,
                            content: content,
                            isHeader: hasHeader && row == 0,
                            alignment: alignments.indices.contains(column)
                                ? alignments[column]
                                : .left
                        )
                    }
                }
                appendTable(
                    cells: cells,
                    columnCount: rows.map(\.count).max() ?? alignments.count
                )
            case .richTable(let source):
                appendTable(
                    cells: source.cells.map {
                        TableCell(
                            row: $0.row,
                            column: $0.column,
                            rowSpan: $0.rowSpan,
                            columnSpan: $0.columnSpan,
                            content: $0.content,
                            isHeader: $0.isHeader,
                            alignment: $0.alignment
                        )
                    },
                    columnCount: source.columnCount,
                    caption: source.caption
                )
            case .details(let summary, let body, let initiallyOpen):
                let detailsID = "\(pathPrefix)\(blockIndex)"
                let isOpen = expandedDetails[detailsID] ?? initiallyOpen
                let summaryStart = result.length
                result.append(NSAttributedString(
                    string: isOpen ? "▾ " : "▸ ",
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: mutedColor,
                    ]
                ))
                appendInline(summary, font: .systemFont(ofSize: 16, weight: .semibold))
                let summaryRange = NSRange(
                    location: summaryStart,
                    length: result.length - summaryStart
                )
                result.addAttributes([
                    .link: URL(string: "vulkanglass-details://toggle/\(detailsID)")!,
                    .readingDetailsInitiallyOpen: NSNumber(value: initiallyOpen),
                ], range: summaryRange)
                if isOpen, !body.isEmpty {
                    result.append(NSAttributedString(string: "\n", attributes: [
                        .font: bodyFont,
                        .foregroundColor: textColor,
                    ]))
                    result.append(make(
                        blocks: MDBlock.parse(body),
                        noteTitles: noteTitles,
                        baseURL: baseURL,
                        dark: dark,
                        loadLocalImages: loadLocalImages,
                        loadRemoteImages: loadRemoteImages,
                        includesBottomPadding: false,
                        expandedDetails: expandedDetails,
                        pathPrefix: "\(detailsID)."
                    ))
                }
            case .definitionList(let items):
                for (itemIndex, item) in items.enumerated() {
                    if itemIndex > 0 {
                        result.append(NSAttributedString(string: "\n", attributes: [
                            .font: bodyFont,
                            .foregroundColor: textColor,
                        ]))
                    }
                    appendInline(item.term, font: .systemFont(ofSize: 16, weight: .semibold))
                    for (definitionIndex, definition) in item.definitions.enumerated() {
                        result.append(NSAttributedString(string: "\n", attributes: [
                            .font: bodyFont,
                            .foregroundColor: textColor,
                        ]))
                        let nested = NSMutableAttributedString(attributedString: make(
                            blocks: MDBlock.parse(definition),
                            noteTitles: noteTitles,
                            baseURL: baseURL,
                            dark: dark,
                            loadLocalImages: loadLocalImages,
                            loadRemoteImages: loadRemoteImages,
                            includesBottomPadding: false,
                            expandedDetails: expandedDetails,
                            pathPrefix: "\(pathPrefix)\(blockIndex).definition.\(itemIndex).\(definitionIndex)."
                        ))
                        applyHangingIndent(
                            to: nested,
                            amount: 20
                        )
                        result.append(nested)
                    }
                }
            }
        }

        if includesBottomPadding {
            result.append(NSAttributedString(string: "\n", attributes: [
                .font: bodyFont,
                .foregroundColor: textColor,
                .paragraphStyle: {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.paragraphSpacing = VGTheme.readingBottomPadding
                    return paragraph
                }(),
            ]))
        }
        return result
    }

    static func inline(
        _ source: String,
        noteTitles: Set<String>,
        baseURL: URL?,
        font: NSFont,
        color: NSColor,
        loadLocalImages: Bool,
        loadRemoteImages: Bool
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in InlineRunsView.parse(source) {
            let value: String
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            switch run {
            case .text(let text), .emoji(let text):
                value = text
            case .bold(let text):
                value = text
                attributes[.font] = font.withTraits(.boldFontMask)
            case .italic(let text):
                value = text
                attributes[.font] = font.withTraits(.italicFontMask)
            case .boldItalic(let text):
                value = text
                attributes[.font] = font.withTraits([.boldFontMask, .italicFontMask])
            case .strikethrough(let text):
                value = text
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .underline(let text):
                value = text
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case .subscriptText(let text):
                value = text
                attributes[.font] = NSFont.systemFont(ofSize: max(9, font.pointSize - 5))
                attributes[.baselineOffset] = -3
            case .superscriptText(let text):
                value = text
                attributes[.font] = NSFont.systemFont(ofSize: max(9, font.pointSize - 5))
                attributes[.baselineOffset] = 5
            case .keyboard(let text):
                value = text
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
                attributes[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
            case .highlight(let text):
                value = text
                attributes[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.38)
            case .wiki(let target, let label):
                value = label
                attributes[.link] = wikiURL(target)
                attributes[.foregroundColor] = NSColor(VGTheme.textAccent).withAlphaComponent(
                    noteTitles.contains(target.lowercased()) ? 1 : 0.55
                )
            case .tag(let tag):
                value = "#\(tag)"
                attributes[.foregroundColor] = NSColor(VGTheme.textAccent)
                attributes[.backgroundColor] = NSColor(VGTheme.accent).withAlphaComponent(0.22)
            case .link(let label, let rawURL):
                value = label
                if rawURL.hasPrefix("wiki://") {
                    let encoded = String(rawURL.dropFirst("wiki://".count))
                    attributes[.link] = wikiURL(encoded.removingPercentEncoding ?? encoded)
                } else if let url = MarkdownResourceResolver.linkURL(rawURL, relativeTo: baseURL) {
                    attributes[.link] = url
                }
            case .code(let text):
                value = text
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
                attributes[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.18)
            case .footnote(let text):
                value = text
                attributes[.font] = NSFont.systemFont(ofSize: 10)
                attributes[.foregroundColor] = NSColor(VGTheme.textAccent)
                attributes[.baselineOffset] = 4
            case .image(let alt, let rawURL):
                let resolvedURL = MarkdownResourceResolver.imageURL(
                    rawURL,
                    relativeTo: baseURL
                )
                if let resolvedURL,
                   MarkdownResourceResolver.mayLoadImage(
                       resolvedURL,
                       loadLocalImages: loadLocalImages,
                       loadRemoteImages: loadRemoteImages
                   ) {
                    let attachment = NSTextAttachment()
                    attachment.image = loadingImagePlaceholder(alt: alt)
                    attachment.bounds = CGRect(x: 0, y: -3, width: 20, height: 20)
                    let loading = NSMutableAttributedString(attachment: attachment)
                    loading.addAttribute(
                        .readingImageURL,
                        value: resolvedURL.absoluteString,
                        range: NSRange(location: 0, length: loading.length)
                    )
                    result.append(loading)
                    continue
                }
                value = MarkdownResourceResolver.imagePlaceholder(
                    alt: alt,
                    resolvedURL: resolvedURL,
                    loadLocalImages: loadLocalImages,
                    loadRemoteImages: loadRemoteImages
                )
                attributes[.font] = font.withTraits(.italicFontMask)
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            }
            result.append(NSAttributedString(string: value, attributes: attributes))
        }
        return result
    }

    private static func wikiURL(_ target: String) -> URL {
        let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        return URL(string: "wiki://\(encoded)")!
    }

    static func fittedImageSize(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(1, 640 / size.width, 240 / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private static func loadingImagePlaceholder(alt: String) -> NSImage? {
        NSImage(
            systemSymbolName: "photo",
            accessibilityDescription: alt.isEmpty ? "Loading image" : alt
        )
    }

    private static func applyHangingIndent(
        to attributed: NSMutableAttributedString,
        amount: CGFloat
    ) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        var updates: [(NSRange, NSMutableParagraphStyle)] = []
        attributed.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            let paragraph = (value as? NSParagraphStyle)?.mutableCopy()
                as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.headIndent += amount
            paragraph.firstLineHeadIndent += amount
            updates.append((range, paragraph))
        }
        for (range, paragraph) in updates {
            attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
    }

    private static func normalizedLine(_ line: String) -> String {
        if line.hasPrefix("- [ ] ") { return "☐ \(line.dropFirst(6))" }
        if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            return "☑ \(line.dropFirst(6))"
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return "• \(line.dropFirst(2))"
        }
        return line
    }

    private static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: return .systemFont(ofSize: 28, weight: .bold)
        case 2, 3: return .systemFont(ofSize: 22, weight: .bold)
        default: return .systemFont(ofSize: 20, weight: .bold)
        }
    }

    private static func textAlignment(_ alignment: GFM.Alignment) -> NSTextAlignment {
        switch alignment {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    private static func alertColor(_ kind: GFM.AlertKind) -> NSColor {
        switch kind {
        case .note: return NSColor(red: 0.35, green: 0.62, blue: 0.95, alpha: 1)
        case .tip: return NSColor(VGTheme.accent)
        case .important: return NSColor(red: 0.72, green: 0.48, blue: 0.95, alpha: 1)
        case .warning: return NSColor(red: 0.95, green: 0.68, blue: 0.22, alpha: 1)
        case .caution: return NSColor(red: 0.90, green: 0.32, blue: 0.32, alpha: 1)
        }
    }
}

private extension NSFont {
    func withTraits(_ traits: NSFontTraitMask) -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: traits)
    }
}

enum MDBlock: Equatable, Sendable {
    case code(language: String, code: String)
    case heading(Int, String)
    case quote([String])
    case alert(GFM.AlertKind, [String])
    case table([[String]], [GFM.Alignment], hasHeader: Bool)
    case richTable(GFM.HTMLTable)
    case details(summary: String, body: String, initiallyOpen: Bool)
    case definitionList([GFM.DefinitionItem])
    case rule
    case lines([String])

    static func parse(_ text: String) -> [MDBlock] {
        let raw = text.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        var result: [MDBlock] = []
        var i = 0
        while i < raw.count {
            let line = raw[i]
            if let openingFence = codeFenceOpening(line) {
                var buffer = [line]
                var closed = false
                i += 1
                while i < raw.count {
                    buffer.append(raw[i])
                    if isCodeFenceClosing(raw[i], minimumLength: openingFence.length) {
                        closed = true
                        i += 1
                        break
                    }
                    i += 1
                }
                let language = openingFence.info
                let content = closed ? buffer.dropFirst().dropLast() : buffer.dropFirst()[...]
                let code = content.joined(separator: "\n")
                result.append(.code(language: language, code: code))
                continue
            }
            if isHTMLElementStartLine(line, tag: "details"),
               let collected = collectHTMLElement(raw, startingAt: i, tag: "details") {
                let root = SemanticHTML.parseFragment(collected.source)
                if let details = SemanticHTML.firstElement(named: "details", in: root) {
                    let summaryNode = details.children.first { $0.name == "summary" }
                    let summary = summaryNode.flatMap { SemanticHTML.embeddedMarkdown(from: $0.children) }
                        ?? "Details"
                    let bodyNodes = summaryNode.map { summary in
                        details.children.filter { $0 !== summary }
                    } ?? details.children
                    let body = SemanticHTML.embeddedMarkdown(from: bodyNodes) ?? ""
                    result.append(.details(
                        summary: summary.isEmpty ? "Details" : summary,
                        body: body,
                        initiallyOpen: details.attributes["open"] != nil
                    ))
                    i = collected.nextIndex
                    continue
                }
            }
            if isHTMLElementStartLine(line, tag: "dl"),
               let collected = collectHTMLElement(raw, startingAt: i, tag: "dl") {
                let root = SemanticHTML.parseFragment(collected.source)
                if let list = SemanticHTML.firstElement(named: "dl", in: root) {
                    var items: [GFM.DefinitionItem] = []
                    for child in list.children where child.name == "dt" || child.name == "dd" {
                        let content = SemanticHTML.embeddedMarkdown(from: child.children) ?? ""
                        if child.name == "dt" {
                            items.append(.init(term: content, definitions: []))
                        } else if !items.isEmpty {
                            items[items.count - 1].definitions.append(content)
                        } else {
                            items.append(.init(term: "", definitions: [content]))
                        }
                    }
                    if !items.isEmpty {
                        result.append(.definitionList(items))
                        i = collected.nextIndex
                        continue
                    }
                }
            }
            if isHTMLTableStartLine(line) {
                if let collected = collectHTMLElement(
                    raw,
                    startingAt: i,
                    tag: "table",
                    stopsAtBlankLine: true
                ),
                   let table = GFM.parseHTMLTable(collected.source) {
                    if table.hasSpans || table.caption != nil {
                        result.append(.richTable(table))
                    } else {
                        var alignments = table.cells
                            .filter { $0.row == 0 }
                            .sorted { $0.column < $1.column }
                            .map(\.alignment)
                        if alignments.count < table.columnCount {
                            alignments.append(contentsOf: repeatElement(.left, count: table.columnCount - alignments.count))
                        }
                        result.append(.table(
                            table.rows,
                            alignments,
                            hasHeader: table.hasHeader
                        ))
                    }
                    i = collected.nextIndex
                    continue
                }
            }
            if let tag = semanticContainerTag(line),
               let collected = collectHTMLElement(raw, startingAt: i, tag: tag),
               let normalized = SemanticHTML.markdown(from: collected.source),
               normalized != collected.source {
                result.append(contentsOf: parse(normalized))
                i = collected.nextIndex
                continue
            }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).range(
                of: #"^<hr(?:\s[^>]*)?/?>$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                result.append(.rule)
                i += 1
                continue
            }
            if GFM.isHorizontalRule(line) {
                result.append(.rule)
                i += 1
                continue
            }
            if let kind = GFM.isAlertMarker(line) {
                var body: [String] = []
                i += 1
                while i < raw.count, raw[i].hasPrefix(">") {
                    let clipped = raw[i].hasPrefix("> ") ? String(raw[i].dropFirst(2)) : String(raw[i].dropFirst())
                    body.append(clipped)
                    i += 1
                }
                result.append(.alert(kind, body))
                continue
            }
            if line.hasPrefix("> ") || line == ">" {
                var quotes: [String] = []
                while i < raw.count, raw[i].hasPrefix(">") {
                    quotes.append(raw[i].hasPrefix("> ") ? String(raw[i].dropFirst(2)) : String(raw[i].dropFirst()))
                    i += 1
                }
                result.append(.quote(quotes))
                continue
            }
            if i + 1 < raw.count, GFM.isTable(header: line, separator: raw[i + 1]) {
                let alignments = GFM.splitTableRow(raw[i + 1]).map(GFM.Alignment.parse)
                let columnCount = alignments.count
                var rows = [GFM.normalizedTableRow(line, columnCount: columnCount)]
                i += 2
                while i < raw.count, GFM.looksLikeTableRow(raw[i]) {
                    rows.append(GFM.normalizedTableRow(raw[i], columnCount: columnCount))
                    i += 1
                }
                result.append(.table(rows, alignments, hasHeader: true))
                continue
            }
            if let heading = heading(line) {
                result.append(.heading(heading.0, heading.1))
                i += 1
                continue
            }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                i += 1
                continue
            }
            var lines: [String] = []
            while i < raw.count {
                let current = raw[i]
                if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                if current.hasPrefix("```") || current.hasPrefix("> ") || GFM.isHorizontalRule(current) { break }
                if let _ = heading(current) { break }
                if i + 1 < raw.count, GFM.isTable(header: current, separator: raw[i + 1]) { break }
                if !lines.isEmpty, isSemanticHTMLBlockStart(current) { break }
                lines.append(current)
                i += 1
            }
            if !lines.isEmpty { result.append(.lines(lines)) }
        }
        return result
    }

    private static func isHTMLTableStartLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"^<table(?:\s+[^>]*)?>"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isHTMLElementStartLine(_ line: String, tag: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: "^<\(tag)(?:\\s|>)",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func collectHTMLElement(
        _ lines: [String],
        startingAt start: Int,
        tag: String,
        stopsAtBlankLine: Bool = false
    ) -> (source: String, nextIndex: Int)? {
        var collected: [String] = []
        var index = start
        while index < lines.count {
            if stopsAtBlankLine,
               index > start,
               lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
            collected.append(lines[index])
            index += 1
            let source = collected.joined(separator: "\n")
            if containsCompleteElement(source, named: tag) {
                return (source, index)
            }
        }
        return nil
    }

    private static func containsCompleteElement(_ source: String, named target: String) -> Bool {
        var index = source.startIndex
        var depth = 0
        var sawOpening = false
        while index < source.endIndex {
            guard let opening = source[index...].firstIndex(of: "<") else { break }
            if source[opening...].hasPrefix("<!--") {
                guard let commentEnd = source.range(of: "-->", range: opening..<source.endIndex) else {
                    return false
                }
                index = commentEnd.upperBound
                continue
            }
            guard let closing = SemanticHTML.closingAngleBracket(in: source, after: opening) else {
                return false
            }
            var content = source[source.index(after: opening)..<closing]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            index = source.index(after: closing)
            guard !content.isEmpty, !content.hasPrefix("!"), !content.hasPrefix("?") else { continue }
            let isClosing = content.hasPrefix("/")
            if isClosing { content.removeFirst() }
            let selfClosing = content.hasSuffix("/")
            let name = content.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
            guard name == target.lowercased() else { continue }
            if isClosing {
                if sawOpening { depth -= 1 }
                if sawOpening && depth == 0 { return true }
            } else {
                sawOpening = true
                if !selfClosing { depth += 1 }
            }
        }
        return false
    }

    private static func codeFenceOpening(_ line: String) -> (length: Int, info: String)? {
        let length = line.prefix { $0 == "`" }.count
        guard length >= 3 else { return nil }
        return (length, String(line.dropFirst(length)).trimmingCharacters(in: .whitespaces))
    }

    private static func isCodeFenceClosing(_ line: String, minimumLength: Int) -> Bool {
        let length = line.prefix { $0 == "`" }.count
        guard length >= minimumLength else { return false }
        return line.dropFirst(length).allSatisfy(\.isWhitespace)
    }

    private static func semanticContainerTag(_ line: String) -> String? {
        for tag in ["blockquote", "figure", "p", "div", "ul", "ol", "pre"]
        where isHTMLElementStartLine(line, tag: tag) {
            return tag
        }
        return nil
    }

    private static func isSemanticHTMLBlockStart(_ line: String) -> Bool {
        if isHTMLTableStartLine(line)
            || isHTMLElementStartLine(line, tag: "details")
            || isHTMLElementStartLine(line, tag: "dl")
            || semanticContainerTag(line) != nil {
            return true
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"^<hr(?:\s[^>]*)?/?>$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func heading(_ block: String) -> (Int, String)? {
        if block.hasPrefix("###### ") { return (6, String(block.dropFirst(7))) }
        if block.hasPrefix("##### ") { return (5, String(block.dropFirst(6))) }
        if block.hasPrefix("#### ") { return (4, String(block.dropFirst(5))) }
        if block.hasPrefix("### ") { return (3, String(block.dropFirst(4))) }
        if block.hasPrefix("## ") { return (2, String(block.dropFirst(3))) }
        if block.hasPrefix("# ") { return (1, String(block.dropFirst(2))) }
        return nil
    }
}

enum InlineRun: Equatable {
    case text(String)
    case bold(String)
    case italic(String)
    case boldItalic(String)
    case strikethrough(String)
    case underline(String)
    case subscriptText(String)
    case superscriptText(String)
    case keyboard(String)
    case highlight(String)
    case wiki(target: String, label: String)
    case tag(String)
    case link(label: String, url: String)
    case code(String)
    case footnote(String)
    case emoji(String)
    case image(alt: String, url: String)

}

enum InlineRunsView {
    static func parse(_ input: String) -> [InlineRun] {
        var result: [InlineRun] = []
        var index = input.startIndex

        func appendText(_ value: String) {
            guard !value.isEmpty else { return }
            if case .text(let current) = result.last {
                result[result.count - 1] = .text(current + value)
            } else {
                result.append(.text(value))
            }
        }

        while index < input.endIndex {
            let suffix = input[index...]
            if input[index] == "\\" {
                let next = input.index(after: index)
                if next < input.endIndex, isMarkdownPunctuation(input[next]) {
                    appendText(String(input[next]))
                    index = input.index(after: next)
                    continue
                }
            }
            if input[index] == "<", let parsed = parseHTMLInline(input, from: index) {
                result.append(contentsOf: parsed.runs)
                index = parsed.end
                continue
            }
            if input[index] == "<", let parsed = parseUnderline(input, from: index) {
                result.append(.underline(parsed.content))
                index = parsed.end
                continue
            }
            if input[index] == "<", let parsed = parseScript(input, from: index) {
                result.append(parsed.superscript
                    ? .superscriptText(parsed.content)
                    : .subscriptText(parsed.content))
                index = parsed.end
                continue
            }
            if suffix.hasPrefix("[[") {
                let contentStart = input.index(index, offsetBy: 2)
                if let end = input.range(of: "]]", range: contentStart..<input.endIndex) {
                    let inner = String(input[contentStart..<end.lowerBound])
                    let fields = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    let navigation = fields.first.map(String.init)?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    let target = navigation.split(separator: "#", maxSplits: 1).first.map(String.init)?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    let label = fields.count == 2
                        ? String(fields[1]).trimmingCharacters(in: .whitespaces)
                        : navigation
                    if target.isEmpty {
                        appendText(String(input[index..<end.upperBound]))
                    } else {
                        result.append(.wiki(target: target, label: label.isEmpty ? target : label))
                    }
                    index = end.upperBound
                    continue
                }
                appendText("[[")
                index = contentStart
                continue
            }

            if suffix.hasPrefix("![") {
                if let parsed = parseImage(input, from: index) {
                    result.append(.image(alt: parsed.alt, url: parsed.url))
                    index = parsed.end
                    continue
                }
            }

            if suffix.hasPrefix("[^"), let end = input.range(of: "]", range: input.index(index, offsetBy: 2)..<input.endIndex) {
                let id = String(input[input.index(index, offsetBy: 2)..<end.lowerBound])
                if !id.isEmpty, end.upperBound >= input.endIndex || input[end.upperBound] != ":" {
                    result.append(.footnote(id))
                    index = end.upperBound
                    continue
                }
            }

            if suffix.hasPrefix("["), let parsed = parseLink(input, from: index) {
                result.append(.link(label: parsed.label, url: parsed.url))
                index = parsed.end
                continue
            }

            if suffix.hasPrefix("`"), let end = input[input.index(after: index)...].firstIndex(of: "`") {
                result.append(.code(String(input[input.index(after: index)..<end])))
                index = input.index(after: end)
                continue
            }

            if let parsed = parseDelimited(input, from: index, delimiter: "***") {
                result.append(contentsOf: applying(.boldItalic, to: parsed.content))
                index = parsed.end
                continue
            }

            if let parsed = parseDelimited(input, from: index, delimiter: "___") {
                result.append(contentsOf: applying(.boldItalic, to: parsed.content))
                index = parsed.end
                continue
            }

            if let parsed = parseDelimited(input, from: index, delimiter: "**") {
                result.append(contentsOf: applying(.bold, to: parsed.content))
                index = parsed.end
                continue
            }

            if let parsed = parseDelimited(input, from: index, delimiter: "__") {
                result.append(contentsOf: applying(.bold, to: parsed.content))
                index = parsed.end
                continue
            }

            if let parsed = parseDelimited(input, from: index, delimiter: "~~") {
                result.append(.strikethrough(parsed.content))
                index = parsed.end
                continue
            }

            if let parsed = parseDelimited(input, from: index, delimiter: "*") {
                result.append(contentsOf: applying(.italic, to: parsed.content))
                index = parsed.end
                continue
            }

            if let parsed = parseDelimited(input, from: index, delimiter: "_") {
                result.append(contentsOf: applying(.italic, to: parsed.content))
                index = parsed.end
                continue
            }

            if input[index] == ":", let parsed = parseEmoji(input, from: index) {
                result.append(.emoji(parsed.glyph))
                index = parsed.end
                continue
            }

            if suffix.hasPrefix("<!--"), let end = input.range(of: "-->", range: index..<input.endIndex) {
                index = end.upperBound
                continue
            }

            if input[index] == "#" {
                let startsTag = index == input.startIndex || input[input.index(before: index)].isWhitespace
                let afterHash = input.index(after: index)
                let tagEnd = input[afterHash...].firstIndex {
                    !($0.isLetter || $0.isNumber || $0 == "/" || $0 == "_" || $0 == "-")
                } ?? input.endIndex
                if startsTag, afterHash < tagEnd {
                    result.append(.tag(String(input[afterHash..<tagEnd])))
                    index = tagEnd
                    continue
                }
            }

            appendText(String(input[index]))
            index = input.index(after: index)
        }
        return result
    }

    private static func parseHTMLInline(
        _ input: String,
        from index: String.Index
    ) -> (runs: [InlineRun], end: String.Index)? {
        guard input[index] == "<",
              let openingEnd = SemanticHTML.closingAngleBracket(in: input, after: index) else { return nil }
        let opening = String(input[input.index(after: index)..<openingEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !opening.hasPrefix("/"), !opening.hasPrefix("!"), !opening.hasPrefix("?") else { return nil }
        let tag = opening.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
        let supported: Set<String> = [
            "strong", "b", "em", "i", "del", "s", "strike", "code", "a",
            "kbd", "mark", "br", "img"
        ]
        guard supported.contains(tag) else { return nil }

        if tag == "br" || tag == "img" {
            let end = input.index(after: openingEnd)
            let fragment = String(input[index..<end])
            let root = SemanticHTML.parseFragment(fragment)
            if tag == "br" { return ([.text("\n")], end) }
            guard let image = SemanticHTML.firstElement(named: "img", in: root),
                  let src = image.attributes["src"],
                  let safe = SemanticHTML.safeURL(src, image: true) else {
                return ([], end)
            }
            return ([.image(alt: SemanticHTML.decodeEntities(image.attributes["alt"] ?? ""), url: safe)], end)
        }

        let contentStart = input.index(after: openingEnd)
        guard let closingStart = input.range(
            of: "</\(tag)",
            options: .caseInsensitive,
            range: contentStart..<input.endIndex
        )?.lowerBound,
              let closingEnd = input[closingStart...].firstIndex(of: ">") else { return nil }
        let end = input.index(after: closingEnd)
        let fragment = String(input[index..<end])
        let root = SemanticHTML.parseFragment(fragment)
        guard let element = SemanticHTML.firstElement(named: tag, in: root) else { return nil }
        let content = SemanticHTML.inlineMarkdown(from: element.children)
        let plain = element.children.map(\.plainText).joined()
        let runs: [InlineRun]
        switch tag {
        case "strong", "b": runs = applying(.bold, to: content)
        case "em", "i": runs = applying(.italic, to: content)
        case "del", "s", "strike": runs = [.strikethrough(plain)]
        case "code": runs = [.code(plain)]
        case "kbd": runs = [.keyboard(plain)]
        case "mark": runs = [.highlight(plain)]
        case "a":
            if let href = element.attributes["href"], let safe = SemanticHTML.safeURL(href, image: false) {
                runs = [.link(label: plain, url: safe)]
            } else {
                runs = [.text(plain)]
            }
        default: return nil
        }
        return (runs, end)
    }

    private enum EmphasisStyle {
        case bold
        case italic
        case boldItalic
    }

    private static func applying(_ style: EmphasisStyle, to content: String) -> [InlineRun] {
        parse(content).map { run in
            switch (style, run) {
            case (.bold, .text(let value)), (.bold, .bold(let value)):
                return .bold(value)
            case (.bold, .italic(let value)), (.bold, .boldItalic(let value)):
                return .boldItalic(value)
            case (.italic, .text(let value)), (.italic, .italic(let value)):
                return .italic(value)
            case (.italic, .bold(let value)), (.italic, .boldItalic(let value)):
                return .boldItalic(value)
            case (.boldItalic, .text(let value)),
                 (.boldItalic, .bold(let value)),
                 (.boldItalic, .italic(let value)),
                 (.boldItalic, .boldItalic(let value)):
                return .boldItalic(value)
            case (_, let unchanged):
                return unchanged
            }
        }
    }

    private static func parseDelimited(
        _ input: String,
        from index: String.Index,
        delimiter: String
    ) -> (content: String, end: String.Index)? {
        guard input[index...].hasPrefix(delimiter),
              let marker = delimiter.first
        else { return nil }
        let contentStart = input.index(index, offsetBy: delimiter.count)
        guard contentStart < input.endIndex,
              isExactDelimiterRun(input, start: index, end: contentStart, marker: marker),
              canOpenDelimiter(input, start: index, end: contentStart, marker: marker)
        else { return nil }

        var searchStart = contentStart
        while searchStart < input.endIndex,
              let closing = input.range(of: delimiter, range: searchStart..<input.endIndex) {
            let nextSearch = input.index(after: closing.lowerBound)
            guard closing.lowerBound > contentStart,
                  isExactDelimiterRun(input, start: closing.lowerBound, end: closing.upperBound, marker: marker),
                  !isEscapedDelimiter(input, at: closing.lowerBound),
                  canCloseDelimiter(input, start: closing.lowerBound, end: closing.upperBound, marker: marker)
            else {
                searchStart = nextSearch
                continue
            }

            let content = String(input[contentStart..<closing.lowerBound])
            if marker == "_", delimiter.count > 1, isDunderIdentifierContent(content) {
                return nil
            }
            return (content, closing.upperBound)
        }
        return nil
    }

    private static func isExactDelimiterRun(
        _ input: String,
        start: String.Index,
        end: String.Index,
        marker: Character
    ) -> Bool {
        let before = start > input.startIndex ? input[input.index(before: start)] : nil
        let after = end < input.endIndex ? input[end] : nil
        return before != marker && after != marker
    }

    private static func canOpenDelimiter(
        _ input: String,
        start: String.Index,
        end: String.Index,
        marker: Character
    ) -> Bool {
        let before = start > input.startIndex ? input[input.index(before: start)] : nil
        let after = end < input.endIndex ? input[end] : nil
        let flanking = delimiterFlanking(before: before, after: after)
        if marker == "_" {
            return flanking.left && (!flanking.right || before.map(isPunctuation) == true)
        }
        if marker == "*", before?.isNumber == true, after?.isNumber == true {
            return false
        }
        return flanking.left
    }

    private static func canCloseDelimiter(
        _ input: String,
        start: String.Index,
        end: String.Index,
        marker: Character
    ) -> Bool {
        let before = start > input.startIndex ? input[input.index(before: start)] : nil
        let after = end < input.endIndex ? input[end] : nil
        let flanking = delimiterFlanking(before: before, after: after)
        if marker == "_" {
            return flanking.right && (!flanking.left || after.map(isPunctuation) == true)
        }
        if marker == "*", before?.isNumber == true, after?.isNumber == true {
            return false
        }
        return flanking.right
    }

    private static func delimiterFlanking(
        before: Character?,
        after: Character?
    ) -> (left: Bool, right: Bool) {
        let beforeIsWhitespace = before?.isWhitespace ?? true
        let afterIsWhitespace = after?.isWhitespace ?? true
        let beforeIsPunctuation = before.map(isPunctuation) ?? false
        let afterIsPunctuation = after.map(isPunctuation) ?? false
        let left = !afterIsWhitespace
            && (!afterIsPunctuation || beforeIsWhitespace || beforeIsPunctuation)
        let right = !beforeIsWhitespace
            && (!beforeIsPunctuation || afterIsWhitespace || afterIsPunctuation)
        return (left, right)
    }

    private static func isEscapedDelimiter(_ input: String, at index: String.Index) -> Bool {
        var cursor = index
        var slashCount = 0
        while cursor > input.startIndex {
            let previous = input.index(before: cursor)
            guard input[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }
        return !slashCount.isMultiple(of: 2)
    }

    private static func isDunderIdentifierContent(_ content: String) -> Bool {
        !content.isEmpty && content.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "_"
        }
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.symbols.contains($0)
        }
    }

    private static func isMarkdownPunctuation(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value
        else { return false }
        return (33...47).contains(value)
            || (58...64).contains(value)
            || (91...96).contains(value)
            || (123...126).contains(value)
    }

    private static func parseImage(_ input: String, from index: String.Index) -> (alt: String, url: String, end: String.Index)? {
        guard input[index...].hasPrefix("!["),
              let bracket = input.range(of: "](", range: index..<input.endIndex),
              let close = input.range(of: ")", range: bracket.upperBound..<input.endIndex)
        else { return nil }
        let altStart = input.index(index, offsetBy: 2)
        let alt = String(input[altStart..<bracket.lowerBound])
        let url = String(input[bracket.upperBound..<close.lowerBound]).split(separator: " ").first.map(String.init) ?? ""
        guard !url.isEmpty else { return nil }
        return (alt, url, close.upperBound)
    }

    private static func parseLink(_ input: String, from index: String.Index) -> (label: String, url: String, end: String.Index)? {
        let location = NSRange(index..<index, in: input).location
        guard let parsed = GFM.inlineLink(in: input, startingAt: location),
              let range = Range(parsed.range, in: input) else { return nil }
        return (parsed.label, parsed.destination, range.upperBound)
    }

    private static func parseUnderline(
        _ input: String,
        from index: String.Index
    ) -> (content: String, end: String.Index)? {
        for tag in ["u", "ins"] {
            let opening = "<\(tag)>"
            let closing = "</\(tag)>"
            guard let openingEnd = input.index(index, offsetBy: opening.count, limitedBy: input.endIndex),
                  String(input[index..<openingEnd]).caseInsensitiveCompare(opening) == .orderedSame,
                  let closingRange = input.range(
                      of: closing,
                      options: .caseInsensitive,
                      range: openingEnd..<input.endIndex
                  ) else { continue }
            let content = String(input[openingEnd..<closingRange.lowerBound])
            guard !content.isEmpty, !content.contains("\n"), !content.contains("\r") else { continue }
            return (content, closingRange.upperBound)
        }
        return nil
    }

    private static func parseScript(
        _ input: String,
        from index: String.Index
    ) -> (content: String, superscript: Bool, end: String.Index)? {
        for (tag, superscript) in [("sub", false), ("sup", true)] {
            let opening = "<\(tag)>"
            let closing = "</\(tag)>"
            guard let openingEnd = input.index(index, offsetBy: opening.count, limitedBy: input.endIndex),
                  String(input[index..<openingEnd]).caseInsensitiveCompare(opening) == .orderedSame,
                  let closingRange = input.range(
                      of: closing,
                      options: .caseInsensitive,
                      range: openingEnd..<input.endIndex
                  ) else { continue }
            let content = String(input[openingEnd..<closingRange.lowerBound])
            guard !content.isEmpty, !content.contains("\n"), !content.contains("\r") else { continue }
            return (content, superscript, closingRange.upperBound)
        }
        return nil
    }

    private static func parseEmoji(_ input: String, from index: String.Index) -> (glyph: String, end: String.Index)? {
        guard input[index] == ":" else { return nil }
        let start = input.index(after: index)
        guard let end = input[start...].firstIndex(of: ":"), end > start else { return nil }
        let name = String(input[start..<end])
        guard let glyph = GFM.emoji(for: name) else { return nil }
        return (glyph, input.index(after: end))
    }
}
