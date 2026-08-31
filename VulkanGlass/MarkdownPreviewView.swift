import AppKit
import SwiftUI

struct MarkdownPreviewLayoutMetrics: Equatable {
    var scrollSurfaceSize: CGSize?
    var readingColumnSize: CGSize?
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
    var loadRemoteImages = false
    var onLayout: ((MarkdownPreviewLayoutMetrics) -> Void)? = nil
    var onWiki: (String) -> Void

    var body: some View {
        GeometryReader { geometry in
            let paneWidth = max(0, geometry.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(displayBlocks.enumerated()), id: \.offset) { blockIndex, block in
                        blockView(block, blockIndex: blockIndex)
                    }
                }
                .padding(.horizontal, VGTheme.readingHorizontalPadding)
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
        .onPreferenceChange(MarkdownPreviewLayoutPreferenceKey.self) { metrics in
            guard metrics.scrollSurfaceSize != nil, metrics.readingColumnSize != nil else { return }
            onLayout?(metrics)
        }
    }

    private var displayBlocks: [MDBlock] {
        var items = MDBlock.parse(text)
        if case .heading(1, _) = items.first {
            items.removeFirst()
        }
        return items
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
            InlineRunsView(text: text, noteTitles: noteTitles, baseURL: baseURL, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
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
                        InlineRunsView(text: line, noteTitles: noteTitles, baseURL: baseURL, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
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
                        InlineRunsView(text: line, noteTitles: noteTitles, baseURL: baseURL, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .table(let rows, let alignments, let hasHeader):
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { col, cell in
                            InlineRunsView(text: cell, noteTitles: noteTitles, baseURL: baseURL, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
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
                InlineRunsView(text: String(line.dropFirst(6)), noteTitles: noteTitles, baseURL: baseURL, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
            }
        } else if let ordered = line.range(of: #"^\s*\d+\.\s+"#, options: .regularExpression) {
            let marker = String(line[ordered])
            HStack(alignment: .top, spacing: 8) {
                Text(marker.trimmingCharacters(in: .whitespaces))
                    .foregroundStyle(VGTheme.textMuted(dark: dark))
                    .monospacedDigit()
                InlineRunsView(text: String(line[ordered.upperBound...]), noteTitles: noteTitles, baseURL: baseURL, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
            }
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundStyle(VGTheme.textMuted(dark: dark))
                InlineRunsView(text: String(line.dropFirst(2)), noteTitles: noteTitles, baseURL: baseURL, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
            }
        } else if line.hasPrefix("![") {
            InlineRunsView(text: line, noteTitles: noteTitles, baseURL: baseURL, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
        } else {
            InlineRunsView(text: line, noteTitles: noteTitles, baseURL: baseURL, loadRemoteImages: loadRemoteImages, onWiki: onWiki)
                .lineSpacing(6)
        }
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

enum MDBlock: Equatable {
    case code(language: String, code: String)
    case heading(Int, String)
    case quote([String])
    case alert(GFM.AlertKind, [String])
    case table([[String]], [GFM.Alignment], hasHeader: Bool)
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
            if line.hasPrefix("```") {
                var buffer = [line]
                var closed = false
                i += 1
                while i < raw.count {
                    buffer.append(raw[i])
                    if raw[i].hasPrefix("```") {
                        closed = true
                        i += 1
                        break
                    }
                    i += 1
                }
                let language = String(buffer[0].dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let content = closed ? buffer.dropFirst().dropLast() : buffer.dropFirst()[...]
                let code = content.joined(separator: "\n")
                result.append(.code(language: language, code: code))
                continue
            }
            if isHTMLTableStartLine(line) {
                var htmlLines: [String] = []
                var cursor = i
                var foundEnd = false
                while cursor < raw.count {
                    let candidate = raw[cursor]
                    if cursor > i {
                        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty || trimmed.hasPrefix("```") {
                            break
                        }
                    }
                    htmlLines.append(candidate)
                    cursor += 1
                    if isHTMLTableEndLine(candidate) {
                        foundEnd = true
                        break
                    }
                }
                if foundEnd, let table = GFM.parseHTMLTable(htmlLines.joined(separator: "\n")) {
                    let columns = table.rows.first?.count ?? 0
                    result.append(.table(
                        table.rows,
                        Array(repeating: .left, count: columns),
                        hasHeader: table.hasHeader
                    ))
                    i = cursor
                    continue
                }
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
                if !lines.isEmpty, isHTMLTableStartLine(current) { break }
                lines.append(current)
                i += 1
            }
            if !lines.isEmpty { result.append(.lines(lines)) }
        }
        return result
    }

    private static func isHTMLTableStartLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"^<table(?:\s+[^>]*)?>$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isHTMLTableEndLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).range(
            of: #"^</table\s*>$"#,
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
                loadRemoteImages: loadRemoteImages
            )
        case .text, .bold, .italic, .boldItalic, .strikethrough, .emoji:
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
            case .text, .bold, .italic, .boldItalic, .strikethrough, .emoji:
                textRuns.append(run)
            case .wiki, .tag, .link, .code, .footnote, .image:
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
        case .wiki, .tag, .link, .code, .footnote, .image:
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
        guard input[index] == "[",
              let bracket = input.range(of: "](", range: index..<input.endIndex),
              let close = input.range(of: ")", range: bracket.upperBound..<input.endIndex)
        else { return nil }
        let label = String(input[input.index(after: index)..<bracket.lowerBound])
        let url = String(input[bracket.upperBound..<close.lowerBound])
        guard !label.isEmpty, !url.isEmpty else { return nil }
        return (label, url, close.upperBound)
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
            if url.isFileURL {
                data = await Task.detached(priority: .utility) {
                    try? Data(contentsOf: url, options: .mappedIfSafe)
                }.value
            } else if MarkdownResourceResolver.mayLoadImage(url, loadRemoteImages: loadRemoteImages) {
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
        "\(resolvedURL?.absoluteString ?? rawURL)|\(loadRemoteImages)"
    }

    private var placeholder: String {
        guard let url = resolvedURL, !url.isFileURL, !loadRemoteImages else { return alt }
        return alt.isEmpty ? "Remote image blocked" : "\(alt) (remote image blocked)"
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
