import AppKit
import Foundation

/// Obsidian-style live preview: render markup, reveal delimiters only while the caret is inside.
enum LivePreview {
    struct Token: Equatable {
        var fullRange: NSRange
        var delimiterRanges: [NSRange]
        var kind: Kind

        enum Kind: Equatable {
            case heading(level: Int)
            case wikiLink
            case markdownLink
            case tag
            case bold
            case italic
            case inlineCode
            case strikethrough
            case list
            case taskList(checked: Bool)
            case orderedList
            case blockquote
            case codeBlock(language: String, content: NSRange)
            case image(url: String)
            case autolink
            case footnoteRef
            case footnoteDef
            case alert(GFM.AlertKind)
            case tableRow(isHeader: Bool)
            case tableSeparator
            case horizontalRule
            case htmlComment
            case subscriptText
            case superscriptText
            case underline
            case emoji(String)
            case escape
            case boldItalic
        }

        func containsCaret(_ caret: Int) -> Bool {
            caret >= fullRange.location && caret <= fullRange.location + fullRange.length
        }
    }

    struct CodeBlockDecoration: Equatable {
        var range: NSRange
        var language: String
        var showBadge: Bool
        var dark: Bool
    }

    struct TableDecoration: Equatable {
        var range: NSRange
        var rows: [TableRowDecoration]
        var separatorRange: NSRange
        var separatorVisible: Bool
        var columnWidths: [CGFloat]
        var dark: Bool
    }

    struct TableRowDecoration: Equatable {
        var range: NSRange
        var cellRanges: [NSRange]
        var pipeRanges: [NSRange]
        var isHeader: Bool
        var hasLeadingPipe: Bool
        var hasTrailingPipe: Bool
    }

    struct BlockBarDecoration: Equatable {
        var range: NSRange
        var dark: Bool
        var kind: BarKind
        var collapsed: Bool

        enum BarKind: Equatable {
            case quote
            case alert(GFM.AlertKind)
            case rule
        }
    }

    struct ImageDecoration: Equatable {
        var range: NSRange
        var url: String
        var collapsed: Bool
        var dark: Bool
    }

    struct EmojiDecoration: Equatable {
        var range: NSRange
        var emoji: String
    }

    struct Decorations: Equatable {
        var codeBlocks: [CodeBlockDecoration] = []
        var tables: [TableDecoration] = []
        var bars: [BlockBarDecoration] = []
        var images: [ImageDecoration] = []
        var emojis: [EmojiDecoration] = []
    }

    private enum Regex {
        static let fence = try! NSRegularExpression(pattern: "^(```+)[^\\n]*", options: .anchorsMatchLines)
        static let heading = try! NSRegularExpression(pattern: "^(#{1,6})[ \\t]+")
        static let taskList = try! NSRegularExpression(pattern: #"^(\s*)([-*+])[ \t]+\[([ xX])\][ \t]+"#)
        static let list = try! NSRegularExpression(pattern: #"^(\s*)([-*+])[ \t]+"#)
        static let blockquote = try! NSRegularExpression(pattern: #"^(> ?)"#)
        static let orderedList = try! NSRegularExpression(pattern: #"^(\s*)(\d{1,9}\.)[ \t]+"#)
        static let footnoteDefinition = try! NSRegularExpression(pattern: #"^\[\^([^\]]+)\]:"#)
        static let htmlComment = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)
        static let escape = try! NSRegularExpression(pattern: #"\\([\\`*_{}\[\]()#+\-.!|~>])"#)
        static let wiki = try! NSRegularExpression(pattern: #"\[\[([^\]|#\r\n]+)(?:#[^\]|\r\n]+)?(?:\|([^\]\r\n]+))?\]\]"#)
        static let image = try! NSRegularExpression(pattern: #"!\[([^\]\r\n]*)\]\(([^)\s]+)(?:\s+\"[^\"\r\n]*\")?\)"#)
        static let footnoteReference = try! NSRegularExpression(pattern: #"\[\^([^\]\r\n]+)\](?!:)"#)
        static let inlineCode = try! NSRegularExpression(pattern: #"`([^`\r\n]+)`"#)
        static let angleLink = try! NSRegularExpression(pattern: #"<(https?://[^>\s]+|mailto:[^>\s]+)>"#)
        static let bareURL = try! NSRegularExpression(pattern: #"https?://[^\s<]+[^\s<.,:;!?)\]]"#)
        static let subscriptText = try! NSRegularExpression(pattern: #"<sub>([^\r\n]+?)</sub>"#, options: .caseInsensitive)
        static let superscriptText = try! NSRegularExpression(pattern: #"<sup>([^\r\n]+?)</sup>"#, options: .caseInsensitive)
        static let underline = try! NSRegularExpression(pattern: #"<(ins|u)>([^\r\n]+?)</\1>"#, options: .caseInsensitive)
        static let emoji = try! NSRegularExpression(pattern: #":([a-z0-9_+-]+):"#)
        static let strike = try! NSRegularExpression(pattern: #"~~([^~\r\n]+)~~"#)
        static let strikeOnce = try! NSRegularExpression(pattern: #"(?<!~)~([^~\r\n]+)~(?!~)"#)
        static let boldItalic = try! NSRegularExpression(pattern: #"\*\*\*([^*\r\n]+)\*\*\*|(?<![\w_])___([^_\r\n]+)___(?![\w_])"#)
        static let bold = try! NSRegularExpression(pattern: #"\*\*([^*\r\n]+)\*\*|(?<![\w_])__([^_\r\n]+)__(?![\w_])"#)
        static let italic = try! NSRegularExpression(pattern: #"(?<!\*)\*([^*\r\n]+)\*(?!\*)|(?<![\w_])_([^_\r\n]+)_(?![\w_])"#)
        static let tag = try! NSRegularExpression(pattern: #"(^|[\s])(#[A-Za-z][\w/-]*)"#, options: .anchorsMatchLines)
    }

    static func tokens(in text: String) -> [Token] {
        let ns = text as NSString
        let blocks = fencedBlocks(in: ns)
        var skip = blocks.map(\.fullRange)
        var result: [Token] = blocks.map { block in
            Token(
                fullRange: block.fullRange,
                delimiterRanges: block.delimiterRanges,
                kind: .codeBlock(language: block.language, content: block.contentRange)
            )
        }

        for comment in htmlCommentTokens(in: ns) where !blocks.contains(where: {
            NSIntersectionRange($0.fullRange, comment.fullRange).length > 0
        }) {
            result.append(comment)
            skip.append(comment.fullRange)
        }
        for table in tableBlocks(in: ns, skipping: skip) {
            result.append(contentsOf: tokens(for: table, in: ns))
            skip.append(table.fullRange)
        }
        for alert in alertBlocks(in: ns, skipping: skip) {
            result.append(contentsOf: tokens(for: alert, in: ns))
            skip.append(alert.fullRange)
        }

        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            if skip.contains(where: { NSIntersectionRange($0, lineRange).length == lineRange.length }) {
                return
            }
            result.append(contentsOf: lineTokens(in: ns, lineRange: lineRange, fences: skip))
        }
        return result
    }

    @discardableResult
    static func apply(
        to storage: NSTextStorage,
        caret: Int,
        selection: NSRange,
        dark: Bool,
        maximumTableWidth: CGFloat? = nil,
        tokens suppliedTokens: [Token]? = nil
    ) -> Decorations {
        let text = storage.string
        let all = NSRange(location: 0, length: storage.length)
        guard all.length > 0 else { return Decorations() }
        let bodyFont = NSFont.systemFont(ofSize: 16)
        let baseColor = textColor(dark: dark)
        storage.beginEditing()
        storage.setAttributes(
            [
                .font: bodyFont,
                .foregroundColor: baseColor,
                .kern: 0,
                .underlineStyle: 0,
                .backgroundColor: NSColor.clear,
                .obliqueness: 0,
                .baselineOffset: 0,
                .strikethroughStyle: 0,
                .paragraphStyle: NSParagraphStyle.default
            ],
            range: all
        )

        let found = suppliedTokens ?? tokens(in: text)
        for token in found {
            if let attrs = contentAttributes(for: token.kind, dark: dark) {
                let range: NSRange
                if case .codeBlock(_, let content) = token.kind, content.length > 0 {
                    range = content
                } else {
                    range = token.fullRange
                }
                if range.length > 0, NSMaxRange(range) <= storage.length {
                    storage.addAttributes(attrs, range: range)
                }
            }
            if case .codeBlock(let language, let content) = token.kind, content.length > 0 {
                let code = (text as NSString).substring(with: content)
                for (span, kind) in CodeHighlight.spans(in: code, language: language) {
                    let absolute = NSRange(location: content.location + span.location, length: span.length)
                    guard NSMaxRange(absolute) <= storage.length else { continue }
                    storage.addAttributes(
                        [
                            .foregroundColor: CodeHighlight.color(for: kind, dark: dark),
                            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
                        ],
                        range: absolute
                    )
                }
            }
        }

        var decorations = Decorations()
        decorations.tables = tableDecorations(
            from: found,
            text: text,
            caret: caret,
            selection: selection,
            dark: dark,
            maximumWidth: maximumTableWidth
        )
        decorations.bars = alertDecorations(from: found, text: text, caret: caret, selection: selection, dark: dark)

        for token in found {
            let active = token.containsCaret(caret) || NSIntersectionRange(selection, token.fullRange).length > 0
            let font = contentFont(for: token.kind)
            switch token.kind {
            case .codeBlock(let language, let content):
                for (index, range) in token.delimiterRanges.enumerated() where range.length > 0 && NSMaxRange(range) <= storage.length {
                    let reserve = !active && index == 0 && !language.isEmpty ? CGFloat(18) : 0
                    storage.addAttributes(
                        delimiterAttributes(visible: active, font: font, dark: dark, reservedHeight: reserve),
                        range: range
                    )
                }
                let ns = text as NSString
                let trimmedContent = trimTrailingNewlines(content, in: ns)
                let boxRange: NSRange
                if active {
                    boxRange = token.fullRange
                } else if !language.isEmpty, let open = token.delimiterRanges.first {
                    let end = trimmedContent.length > 0 ? NSMaxRange(trimmedContent) : NSMaxRange(open)
                    boxRange = NSRange(location: open.location, length: max(0, end - open.location))
                } else if trimmedContent.length > 0 {
                    boxRange = trimmedContent
                } else {
                    boxRange = token.fullRange
                }
                decorations.codeBlocks.append(
                    CodeBlockDecoration(
                        range: boxRange.length > 0 ? boxRange : token.fullRange,
                        language: language,
                        showBadge: !active && !language.isEmpty,
                        dark: dark
                    )
                )
            case .tableSeparator:
                if token.fullRange.length > 0 {
                    storage.addAttributes(
                        delimiterAttributes(visible: active, font: font, dark: dark),
                        range: token.fullRange
                    )
                }
            case .tableRow:
                // Table source is structural, not editing chrome. Keep pipes hidden even
                // while the caret is inside a cell, as in Obsidian's live table editor.
                for range in token.delimiterRanges where range.length > 0 && NSMaxRange(range) <= storage.length {
                    storage.addAttributes(
                        delimiterAttributes(visible: false, font: font, dark: dark, keepWidth: true),
                        range: range
                    )
                }
            case .emoji(let glyph):
                if token.fullRange.length > 0 {
                    let first = NSRange(location: token.fullRange.location, length: 1)
                    let rest = NSRange(location: token.fullRange.location + 1, length: token.fullRange.length - 1)
                    if active {
                        storage.addAttributes(delimiterAttributes(visible: true, font: font, dark: dark), range: token.fullRange)
                    } else {
                        storage.addAttributes(
                            [
                                .font: NSFont.systemFont(ofSize: 18),
                                .foregroundColor: NSColor.clear
                            ],
                            range: first
                        )
                        if rest.length > 0 {
                            storage.addAttributes(delimiterAttributes(visible: false, font: font, dark: dark), range: rest)
                        }
                        decorations.emojis.append(EmojiDecoration(range: first, emoji: glyph))
                    }
                }
            case .image(let url):
                let reserve = !active ? CGFloat(148) : 0
                for range in token.delimiterRanges where range.length > 0 && NSMaxRange(range) <= storage.length {
                    storage.addAttributes(
                        delimiterAttributes(visible: active, font: font, dark: dark, reservedHeight: reserve),
                        range: range
                    )
                }
                decorations.images.append(
                    ImageDecoration(range: token.fullRange, url: url, collapsed: !active, dark: dark)
                )
            case .horizontalRule:
                storage.addAttributes(
                    delimiterAttributes(visible: active, font: font, dark: dark, reservedHeight: active ? 0 : 14),
                    range: token.fullRange
                )
                if !active {
                    decorations.bars.append(BlockBarDecoration(range: token.fullRange, dark: dark, kind: .rule, collapsed: true))
                }
            case .htmlComment, .escape:
                for range in token.delimiterRanges where range.length > 0 && NSMaxRange(range) <= storage.length {
                    storage.addAttributes(delimiterAttributes(visible: active, font: font, dark: dark), range: range)
                }
            case .blockquote:
                for range in token.delimiterRanges where range.length > 0 && NSMaxRange(range) <= storage.length {
                    storage.addAttributes(delimiterAttributes(visible: active, font: font, dark: dark), range: range)
                }
                decorations.bars.append(BlockBarDecoration(range: token.fullRange, dark: dark, kind: .quote, collapsed: !active))
            case .alert(let kind):
                for range in token.delimiterRanges where range.length > 0 && NSMaxRange(range) <= storage.length {
                    let isMarker = range == token.fullRange
                    let reserve = !active && isMarker && !kind.title.isEmpty ? CGFloat(22) : 0
                    storage.addAttributes(
                        delimiterAttributes(visible: active, font: font, dark: dark, reservedHeight: reserve),
                        range: range
                    )
                }
            case .list, .taskList:
                for range in token.delimiterRanges where range.length > 0 && NSMaxRange(range) <= storage.length {
                    storage.addAttributes(delimiterAttributes(visible: true, font: font, dark: dark), range: range)
                }
            default:
                for range in token.delimiterRanges where range.length > 0 && NSMaxRange(range) <= storage.length {
                    storage.addAttributes(delimiterAttributes(visible: active, font: font, dark: dark), range: range)
                }
            }
        }
        styleTables(decorations.tables, in: storage)
        storage.endEditing()
        return decorations
    }

    private static func tableDecorations(
        from tokens: [Token],
        text: String,
        caret: Int,
        selection: NSRange,
        dark: Bool,
        maximumWidth: CGFloat?
    ) -> [TableDecoration] {
        let rows = tokens.filter {
            if case .tableRow = $0.kind { return true }
            return $0.kind == .tableSeparator
        }.sorted { $0.fullRange.location < $1.fullRange.location }
        return groupedAdjacent(rows, text: text).map { group in
            let range = group.dropFirst().reduce(group[0].fullRange) { NSUnionRange($0, $1.fullRange) }
            let source = text as NSString
            let visibleRows = group.compactMap { token -> TableRowDecoration? in
                guard case .tableRow(let isHeader) = token.kind else { return nil }
                return tableRowDecoration(for: token, isHeader: isHeader, in: source)
            }
            let separator = group.first { $0.kind == .tableSeparator }?.fullRange ?? NSRange(location: range.location, length: 0)
            let separatorVisible = caret >= separator.location && caret <= NSMaxRange(separator)
                || NSIntersectionRange(selection, separator).length > 0
            let columns = visibleRows.map(\.cellRanges.count).max() ?? 0
            let desiredWidths = (0..<columns).map { column -> CGFloat in
                let measured = visibleRows.compactMap { row -> CGFloat? in
                    guard row.cellRanges.indices.contains(column) else { return nil }
                    let raw = source.substring(with: row.cellRanges[column])
                        .trimmingCharacters(in: .whitespaces)
                    let font = NSFont.systemFont(ofSize: 16)
                    return (raw as NSString).size(withAttributes: [.font: font]).width
                }.max() ?? 0
                return min(260, max(112, ceil(measured + 32)))
            }
            let widths = fittedTableWidths(desiredWidths, maximumWidth: maximumWidth)
            return TableDecoration(
                range: range,
                rows: visibleRows,
                separatorRange: separator,
                separatorVisible: separatorVisible,
                columnWidths: widths,
                dark: dark
            )
        }
    }

    private static func fittedTableWidths(_ widths: [CGFloat], maximumWidth: CGFloat?) -> [CGFloat] {
        guard let maximumWidth, maximumWidth > 0 else { return widths }
        let total = widths.reduce(0, +)
        guard total > maximumWidth, total > 0 else { return widths }
        let scale = maximumWidth / total
        return widths.map { $0 * scale }
    }

    private static func tableRowDecoration(
        for token: Token,
        isHeader: Bool,
        in text: NSString
    ) -> TableRowDecoration {
        let line = text.substring(with: token.fullRange) as NSString
        let localPipes = token.delimiterRanges.map { $0.location - token.fullRange.location }
        var firstText = 0
        while firstText < line.length, isWhitespace(line.character(at: firstText)) {
            firstText += 1
        }
        var lastText = line.length
        while lastText > firstText, isWhitespace(line.character(at: lastText - 1)) {
            lastText -= 1
        }
        let hasLeadingPipe = localPipes.first == firstText
        let hasTrailingPipe = localPipes.last == lastText - 1
        var separators = localPipes
        if hasLeadingPipe, !separators.isEmpty { separators.removeFirst() }
        if hasTrailingPipe, !separators.isEmpty { separators.removeLast() }

        var starts = [hasLeadingPipe ? firstText + 1 : firstText]
        starts.append(contentsOf: separators.map { $0 + 1 })
        var ends = separators
        ends.append(hasTrailingPipe ? lastText - 1 : lastText)
        let cells = zip(starts, ends).map { start, end in
            return NSRange(
                location: token.fullRange.location + start,
                length: max(0, end - start)
            )
        }
        return TableRowDecoration(
            range: token.fullRange,
            cellRanges: cells,
            pipeRanges: token.delimiterRanges,
            isHeader: isHeader,
            hasLeadingPipe: hasLeadingPipe,
            hasTrailingPipe: hasTrailingPipe
        )
    }

    private static func isWhitespace(_ utf16: unichar) -> Bool {
        guard let scalar = UnicodeScalar(utf16) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func styleTables(
        _ tables: [TableDecoration],
        in storage: NSTextStorage
    ) {
        for table in tables {
            if !table.separatorVisible,
               table.separatorRange.length > 0,
               NSMaxRange(table.separatorRange) <= storage.length {
                let hiddenLine = NSMutableParagraphStyle()
                hiddenLine.minimumLineHeight = 0.01
                hiddenLine.maximumLineHeight = 0.01
                storage.addAttributes(
                    [
                        .font: NSFont.systemFont(ofSize: 0.01),
                        .foregroundColor: NSColor.clear,
                        .kern: 0,
                        .paragraphStyle: hiddenLine
                    ],
                    range: table.separatorRange
                )
            }

            for row in table.rows {
                guard row.range.length > 0, NSMaxRange(row.range) <= storage.length else { continue }
                let rowStyle = NSMutableParagraphStyle()
                rowStyle.alignment = .left
                rowStyle.firstLineHeadIndent = 12
                rowStyle.headIndent = 12
                rowStyle.minimumLineHeight = 38
                rowStyle.maximumLineHeight = 38
                storage.addAttribute(.paragraphStyle, value: rowStyle, range: row.range)

                let bodyFont = NSFont.systemFont(ofSize: 16)
                let fontHeight = ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading)
                let baselineOffset = floor((38 - fontHeight) / 2)
                for cell in row.cellRanges where cell.length > 0 && NSMaxRange(cell) <= storage.length {
                    addBaselineOffset(baselineOffset, in: cell, storage: storage)
                    for whitespace in boundaryWhitespaceRanges(in: cell, text: storage.string as NSString) {
                        storage.addAttributes(
                            [
                                .font: NSFont.systemFont(ofSize: 0.01),
                                .foregroundColor: NSColor.clear,
                                .kern: 0,
                                .baselineOffset: 0
                            ],
                            range: whitespace
                        )
                    }
                }

                for (index, pipe) in row.pipeRanges.enumerated() where NSMaxRange(pipe) <= storage.length {
                    let isLeading = row.hasLeadingPipe && index == 0
                    let cellIndex = row.hasLeadingPipe ? index - 1 : index
                    let advance: CGFloat
                    if isLeading {
                        advance = 0
                    } else if row.cellRanges.indices.contains(cellIndex), table.columnWidths.indices.contains(cellIndex) {
                        let cellWidth = storage.attributedSubstring(from: row.cellRanges[cellIndex]).size().width
                        let isTrailing = row.hasTrailingPipe && index == row.pipeRanges.count - 1
                        let trailingAdjustment: CGFloat = isTrailing ? 12 : 0
                        advance = max(0, table.columnWidths[cellIndex] - cellWidth - trailingAdjustment)
                    } else {
                        advance = 0
                    }
                    storage.addAttributes(
                        [
                            .font: NSFont.systemFont(ofSize: 0.01),
                            .foregroundColor: NSColor.clear,
                            .kern: advance,
                            .underlineStyle: 0,
                            .strikethroughStyle: 0,
                            .backgroundColor: NSColor.clear
                        ],
                        range: pipe
                    )
                }
            }
        }
    }

    private static func addBaselineOffset(
        _ offset: CGFloat,
        in range: NSRange,
        storage: NSTextStorage
    ) {
        var runs: [(range: NSRange, offset: CGFloat)] = []
        storage.enumerateAttribute(.baselineOffset, in: range) { value, effectiveRange, _ in
            let existing = (value as? NSNumber).map(CGFloat.init(truncating:)) ?? 0
            runs.append((effectiveRange, existing))
        }
        for run in runs {
            storage.addAttribute(.baselineOffset, value: run.offset + offset, range: run.range)
        }
    }

    private static func boundaryWhitespaceRanges(in range: NSRange, text: NSString) -> [NSRange] {
        var contentStart = range.location
        let cellEnd = NSMaxRange(range)
        while contentStart < cellEnd, isWhitespace(text.character(at: contentStart)) {
            contentStart += 1
        }

        var contentEnd = cellEnd
        while contentEnd > contentStart, isWhitespace(text.character(at: contentEnd - 1)) {
            contentEnd -= 1
        }

        var ranges: [NSRange] = []
        if contentStart > range.location {
            ranges.append(NSRange(location: range.location, length: contentStart - range.location))
        }
        if contentEnd < cellEnd {
            ranges.append(NSRange(location: contentEnd, length: cellEnd - contentEnd))
        }
        return ranges
    }

    private static func alertDecorations(
        from tokens: [Token],
        text: String,
        caret: Int,
        selection: NSRange,
        dark: Bool
    ) -> [BlockBarDecoration] {
        let alerts = tokens.filter {
            if case .alert = $0.kind { return true }
            return false
        }.sorted { $0.fullRange.location < $1.fullRange.location }
        return groupedAdjacent(alerts, text: text, requireSameAlertKind: true).compactMap { group in
            guard case .alert(let kind) = group[0].kind else { return nil }
            let range = group.dropFirst().reduce(group[0].fullRange) { NSUnionRange($0, $1.fullRange) }
            let marker = group[0]
            let active = marker.containsCaret(caret) || NSIntersectionRange(selection, marker.fullRange).length > 0
            return BlockBarDecoration(range: range, dark: dark, kind: .alert(kind), collapsed: !active)
        }
    }

    private static func groupedAdjacent(
        _ tokens: [Token],
        text: String,
        requireSameAlertKind: Bool = false
    ) -> [[Token]] {
        guard let first = tokens.first else { return [] }
        let ns = text as NSString
        var groups = [[first]]
        for token in tokens.dropFirst() {
            let previous = groups[groups.count - 1].last!
            let gapStart = NSMaxRange(previous.fullRange)
            let gapLength = max(0, token.fullRange.location - gapStart)
            let adjacent = gapLength <= 2 && (gapLength == 0 || ns.substring(
                with: NSRange(location: gapStart, length: gapLength)
            ).allSatisfy(\.isNewline))
            let sameKind: Bool
            if requireSameAlertKind,
               case .alert(let lhs) = previous.kind,
               case .alert(let rhs) = token.kind {
                sameKind = lhs == rhs
            } else {
                sameKind = true
            }
            if adjacent && sameKind {
                groups[groups.count - 1].append(token)
            } else {
                groups.append([token])
            }
        }
        return groups
    }

    static func typingAttributes(at caret: Int, tokens: [Token], dark: Bool) -> [NSAttributedString.Key: Any] {
        let enclosing = tokens
            .filter { $0.containsCaret(caret) }
            .min { $0.fullRange.length < $1.fullRange.length }
        if let enclosing, let attrs = contentAttributes(for: enclosing.kind, dark: dark) {
            var typing = attrs
            if typing[.foregroundColor] == nil {
                typing[.foregroundColor] = textColor(dark: dark)
            }
            if typing[.font] == nil {
                typing[.font] = NSFont.systemFont(ofSize: 16)
            }
            return typing
        }
        return [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: textColor(dark: dark)
        ]
    }

    static func typingAttributes(at caret: Int, in text: String, dark: Bool) -> [NSAttributedString.Key: Any] {
        typingAttributes(at: caret, tokens: tokens(in: text), dark: dark)
    }

    // MARK: - Colors / fonts

    private static func textColor(dark: Bool) -> NSColor {
        dark ? NSColor(red: 0.863, green: 0.867, blue: 0.871, alpha: 1) : NSColor.textColor
    }

    private static func accentColor() -> NSColor {
        NSColor(red: 0.18, green: 0.83, blue: 0.75, alpha: 1)
    }

    private static func faintColor(dark: Bool) -> NSColor {
        dark ? NSColor(red: 0.40, green: 0.40, blue: 0.40, alpha: 1) : NSColor(red: 0.60, green: 0.60, blue: 0.60, alpha: 1)
    }

    private static func contentFont(for kind: Token.Kind) -> NSFont {
        switch kind {
        case .heading(let level):
            let size: CGFloat
            switch level {
            case 1: size = 34
            case 2: size = 26
            case 3: size = 22
            default: size = 18
            }
            return .systemFont(ofSize: size, weight: .bold)
        case .inlineCode, .codeBlock:
            return .monospacedSystemFont(ofSize: 14, weight: .regular)
        case .bold, .boldItalic:
            return .systemFont(ofSize: 16, weight: .bold)
        case .subscriptText, .superscriptText, .footnoteRef:
            return .systemFont(ofSize: 11)
        default:
            return .systemFont(ofSize: 16)
        }
    }

    private static func contentAttributes(for kind: Token.Kind, dark: Bool) -> [NSAttributedString.Key: Any]? {
        switch kind {
        case .list, .taskList, .orderedList, .blockquote, .alert, .tableSeparator,
             .horizontalRule, .htmlComment, .escape, .emoji, .image:
            return nil
        case .codeBlock:
            return [
                .font: contentFont(for: kind),
                .foregroundColor: textColor(dark: dark)
            ]
        case .wikiLink, .markdownLink, .autolink:
            return [
                .font: contentFont(for: kind),
                .foregroundColor: accentColor(),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        case .tag:
            return [
                .font: contentFont(for: kind),
                .foregroundColor: accentColor(),
                .backgroundColor: NSColor(red: 0.08, green: 0.72, blue: 0.65, alpha: 0.22)
            ]
        case .italic:
            return [
                .font: contentFont(for: kind),
                .obliqueness: 0.18
            ]
        case .boldItalic:
            return [
                .font: contentFont(for: kind),
                .obliqueness: 0.18,
                .foregroundColor: textColor(dark: dark)
            ]
        case .inlineCode:
            return [
                .font: contentFont(for: kind),
                .backgroundColor: NSColor.gray.withAlphaComponent(0.18),
                .foregroundColor: textColor(dark: dark)
            ]
        case .strikethrough:
            return [
                .font: contentFont(for: kind),
                .strikethroughStyle: NSUnderlineStyle.single.rawValue
            ]
        case .underline:
            return [
                .font: contentFont(for: kind),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        case .subscriptText:
            return [
                .font: contentFont(for: kind),
                .baselineOffset: -3
            ]
        case .superscriptText, .footnoteRef:
            return [
                .font: contentFont(for: kind),
                .baselineOffset: 6,
                .foregroundColor: accentColor()
            ]
        case .footnoteDef:
            return [
                .font: contentFont(for: kind),
                .foregroundColor: faintColor(dark: dark)
            ]
        case .tableRow:
            return nil
        case .heading, .bold:
            return [
                .font: contentFont(for: kind),
                .foregroundColor: textColor(dark: dark)
            ]
        }
    }

    private static func delimiterAttributes(
        visible: Bool,
        font: NSFont,
        dark: Bool,
        reservedHeight: CGFloat = 0,
        keepWidth: Bool = false
    ) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any]
        if visible {
            attrs = [
                .font: font,
                .foregroundColor: faintColor(dark: dark),
                .kern: 0,
                .underlineStyle: 0,
                .strikethroughStyle: 0,
                .backgroundColor: NSColor.clear,
                .obliqueness: 0
            ]
        } else if keepWidth {
            attrs = [
                .font: font,
                .foregroundColor: NSColor.clear,
                .kern: 8,
                .underlineStyle: 0,
                .strikethroughStyle: 0,
                .backgroundColor: NSColor.clear
            ]
        } else {
            attrs = [
                .font: NSFont.systemFont(ofSize: 0.01),
                .foregroundColor: NSColor.clear,
                .kern: -16,
                .underlineStyle: 0,
                .strikethroughStyle: 0,
                .backgroundColor: NSColor.clear
            ]
        }
        if reservedHeight > 0 {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = reservedHeight
            style.maximumLineHeight = reservedHeight
            attrs[.paragraphStyle] = style
        }
        return attrs
    }

    // MARK: - Parsing

    private struct Fence {
        var fullRange: NSRange
        var contentRange: NSRange
        var delimiterRanges: [NSRange]
        var language: String
    }

    private static func fencedBlocks(in ns: NSString) -> [Fence] {
        let matches = Regex.fence.matches(in: ns as String, range: NSRange(location: 0, length: ns.length))
        var blocks: [Fence] = []
        var i = 0
        while i < matches.count {
            let open = matches[i]
            let language = fenceLanguage(ns.substring(with: open.range))
            let openDelim = includingTerminator(open.range, in: ns)
            let contentStart = NSMaxRange(openDelim)
            if i + 1 < matches.count {
                let close = matches[i + 1]
                let content = NSRange(location: contentStart, length: max(0, close.range.location - contentStart))
                let full = NSRange(
                    location: open.range.location,
                    length: NSMaxRange(close.range) - open.range.location
                )
                blocks.append(
                    Fence(
                        fullRange: full,
                        contentRange: content,
                        delimiterRanges: [openDelim, close.range],
                        language: language
                    )
                )
                i += 2
            } else {
                let content = NSRange(location: contentStart, length: max(0, ns.length - contentStart))
                let full = NSRange(location: open.range.location, length: ns.length - open.range.location)
                blocks.append(
                    Fence(
                        fullRange: full,
                        contentRange: content,
                        delimiterRanges: [openDelim],
                        language: language
                    )
                )
                break
            }
        }
        return blocks
    }

    private static func fenceLanguage(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let rest = trimmed.drop(while: { $0 == "`" }).trimmingCharacters(in: .whitespaces)
        return rest.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
    }

    private static func includingTerminator(_ range: NSRange, in ns: NSString) -> NSRange {
        var result = range
        let end = NSMaxRange(range)
        guard end < ns.length else { return result }
        let ch = ns.character(at: end)
        if ch == 13 {
            result.length += 1
            if end + 1 < ns.length, ns.character(at: end + 1) == 10 {
                result.length += 1
            }
        } else if ch == 10 {
            result.length += 1
        }
        return result
    }

    private static func trimTrailingNewlines(_ range: NSRange, in ns: NSString) -> NSRange {
        var result = range
        while result.length > 0 {
            let last = ns.character(at: NSMaxRange(result) - 1)
            if last == 10 || last == 13 {
                result.length -= 1
            } else {
                break
            }
        }
        return result
    }

    private static func lineTokens(in ns: NSString, lineRange: NSRange, fences: [NSRange]) -> [Token] {
        if covered(lineRange.location, by: fences) { return [] }
        var tokens: [Token] = []
        var occupied: [NSRange] = []
        let line = ns.substring(with: lineRange)

        if GFM.isHorizontalRule(line) {
            return [Token(fullRange: lineRange, delimiterRanges: [lineRange], kind: .horizontalRule)]
        }
        if let heading = headingToken(lineRange: lineRange, in: ns) {
            tokens.append(heading)
            occupied.append(contentsOf: heading.delimiterRanges)
        } else if let def = footnoteDefToken(lineRange: lineRange, in: ns) {
            tokens.append(def)
            occupied.append(contentsOf: def.delimiterRanges)
        } else if let task = taskListToken(lineRange: lineRange, in: ns) {
            tokens.append(task)
            occupied.append(contentsOf: task.delimiterRanges)
        } else if let ordered = orderedListToken(lineRange: lineRange, in: ns) {
            tokens.append(ordered)
            occupied.append(contentsOf: ordered.delimiterRanges)
        } else if let list = listToken(lineRange: lineRange, in: ns) {
            tokens.append(list)
            occupied.append(contentsOf: list.delimiterRanges)
        } else if let quote = blockquoteToken(lineRange: lineRange, in: ns) {
            tokens.append(quote)
            occupied.append(contentsOf: quote.delimiterRanges)
        }

        tokens.append(contentsOf: inlineTokens(in: ns, lineRange: lineRange, skipping: occupied + fences))
        return tokens
    }

    private static func headingToken(lineRange: NSRange, in ns: NSString) -> Token? {
        let line = ns.substring(with: lineRange)
        let match = Regex.heading.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        )
        guard let match else { return nil }
        let hashes = match.range(at: 1).length
        let prefix = offset(match.range, by: lineRange.location)
        return Token(fullRange: lineRange, delimiterRanges: [prefix], kind: .heading(level: hashes))
    }

    private static func taskListToken(lineRange: NSRange, in ns: NSString) -> Token? {
        let line = ns.substring(with: lineRange)
        let match = Regex.taskList.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        )
        guard let match else { return nil }
        let indent = match.range(at: 1).length
        let marker = NSRange(
            location: lineRange.location + indent,
            length: match.range.length - indent
        )
        let checked = ns.substring(with: offset(match.range(at: 3), by: lineRange.location))
            .trimmingCharacters(in: .whitespaces)
            .lowercased() == "x"
        return Token(fullRange: lineRange, delimiterRanges: [marker], kind: .taskList(checked: checked))
    }

    private static func listToken(lineRange: NSRange, in ns: NSString) -> Token? {
        let line = ns.substring(with: lineRange)
        let match = Regex.list.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        )
        guard let match else { return nil }
        let indent = match.range(at: 1).length
        let marker = NSRange(
            location: lineRange.location + indent,
            length: match.range.length - indent
        )
        return Token(fullRange: lineRange, delimiterRanges: [marker], kind: .list)
    }

    private static func blockquoteToken(lineRange: NSRange, in ns: NSString) -> Token? {
        let line = ns.substring(with: lineRange)
        let match = Regex.blockquote.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        )
        guard let match else { return nil }
        return Token(
            fullRange: lineRange,
            delimiterRanges: [offset(match.range, by: lineRange.location)],
            kind: .blockquote
        )
    }

    private static func orderedListToken(lineRange: NSRange, in ns: NSString) -> Token? {
        let line = ns.substring(with: lineRange)
        let match = Regex.orderedList.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        )
        guard match != nil else { return nil }
        return Token(fullRange: lineRange, delimiterRanges: [], kind: .orderedList)
    }

    private static func footnoteDefToken(lineRange: NSRange, in ns: NSString) -> Token? {
        let line = ns.substring(with: lineRange)
        let match = Regex.footnoteDefinition.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        )
        guard let match else { return nil }
        return Token(
            fullRange: lineRange,
            delimiterRanges: [offset(match.range, by: lineRange.location)],
            kind: .footnoteDef
        )
    }

    private struct TableBlock {
        var fullRange: NSRange
        var rows: [NSRange]
        var separatorIndex: Int
    }

    private struct AlertBlock {
        var kind: GFM.AlertKind
        var lines: [NSRange]
        var fullRange: NSRange
    }

    private static func htmlCommentTokens(in ns: NSString) -> [Token] {
        return Regex.htmlComment.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).map { match in
            Token(fullRange: match.range, delimiterRanges: [match.range], kind: .htmlComment)
        }
    }

    private static func tableBlocks(in ns: NSString, skipping: [NSRange]) -> [TableBlock] {
        let lines = collectLines(in: ns)
        var blocks: [TableBlock] = []
        var i = 0
        while i + 1 < lines.count {
            if skipping.contains(where: { NSIntersectionRange($0, lines[i]).length == lines[i].length }) {
                i += 1
                continue
            }
            let first = ns.substring(with: lines[i])
            let second = ns.substring(with: lines[i + 1])
            guard GFM.isTable(header: first, separator: second) else {
                i += 1
                continue
            }
            var rows = [lines[i], lines[i + 1]]
            var j = i + 2
            while j < lines.count {
                if skipping.contains(where: { NSIntersectionRange($0, lines[j]).length == lines[j].length }) { break }
                let next = ns.substring(with: lines[j])
                if GFM.looksLikeTableRow(next) {
                    rows.append(lines[j])
                    j += 1
                } else {
                    break
                }
            }
            let full = NSRange(
                location: rows[0].location,
                length: NSMaxRange(rows.last!) - rows[0].location
            )
            blocks.append(TableBlock(fullRange: full, rows: rows, separatorIndex: 1))
            i = j
        }
        return blocks
    }

    private static func tokens(for table: TableBlock, in ns: NSString) -> [Token] {
        var tokens: [Token] = []
        for (index, row) in table.rows.enumerated() {
            let pipes = pipeRanges(in: ns, lineRange: row)
            if index == table.separatorIndex {
                tokens.append(Token(fullRange: row, delimiterRanges: pipes, kind: .tableSeparator))
            } else {
                tokens.append(Token(fullRange: row, delimiterRanges: pipes, kind: .tableRow(isHeader: index == 0)))
                tokens.append(contentsOf: inlineTokens(in: ns, lineRange: row, skipping: pipes))
            }
        }
        return tokens
    }

    private static func pipeRanges(in ns: NSString, lineRange: NSRange) -> [NSRange] {
        let line = ns.substring(with: lineRange) as NSString
        var ranges: [NSRange] = []
        var escaped = false
        for i in 0..<line.length {
            let ch = line.character(at: i)
            if escaped {
                escaped = false
                continue
            }
            if ch == 92 {
                escaped = true
                continue
            }
            if ch == 124 {
                ranges.append(NSRange(location: lineRange.location + i, length: 1))
            }
        }
        return ranges
    }

    private static func alertBlocks(in ns: NSString, skipping: [NSRange]) -> [AlertBlock] {
        let lines = collectLines(in: ns)
        var blocks: [AlertBlock] = []
        var i = 0
        while i < lines.count {
            if skipping.contains(where: { NSIntersectionRange($0, lines[i]).length == lines[i].length }) {
                i += 1
                continue
            }
            let text = ns.substring(with: lines[i])
            guard let kind = GFM.isAlertMarker(text) else {
                i += 1
                continue
            }
            var collected = [lines[i]]
            var j = i + 1
            while j < lines.count {
                if skipping.contains(where: { NSIntersectionRange($0, lines[j]).length == lines[j].length }) { break }
                let next = ns.substring(with: lines[j])
                if next.hasPrefix(">") {
                    collected.append(lines[j])
                    j += 1
                } else {
                    break
                }
            }
            let full = NSRange(
                location: collected[0].location,
                length: NSMaxRange(collected.last!) - collected[0].location
            )
            blocks.append(AlertBlock(kind: kind, lines: collected, fullRange: full))
            i = j
        }
        return blocks
    }

    private static func tokens(for alert: AlertBlock, in ns: NSString) -> [Token] {
        alert.lines.enumerated().map { index, line in
            let text = ns.substring(with: line)
            let prefix = text.hasPrefix("> ") ? 2 : (text.hasPrefix(">") ? 1 : 0)
            let delim = index == 0
                ? line
                : NSRange(location: line.location, length: min(prefix, line.length))
            return Token(fullRange: line, delimiterRanges: [delim], kind: .alert(alert.kind))
        }
    }

    private static func collectLines(in ns: NSString) -> [NSRange] {
        var lines: [NSRange] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.byLines, .substringNotRequired]
        ) { _, range, _, _ in
            lines.append(range)
        }
        return lines
    }

    private static func inlineTokens(in ns: NSString, lineRange: NSRange, skipping: [NSRange]) -> [Token] {
        let line = ns.substring(with: lineRange) as NSString
        let text = line as String
        var tokens: [Token] = []
        var occupied = skipping

        func add(_ token: Token, occupyFull: Bool = true) {
            tokens.append(token)
            occupied.append(occupyFull ? token.fullRange : token.delimiterRanges.first ?? token.fullRange)
            if !occupyFull {
                occupied.append(contentsOf: token.delimiterRanges)
            }
        }

        for match in Regex.escape.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            let full = offset(match.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            add(Token(
                fullRange: full,
                delimiterRanges: [NSRange(location: full.location, length: 1)],
                kind: .escape
            ))
        }

        // Wiki links first so `[[` is not parsed as a markdown link.
        for match in Regex.wiki.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            let full = offset(match.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            var delimiters: [NSRange] = [
                NSRange(location: full.location, length: 2),
                NSRange(location: NSMaxRange(full) - 2, length: 2)
            ]
            if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound {
                let alias = offset(match.range(at: 2), by: lineRange.location)
                let targetAndPipe = NSRange(
                    location: full.location + 2,
                    length: alias.location - (full.location + 2)
                )
                if targetAndPipe.length > 0 { delimiters.insert(targetAndPipe, at: 1) }
            }
            add(Token(fullRange: full, delimiterRanges: delimiters, kind: .wikiLink))
        }

        for match in Regex.image.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            let full = offset(match.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            let url = ns.substring(with: offset(match.range(at: 2), by: lineRange.location))
            add(Token(fullRange: full, delimiterRanges: [full], kind: .image(url: url)))
        }

        for match in Regex.footnoteReference.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            let full = offset(match.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            add(Token(
                fullRange: full,
                delimiterRanges: [
                    NSRange(location: full.location, length: 2),
                    NSRange(location: NSMaxRange(full) - 1, length: 1)
                ],
                kind: .footnoteRef
            ))
        }

        for link in GFM.inlineLinks(in: text) {
            let full = offset(link.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            let label = offset(link.labelRange, by: lineRange.location)
            let open = NSRange(location: full.location, length: 1)
            let rest = NSRange(location: NSMaxRange(label), length: NSMaxRange(full) - NSMaxRange(label))
            add(Token(fullRange: full, delimiterRanges: [open, rest], kind: .markdownLink))
        }

        for match in Regex.inlineCode.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            let full = offset(match.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            add(Token(
                fullRange: full,
                delimiterRanges: [
                    NSRange(location: full.location, length: 1),
                    NSRange(location: NSMaxRange(full) - 1, length: 1)
                ],
                kind: .inlineCode
            ))
        }

        for match in Regex.angleLink.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            let full = offset(match.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            add(Token(
                fullRange: full,
                delimiterRanges: [
                    NSRange(location: full.location, length: 1),
                    NSRange(location: NSMaxRange(full) - 1, length: 1)
                ],
                kind: .autolink
            ))
        }

        for match in Regex.bareURL.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            let full = offset(match.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            add(Token(fullRange: full, delimiterRanges: [], kind: .autolink))
        }

        for match in Regex.subscriptText.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            let full = offset(match.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            let inner = offset(match.range(at: 1), by: lineRange.location)
            add(Token(
                fullRange: full,
                delimiterRanges: [
                    NSRange(location: full.location, length: inner.location - full.location),
                    NSRange(location: NSMaxRange(inner), length: NSMaxRange(full) - NSMaxRange(inner))
                ],
                kind: .subscriptText
            ), occupyFull: false)
        }

        for match in Regex.superscriptText.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            let full = offset(match.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            let inner = offset(match.range(at: 1), by: lineRange.location)
            add(Token(
                fullRange: full,
                delimiterRanges: [
                    NSRange(location: full.location, length: inner.location - full.location),
                    NSRange(location: NSMaxRange(inner), length: NSMaxRange(full) - NSMaxRange(inner))
                ],
                kind: .superscriptText
            ), occupyFull: false)
        }

        for match in Regex.underline.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            let full = offset(match.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            let inner = offset(match.range(at: 2), by: lineRange.location)
            add(Token(
                fullRange: full,
                delimiterRanges: [
                    NSRange(location: full.location, length: inner.location - full.location),
                    NSRange(location: NSMaxRange(inner), length: NSMaxRange(full) - NSMaxRange(inner))
                ],
                kind: .underline
            ), occupyFull: false)
        }

        for match in Regex.emoji.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            let full = offset(match.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            let name = ns.substring(with: offset(match.range(at: 1), by: lineRange.location))
            guard let glyph = GFM.emoji(for: name) else { continue }
            add(Token(fullRange: full, delimiterRanges: [full], kind: .emoji(glyph)))
        }

        for match in Regex.strike.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            let full = offset(match.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            add(Token(
                fullRange: full,
                delimiterRanges: [
                    NSRange(location: full.location, length: 2),
                    NSRange(location: NSMaxRange(full) - 2, length: 2)
                ],
                kind: .strikethrough
            ))
        }

        for match in Regex.strikeOnce.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            let full = offset(match.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            add(Token(
                fullRange: full,
                delimiterRanges: [
                    NSRange(location: full.location, length: 1),
                    NSRange(location: NSMaxRange(full) - 1, length: 1)
                ],
                kind: .strikethrough
            ))
        }

        for match in Regex.boldItalic.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            let full = offset(match.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            add(Token(
                fullRange: full,
                delimiterRanges: [
                    NSRange(location: full.location, length: 3),
                    NSRange(location: NSMaxRange(full) - 3, length: 3)
                ],
                kind: .boldItalic
            ), occupyFull: false)
        }

        for match in Regex.bold.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            let full = offset(match.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound {
                let source = line.substring(with: match.range)
                let inner = source.dropFirst(2).dropLast(2)
                if !inner.isEmpty, inner.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    continue
                }
            }
            add(Token(
                fullRange: full,
                delimiterRanges: [
                    NSRange(location: full.location, length: 2),
                    NSRange(location: NSMaxRange(full) - 2, length: 2)
                ],
                kind: .bold
            ), occupyFull: false)
        }

        for match in Regex.italic.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            let full = offset(match.range, by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            add(Token(
                fullRange: full,
                delimiterRanges: [
                    NSRange(location: full.location, length: 1),
                    NSRange(location: NSMaxRange(full) - 1, length: 1)
                ],
                kind: .italic
            ))
        }

        // Keep `#` visible: it is part of the rendered tag, not hidden markup.
        for match in Regex.tag.matches(in: text, range: NSRange(location: 0, length: line.length)) {
            guard match.numberOfRanges > 2 else { continue }
            let full = offset(match.range(at: 2), by: lineRange.location)
            if covered(full.location, by: occupied) { continue }
            add(Token(fullRange: full, delimiterRanges: [], kind: .tag))
        }

        return tokens
    }

    private static func offset(_ range: NSRange, by delta: Int) -> NSRange {
        NSRange(location: range.location + delta, length: range.length)
    }

    private static func covered(_ location: Int, by ranges: [NSRange]) -> Bool {
        ranges.contains { NSLocationInRange(location, $0) }
    }
}
