import AppKit
import SwiftUI

struct MarkdownPreviewLayoutMetrics: Equatable {
    var scrollSurfaceSize: CGSize?
    var readingColumnSize: CGSize?
    var contentLeading: CGFloat?
    var tableCells: [MarkdownPreviewTableCellLayout] = []
}

struct MarkdownPreviewTableCellLayout: Equatable {
    var table: Int
    var row: Int
    var column: Int
    var size: CGSize
}

enum MarkdownPreviewTableStyle {
    static func background(dark: Bool, isHeader: Bool) -> Color {
        isHeader ? VGTheme.backgroundSecondary(dark: dark).opacity(0.85) : Color.clear
    }
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
        for cell in next.tableCells {
            value.tableCells.removeAll {
                $0.table == cell.table && $0.row == cell.row && $0.column == cell.column
            }
            value.tableCells.append(cell)
        }
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
        GeometryReader { geometry in
            let paneWidth = max(0, geometry.size.width)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(displayBlocks.enumerated()), id: \.offset) { blockIndex, block in
                        blockView(block, blockIndex: blockIndex)
                    }
                }
                .background {
                    if onLayout != nil {
                        GeometryReader { contentGeometry in
                            Color.clear.preference(
                                key: MarkdownPreviewLayoutPreferenceKey.self,
                                value: MarkdownPreviewLayoutMetrics(
                                    contentLeading: contentGeometry.frame(
                                        in: .named(layoutCoordinateSpace ?? "MarkdownPreviewLayout")
                                    ).minX
                                )
                            )
                        }
                    }
                }
                .padding(.horizontal, VGTheme.documentHorizontalPadding)
                .padding(.bottom, VGTheme.readingBottomPadding)
                .frame(
                    width: VGTheme.readingColumnWidth(paneWidth: paneWidth),
                    alignment: .leading
                )
                .background {
                    if onLayout != nil {
                        GeometryReader { columnGeometry in
                            Color.clear.preference(
                                key: MarkdownPreviewLayoutPreferenceKey.self,
                                value: MarkdownPreviewLayoutMetrics(
                                    readingColumnSize: columnGeometry.size
                                )
                            )
                        }
                    }
                }
                .frame(minWidth: paneWidth, alignment: .leading)
            }
            .frame(width: paneWidth, height: geometry.size.height, alignment: .topLeading)
            .background {
                if onLayout != nil {
                    GeometryReader { scrollGeometry in
                        Color.clear.preference(
                            key: MarkdownPreviewLayoutPreferenceKey.self,
                            value: MarkdownPreviewLayoutMetrics(
                                scrollSurfaceSize: scrollGeometry.size
                            )
                        )
                    }
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

    @ViewBuilder
    private func blockView(_ block: MDBlock, blockIndex: Int) -> some View {
        switch block {
        case .code(let language, let code):
            ZStack(alignment: .topTrailing) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VGTheme.backgroundSecondary(dark: dark).opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if !language.isEmpty {
                    Text(CodeHighlight.displayName(for: language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                }
            }
        case .heading(let level, let text):
            InlineRunsView(text: text, noteTitles: noteTitles, baseURL: baseURL, loadLocalImages: loadLocalImages, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
                .font(headingFont(level))
                .fontWeight(.bold)
                .padding(.top, level <= 1 ? 4 : 10)
        case .alert(let kind, let lines):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: kind.symbol)
                    .foregroundStyle(alertColor(kind))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title).font(.subheadline.weight(.semibold)).foregroundStyle(alertColor(kind))
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        InlineRunsView(text: line, noteTitles: noteTitles, baseURL: baseURL, loadLocalImages: loadLocalImages, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alertColor(kind).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .quote(let lines):
            HStack(alignment: .top, spacing: 12) {
                VGTheme.accent.frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        InlineRunsView(text: line, noteTitles: noteTitles, baseURL: baseURL, loadLocalImages: loadLocalImages, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .table(let rows, let alignments, let hasHeader):
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { col, cell in
                            InlineRunsView(text: cell, noteTitles: noteTitles, baseURL: baseURL, loadLocalImages: loadLocalImages, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
                                .padding(8)
                                .frame(
                                    maxWidth: .infinity,
                                    maxHeight: .infinity,
                                    alignment: alignment(alignments, col)
                                )
                                .background(MarkdownPreviewTableStyle.background(
                                    dark: dark,
                                    isHeader: hasHeader && rowIndex == 0
                                ))
                                .background {
                                    if onLayout != nil {
                                        GeometryReader { cellGeometry in
                                            Color.clear.preference(
                                                key: MarkdownPreviewLayoutPreferenceKey.self,
                                                value: MarkdownPreviewLayoutMetrics(
                                                    tableCells: [
                                                        MarkdownPreviewTableCellLayout(
                                                            table: blockIndex,
                                                            row: rowIndex,
                                                            column: col,
                                                            size: cellGeometry.size
                                                        )
                                                    ]
                                                )
                                            )
                                        }
                                    }
                                }
                                .border(VGTheme.divider(dark: dark), width: 0.5)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .richTable(let table):
            HTMLSpanningTableView(
                table: table,
                noteTitles: noteTitles,
                baseURL: baseURL,
                dark: dark,
                loadRemoteImages: loadRemoteImages,
                onWiki: onWiki
            )
        case .details(let summary, let body, let initiallyOpen):
            HTMLDetailsView(initiallyOpen: initiallyOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(MDBlock.parse(body).enumerated()), id: \.offset) { nestedIndex, block in
                        erasedBlockView(block, blockIndex: blockIndex * 1_000 + nestedIndex)
                    }
                }
                .padding(.leading, 20)
                .padding(.top, 4)
            } label: {
                InlineRunsView(
                    text: summary,
                    noteTitles: noteTitles,
                    baseURL: baseURL,
                    loadRemoteImages: loadRemoteImages,
                    onWiki: onWiki
                )
                .fontWeight(.semibold)
            }
        case .definitionList(let items):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        InlineRunsView(text: item.term, noteTitles: noteTitles, baseURL: baseURL, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
                            .fontWeight(.semibold)
                        ForEach(Array(item.definitions.enumerated()), id: \.offset) { _, definition in
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(MDBlock.parse(definition).enumerated()), id: \.offset) { nestedIndex, block in
                                    erasedBlockView(block, blockIndex: blockIndex * 1_000 + nestedIndex)
                                }
                            }
                                .padding(.leading, 20)
                        }
                    }
                }
            }
        case .rule:
            VGTheme.divider(dark: dark).frame(height: 1).padding(.vertical, 8)
        case .lines(let lines):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            let checked = line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ")
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(VGTheme.accent)
                    .padding(.top, 2)
                InlineRunsView(text: String(line.dropFirst(6)), noteTitles: noteTitles, baseURL: baseURL, loadLocalImages: loadLocalImages, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
            }
        } else if let ordered = line.range(of: #"^\s*\d+\.\s+"#, options: .regularExpression) {
            let marker = String(line[ordered])
            HStack(alignment: .top, spacing: 8) {
                Text(marker.trimmingCharacters(in: .whitespaces))
                    .foregroundStyle(VGTheme.textMuted(dark: dark))
                    .monospacedDigit()
                InlineRunsView(text: String(line[ordered.upperBound...]), noteTitles: noteTitles, baseURL: baseURL, loadLocalImages: loadLocalImages, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
            }
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundStyle(VGTheme.textMuted(dark: dark))
                InlineRunsView(text: String(line.dropFirst(2)), noteTitles: noteTitles, baseURL: baseURL, loadLocalImages: loadLocalImages, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
            }
        } else if line.hasPrefix("![") {
            InlineRunsView(text: line, noteTitles: noteTitles, baseURL: baseURL, loadLocalImages: loadLocalImages, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
        } else {
            InlineRunsView(text: line, noteTitles: noteTitles, baseURL: baseURL, loadLocalImages: loadLocalImages, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
                .lineSpacing(6)
        }
    }

    private func erasedBlockView(_ block: MDBlock, blockIndex: Int) -> AnyView {
        AnyView(blockView(block, blockIndex: blockIndex))
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .largeTitle
        case 2: return .title2
        case 3: return .title2
        default: return .title3
        }
    }

    private func alignment(_ alignments: [GFM.Alignment], _ col: Int) -> Alignment {
        switch alignments.indices.contains(col) ? alignments[col] : .left {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func alertColor(_ kind: GFM.AlertKind) -> Color {
        switch kind {
        case .note: return Color(red: 0.35, green: 0.62, blue: 0.95)
        case .tip: return VGTheme.accent
        case .important: return Color(red: 0.72, green: 0.48, blue: 0.95)
        case .warning: return Color(red: 0.95, green: 0.68, blue: 0.22)
        case .caution: return Color(red: 0.90, green: 0.32, blue: 0.32)
        }
    }
}

private struct HTMLDetailsView<Content: View, Label: View>: View {
    @State private var isExpanded: Bool
    private let content: Content
    private let label: Label

    init(
        initiallyOpen: Bool,
        @ViewBuilder content: () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        _isExpanded = State(initialValue: initiallyOpen)
        self.content = content()
        self.label = label()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            label
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct HTMLSpanningTableView: View {
    let table: GFM.HTMLTable
    let noteTitles: Set<String>
    let baseURL: URL?
    let dark: Bool
    let loadRemoteImages: Bool
    let onWiki: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let caption = table.caption {
                InlineRunsView(
                    text: caption,
                    noteTitles: noteTitles,
                    baseURL: baseURL,
                    loadRemoteImages: loadRemoteImages,
                    onWiki: onWiki
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            SpanningTableLayout(cells: table.cells, columns: table.columnCount, rows: table.rowCount) {
                ForEach(Array(table.cells.enumerated()), id: \.offset) { _, cell in
                    InlineRunsView(
                        text: cell.content,
                        noteTitles: noteTitles,
                        baseURL: baseURL,
                        loadRemoteImages: loadRemoteImages,
                        onWiki: onWiki
                    )
                    .fontWeight(cell.isHeader ? .semibold : .regular)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: swiftUIAlignment(cell.alignment))
                    .background(MarkdownPreviewTableStyle.background(dark: dark, isHeader: cell.isHeader))
                    .border(VGTheme.divider(dark: dark), width: 0.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func swiftUIAlignment(_ alignment: GFM.Alignment) -> Alignment {
        switch alignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

struct SpanningTableLayout: Layout {
    let cells: [GFM.HTMLTableCell]
    let columns: Int
    let rows: Int

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        metrics(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let measurement = metrics(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )
        for index in subviews.indices where cells.indices.contains(index) {
            let cell = cells[index]
            guard let frame = Self.frame(
                for: cell,
                in: bounds,
                columnCount: columns,
                rowHeights: measurement.rowHeights
            ) else { continue }
            subviews[index].place(
                at: frame.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    static func frame(
        for cell: GFM.HTMLTableCell,
        in bounds: CGRect,
        columnCount: Int,
        rowHeights: [CGFloat]
    ) -> CGRect? {
        guard columnCount > 0,
              cell.row >= 0, cell.row < rowHeights.count,
              cell.column >= 0, cell.column < columnCount else { return nil }
        let endRow = min(rowHeights.count, cell.row + max(1, cell.rowSpan))
        let endColumn = min(columnCount, cell.column + max(1, cell.columnSpan))
        let columnWidth = bounds.width / CGFloat(columnCount)
        return CGRect(
            x: bounds.minX + CGFloat(cell.column) * columnWidth,
            y: bounds.minY + rowHeights.prefix(cell.row).reduce(0, +),
            width: CGFloat(endColumn - cell.column) * columnWidth,
            height: rowHeights[cell.row..<endRow].reduce(0, +)
        )
    }

    private func metrics(proposal: ProposedViewSize, subviews: Subviews) -> (
        size: CGSize,
        columnWidth: CGFloat,
        rowHeights: [CGFloat]
    ) {
        guard columns > 0, rows > 0 else { return (.zero, 0, []) }
        let intrinsicWidths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? max($0, 1) : nil }
        let naturalColumnWidth = max(80, (intrinsicWidths.max() ?? 80) + 16)
        let totalWidth = proposedWidth ?? naturalColumnWidth * CGFloat(columns)
        let columnWidth = totalWidth / CGFloat(columns)
        var rowHeights = Array(repeating: CGFloat(0), count: rows)

        for index in subviews.indices where cells.indices.contains(index) {
            let cell = cells[index]
            guard cell.row < rows else { continue }
            let width = columnWidth * CGFloat(cell.columnSpan)
            let height = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            if cell.rowSpan == 1 {
                rowHeights[cell.row] = max(rowHeights[cell.row], height)
            }
        }
        for index in subviews.indices where cells.indices.contains(index) {
            let cell = cells[index]
            guard cell.row < rows, cell.rowSpan > 1 else { continue }
            let end = min(rows, cell.row + cell.rowSpan)
            let width = columnWidth * CGFloat(cell.columnSpan)
            let required = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            let current = rowHeights[cell.row..<end].reduce(0, +)
            if required > current {
                let addition = (required - current) / CGFloat(end - cell.row)
                for row in cell.row..<end { rowHeights[row] += addition }
            }
        }
        rowHeights = rowHeights.map { max($0, 34) }
        return (CGSize(width: totalWidth, height: rowHeights.reduce(0, +)), columnWidth, rowHeights)
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

enum InlineRun: Identifiable, Equatable {
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

    var id: String {
        switch self {
        case .text(let value): return "t-\(value)"
        case .bold(let value): return "b-\(value)"
        case .italic(let value): return "it-\(value)"
        case .boldItalic(let value): return "bi-\(value)"
        case .strikethrough(let value): return "s-\(value)"
        case .underline(let value): return "u-\(value)"
        case .subscriptText(let value): return "sub-\(value)"
        case .superscriptText(let value): return "sup-\(value)"
        case .keyboard(let value): return "kbd-\(value)"
        case .highlight(let value): return "mark-\(value)"
        case .wiki(let target, let label): return "w-\(target)-\(label)"
        case .tag(let value): return "g-\(value)"
        case .link(let label, let url): return "l-\(label)-\(url)"
        case .code(let value): return "c-\(value)"
        case .footnote(let value): return "f-\(value)"
        case .emoji(let value): return "e-\(value)"
        case .image(let alt, let url): return "i-\(alt)-\(url)"
        }
    }
}

enum InlineRunGroup: Equatable {
    case text([InlineRun])
    case element(InlineRun)
}

struct InlineRunsView: View {
    let text: String
    let noteTitles: Set<String>
    var baseURL: URL? = nil
    var loadLocalImages = true
    var loadRemoteImages = false
    var onWiki: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(layoutGroups.enumerated()), id: \.offset) { _, group in
                switch group {
                case .text(let textRuns):
                    Self.composedText(textRuns)
                case .element(let run):
                    standaloneView(run)
                }
            }
        }
    }

    private var runs: [InlineRun] {
        Self.parse(text)
    }

    private var layoutGroups: [InlineRunGroup] {
        Self.layoutGroups(for: runs)
    }

    @ViewBuilder
    private func standaloneView(_ run: InlineRun) -> some View {
        switch run {
        case .wiki(let target, let label):
            let exists = noteTitles.contains(target.lowercased())
            Button(label) { onWiki(target) }
                .buttonStyle(.plain)
                .foregroundStyle(exists ? VGTheme.textAccent : VGTheme.textAccent.opacity(0.55))
                .underline(exists)
        case .tag(let tag):
            Text("#\(tag)")
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(VGTheme.accent.opacity(0.22))
                .foregroundStyle(VGTheme.textAccent)
                .clipShape(Capsule())
        case .link(let label, let url):
            if url.hasPrefix("wiki://") {
                let target = String(url.dropFirst(7)).removingPercentEncoding ?? url
                Button(label) { onWiki(target) }
                    .buttonStyle(.plain)
                    .foregroundStyle(VGTheme.textAccent)
                    .underline()
            } else if let destination = MarkdownResourceResolver.linkURL(url, relativeTo: baseURL) {
                Link(label, destination: destination)
                    .foregroundStyle(VGTheme.textAccent)
                    .underline()
            } else {
                Text(label)
            }
        case .code(let value):
            Text(value)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 4)
                .background(Color.gray.opacity(0.18))
        case .keyboard(let value):
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.35)))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case .highlight(let value):
            Text(value)
                .padding(.horizontal, 2)
                .background(Color.yellow.opacity(0.38))
        case .footnote(let value):
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(VGTheme.textAccent)
                .baselineOffset(4)
        case .image(let alt, let url):
            MarkdownImageView(
                alt: alt,
                rawURL: url,
                baseURL: baseURL,
                loadLocalImages: loadLocalImages,
                loadRemoteImages: loadRemoteImages
            )
        case .text, .bold, .italic, .boldItalic, .strikethrough, .underline,
             .subscriptText, .superscriptText, .emoji:
            Self.composedText([run])
        }
    }

    static func layoutGroups(for runs: [InlineRun]) -> [InlineRunGroup] {
        var result: [InlineRunGroup] = []
        var textRuns: [InlineRun] = []

        func flushText() {
            guard !textRuns.isEmpty else { return }
            result.append(.text(textRuns))
            textRuns.removeAll(keepingCapacity: true)
        }

        for run in runs {
            switch run {
            case .text, .bold, .italic, .boldItalic, .strikethrough, .underline,
                 .subscriptText, .superscriptText, .emoji:
                textRuns.append(run)
            case .wiki, .tag, .link, .code, .footnote, .image, .keyboard, .highlight:
                flushText()
                result.append(.element(run))
            }
        }
        flushText()
        return result
    }

    private static func composedText(_ runs: [InlineRun]) -> Text {
        runs.reduce(Text("")) { partial, run in
            partial + styledText(run)
        }
    }

    private static func styledText(_ run: InlineRun) -> Text {
        switch run {
        case .text(let value), .emoji(let value):
            return Text(value)
        case .bold(let value):
            return Text(value).bold()
        case .italic(let value):
            return Text(value).italic()
        case .boldItalic(let value):
            return Text(value).bold().italic()
        case .strikethrough(let value):
            return Text(value).strikethrough()
        case .underline(let value):
            return Text(value).underline()
        case .subscriptText(let value):
            return Text(value).font(.system(size: 11)).baselineOffset(-3)
        case .superscriptText(let value):
            return Text(value).font(.system(size: 11)).baselineOffset(5)
        case .wiki, .tag, .link, .code, .footnote, .image, .keyboard, .highlight:
            return Text("")
        }
    }

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

private struct MarkdownImageView: View {
    let alt: String
    let rawURL: String
    let baseURL: URL?
    let loadLocalImages: Bool
    let loadRemoteImages: Bool
    @State private var image: NSImage?

    private var resolvedURL: URL? {
        MarkdownResourceResolver.imageURL(rawURL, relativeTo: baseURL)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
            } else {
                Text(placeholder)
                    .italic()
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: taskIdentity) {
            image = nil
            guard let url = resolvedURL else {
                return
            }
            let data: Data?
            if url.isFileURL, loadLocalImages {
                data = await Task.detached(priority: .utility) {
                    try? Data(contentsOf: url, options: .mappedIfSafe)
                }.value
            } else if MarkdownResourceResolver.mayLoadImage(
                url,
                loadLocalImages: loadLocalImages,
                loadRemoteImages: loadRemoteImages
            ) {
                data = try? await RemoteImageLoader.data(from: url)
            } else {
                data = nil
            }
            guard !Task.isCancelled, let data, let decoded = NSImage(data: data) else {
                return
            }
            image = decoded
        }
    }

    private var taskIdentity: String {
        "\(resolvedURL?.absoluteString ?? rawURL)|\(loadLocalImages)|\(loadRemoteImages)"
    }

    private var placeholder: String {
        MarkdownResourceResolver.imagePlaceholder(
            alt: alt,
            resolvedURL: resolvedURL,
            loadLocalImages: loadLocalImages,
            loadRemoteImages: loadRemoteImages
        )
    }
}

/// Wraps chips and text like Obsidian's inline tags and links.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).0
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews).1
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (CGSize, [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight), frames)
    }
}
