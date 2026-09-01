import AppKit

/// Converts the semantic and typographic information AppKit imports from HTML/RTF
/// into Markdown source suitable for the editor.
enum RichTextMarkdownConverter {
    private static let markdownBlockStartExpressions = [
        #"^ {0,3}(#{1,6})(?:[ \t]+|$)"#,
        #"^ {0,3}([+\->])(?=[ \t]+)"#,
        #"^ {0,3}\d{1,9}([.)])(?=[ \t]+)"#,
        #"^ {0,3}(-)(?:[ \t]*-){2,}[ \t]*$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    final class BlockingResourceLoadDelegate: NSObject {
        static let shared = BlockingResourceLoadDelegate()

        @objc(webView:resource:willSendRequest:redirectResponse:fromDataSource:)
        func rejectExternalResource(
            _ sender: AnyObject,
            resource: AnyObject,
            request: URLRequest,
            redirectResponse: URLResponse?,
            dataSource: AnyObject
        ) -> URLRequest? {
            nil
        }
    }

    private struct InlineStyle: Equatable {
        let bold: Bool
        let italic: Bool
        let code: Bool
        let strikethrough: Bool
        let underline: Bool
        let superscript: Int
        let link: String?
    }

    private struct InlineRun {
        var text: String
        let style: InlineStyle
    }

    private enum ListKind: Equatable {
        case ordered
        case unordered
    }

    private enum BlockKind: Equatable {
        case normal
        case list(ListKind)
        case code
        case htmlTable
    }

    private struct Block {
        let text: String
        let kind: BlockKind
    }

    private struct TableCellKey: Hashable {
        let row: Int
        let column: Int
    }

    private struct ImportedTableCell {
        var paragraphs: [String]
        var rowSpan: Int
        var columnSpan: Int
        var isBold: Bool
    }

    private struct ImportedHTMLTable {
        let html: String
        let endLocation: Int
    }

    static func markdown(from data: Data, documentType: NSAttributedString.DocumentType) -> String? {
        if documentType == .html,
           let html = decodedHTML(data),
           needsSemanticHTMLImport(html),
           let semantic = SemanticHTML.markdown(from: html) {
            return semantic
        }
        let options = readingOptions(for: data, documentType: documentType)
        guard let attributed = try? NSAttributedString(
            data: data,
            options: options,
            documentAttributes: nil
        ) else { return nil }
        let converted = markdown(from: attributed)
        let meaningfulScalars = converted.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard meaningfulScalars.contains(where: { $0.value != 0xFFFC && $0.value != 0xFFFD }) else {
            return nil
        }
        return converted
    }

    static func decodedHTML(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard data.count.isMultiple(of: 2) else { return nil }
            return String(data: data, encoding: .utf16)
        }
        if let charset = declaredHTMLCharset(in: data) {
            guard let encoding = stringEncoding(forHTMLCharset: charset) else { return nil }
            guard let decoded = String(data: data, encoding: encoding), !decoded.contains("\0") else { return nil }
            return decoded
        }
        if let utf8 = String(data: data, encoding: .utf8), !utf8.contains("\0") { return utf8 }
        guard let fallback = String(data: data, encoding: .windowsCP1252), !fallback.contains("\0") else {
            return nil
        }
        return fallback
    }

    private static func needsSemanticHTMLImport(_ html: String) -> Bool {
        html.range(
            of: #"<(?:table|blockquote|br|hr|img|picture|details|summary|dl|dt|dd|kbd|mark|input|figure|figcaption)(?:\s|/?>)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static func readingOptions(
        for data: Data,
        documentType: NSAttributedString.DocumentType
    ) -> [NSAttributedString.DocumentReadingOptionKey: Any] {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: documentType]
        if documentType == .html {
            if !htmlDeclaresCharacterEncoding(data) {
                options[.characterEncoding] = String.Encoding.utf8.rawValue
            }
            // HTML copied from a browser may reference remote styles and images. Paste
            // conversion is local and must not fetch subsidiary web resources.
            options[.webResourceLoadDelegate] = BlockingResourceLoadDelegate.shared
        }
        return options
    }

    static func markdown(from attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else { return "" }

        let source = attributed.string as NSString
        var blocks: [Block] = []
        var location = 0

        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location,
                  isNewline(source.character(at: contentEnd - 1)) {
                contentEnd -= 1
            }

            let contentRange = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
            let attributesLocation = min(lineRange.location, attributed.length - 1)
            let paragraphStyle = attributed.attribute(
                .paragraphStyle,
                at: attributesLocation,
                effectiveRange: nil
            ) as? NSParagraphStyle

            if let tableBlock = paragraphStyle?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).last,
               let table = importedHTMLTable(
                   from: attributed,
                   startingAt: location,
                   table: tableBlock.table
               ) {
                blocks.append(Block(text: table.html, kind: .htmlTable))
                location = table.endLocation
                continue
            } else if contentRange.length == 0 {
                blocks.append(Block(text: "", kind: .normal))
            } else if isCodeBlock(attributed, range: contentRange, paragraphStyle: paragraphStyle) {
                blocks.append(Block(
                    text: removingAttachmentCharacters(from: source.substring(with: contentRange)),
                    kind: .code
                ))
            } else {
                let list = listDetails(in: source.substring(with: contentRange), style: paragraphStyle)
                let bodyRange = NSRange(
                    location: contentRange.location + list.prefixLength,
                    length: contentRange.length - list.prefixLength
                )
                let headerLevel = min(max(paragraphStyle?.headerLevel ?? 0, 0), 6)
                var text = inlineMarkdown(from: attributed, range: bodyRange, isHeading: headerLevel > 0)

                if headerLevel > 0 {
                    text = String(repeating: "#", count: headerLevel) + " " + text
                } else if let listKind = list.kind {
                    let indentation = String(repeating: "  ", count: max(0, list.depth - 1))
                    text = indentation + (listKind == .ordered ? "1. " : "- ") + text
                } else {
                    text = escapingMarkdownBlockStart(in: text)
                }

                blocks.append(Block(text: text, kind: list.kind.map(BlockKind.list) ?? .normal))
            }

            location = NSMaxRange(lineRange)
        }

        return render(blocks)
    }

    private static func inlineMarkdown(
        from attributed: NSAttributedString,
        range: NSRange,
        isHeading: Bool
    ) -> String {
        guard range.length > 0 else { return "" }
        var runs: [InlineRun] = []

        attributed.enumerateAttributes(in: range) { attributes, runRange, _ in
            let font = attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let link = (attributes[.link] as? URL)?.absoluteString
                ?? (attributes[.link] as? String)
            let style = InlineStyle(
                bold: !isHeading && traits.contains(.bold),
                italic: traits.contains(.italic),
                code: traits.contains(.monoSpace),
                strikethrough: (attributes[.strikethroughStyle] as? Int ?? 0) != 0,
                underline: link == nil && (attributes[.underlineStyle] as? Int ?? 0) != 0,
                superscript: attributes[.superscript] as? Int ?? 0,
                link: link
            )
            // NSTextAttachment runs use U+FFFC as a placeholder. There is no stable,
            // portable source URL on an imported attachment, so omit the placeholder
            // instead of saving an invisible control character or inventing a link.
            let text = removingAttachmentCharacters(
                from: (attributed.string as NSString).substring(with: runRange)
            )
            guard !text.isEmpty else { return }
            if let last = runs.indices.last, runs[last].style == style {
                runs[last].text += text
            } else {
                runs.append(InlineRun(text: text, style: style))
            }
        }

        var output = ""
        var index = 0
        while index < runs.count {
            let link = runs[index].style.link
            var end = index + 1
            while end < runs.count, runs[end].style.link == link { end += 1 }
            let label = runs[index..<end].map(styledText).joined()
            if let link {
                output += "[\(label)](\(escapedLinkDestination(link)))"
            } else {
                output += label
            }
            index = end
        }
        return output
    }

    /// AppKit imports each HTML table cell as a paragraph whose text block records
    /// the source table and its row/column coordinates. Rebuild that semantic
    /// structure as safe, portable HTML instead of flattening every cell into an
    /// unrelated Markdown paragraph.
    private static func importedHTMLTable(
        from attributed: NSAttributedString,
        startingAt start: Int,
        table: NSTextTable
    ) -> ImportedHTMLTable? {
        let source = attributed.string as NSString
        var cells: [TableCellKey: ImportedTableCell] = [:]
        var location = start

        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let attributesLocation = min(lineRange.location, attributed.length - 1)
            let paragraphStyle = attributed.attribute(
                .paragraphStyle,
                at: attributesLocation,
                effectiveRange: nil
            ) as? NSParagraphStyle
            guard let tableBlock = paragraphStyle?.textBlocks
                .compactMap({ $0 as? NSTextTableBlock })
                .last(where: { $0.table === table }) else { break }

            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location,
                  isNewline(source.character(at: contentEnd - 1)) {
                contentEnd -= 1
            }
            let contentRange = NSRange(
                location: lineRange.location,
                length: contentEnd - lineRange.location
            )
            let key = TableCellKey(row: tableBlock.startingRow, column: tableBlock.startingColumn)
            let paragraph = inlineHTML(from: attributed, range: contentRange)
            let paragraphIsBold = allMeaningfulTextIsBold(in: attributed, range: contentRange)
            if var cell = cells[key] {
                cell.paragraphs.append(paragraph)
                cell.rowSpan = max(cell.rowSpan, tableBlock.rowSpan)
                cell.columnSpan = max(cell.columnSpan, tableBlock.columnSpan)
                cell.isBold = cell.isBold && paragraphIsBold
                cells[key] = cell
            } else {
                cells[key] = ImportedTableCell(
                    paragraphs: [paragraph],
                    rowSpan: tableBlock.rowSpan,
                    columnSpan: tableBlock.columnSpan,
                    isBold: paragraphIsBold
                )
            }
            location = NSMaxRange(lineRange)
        }

        guard !cells.isEmpty else { return nil }
        let rowNumbers = Set(cells.keys.map(\.row)).sorted()
        let firstRowCells = cells
            .filter { $0.key.row == rowNumbers.first }
            .sorted { $0.key.column < $1.key.column }
        let coveredHeaderColumns = firstRowCells.reduce(0) { $0 + $1.value.columnSpan }
        let hasHeader = rowNumbers.first == 0
            && !firstRowCells.isEmpty
            && coveredHeaderColumns >= table.numberOfColumns
            && firstRowCells.allSatisfy(\.value.isBold)

        var lines = ["<table>"]
        if hasHeader, let headerRow = rowNumbers.first {
            lines.append("  <thead>")
            lines.append(contentsOf: htmlTableRow(headerRow, cells: cells, header: true))
            lines.append("  </thead>")
        }

        let bodyRows = hasHeader ? Array(rowNumbers.dropFirst()) : rowNumbers
        if !bodyRows.isEmpty {
            lines.append("  <tbody>")
            for row in bodyRows {
                lines.append(contentsOf: htmlTableRow(row, cells: cells, header: false))
            }
            lines.append("  </tbody>")
        }
        lines.append("</table>")
        return ImportedHTMLTable(html: lines.joined(separator: "\n"), endLocation: location)
    }

    private static func htmlTableRow(
        _ row: Int,
        cells: [TableCellKey: ImportedTableCell],
        header: Bool
    ) -> [String] {
        let rowCells = cells
            .filter { $0.key.row == row }
            .sorted { $0.key.column < $1.key.column }
        guard !rowCells.isEmpty else { return [] }

        let tag = header ? "th" : "td"
        var lines = ["    <tr>"]
        for (_, cell) in rowCells {
            var attributes = ""
            if cell.rowSpan > 1 { attributes += " rowspan=\"\(cell.rowSpan)\"" }
            if cell.columnSpan > 1 { attributes += " colspan=\"\(cell.columnSpan)\"" }
            let content = cell.paragraphs.joined(separator: "<br>")
            lines.append("      <\(tag)\(attributes)>\(content)</\(tag)>")
        }
        lines.append("    </tr>")
        return lines
    }

    private static func inlineHTML(from attributed: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var output = ""
        attributed.enumerateAttributes(in: range) { attributes, runRange, _ in
            let rawText = removingAttachmentCharacters(
                from: (attributed.string as NSString).substring(with: runRange)
            )
            guard !rawText.isEmpty else { return }

            let font = attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let link = (attributes[.link] as? URL)?.absoluteString
                ?? (attributes[.link] as? String)
            var text = escapeHTML(rawText)
            if traits.contains(.monoSpace) { text = "<code>\(text)</code>" }
            if traits.contains(.bold) { text = "<strong>\(text)</strong>" }
            if traits.contains(.italic) { text = "<em>\(text)</em>" }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 {
                text = "<del>\(text)</del>"
            }
            if link == nil, (attributes[.underlineStyle] as? Int ?? 0) != 0 {
                text = "<ins>\(text)</ins>"
            }
            let superscript = attributes[.superscript] as? Int ?? 0
            if superscript > 0 {
                text = "<sup>\(text)</sup>"
            } else if superscript < 0 {
                text = "<sub>\(text)</sub>"
            }
            if let link, let safeLink = SemanticHTML.safeURL(link, image: false) {
                text = "<a href=\"\(escapeHTML(safeLink))\">\(text)</a>"
            }
            output += text
        }
        return output
    }

    private static func allMeaningfulTextIsBold(
        in attributed: NSAttributedString,
        range: NSRange
    ) -> Bool {
        guard range.length > 0 else { return false }
        var sawText = false
        var allBold = true
        attributed.enumerateAttribute(.font, in: range) { value, fontRange, stop in
            let text = removingAttachmentCharacters(
                from: (attributed.string as NSString).substring(with: fontRange)
            )
            guard text.contains(where: { !$0.isWhitespace }) else { return }
            sawText = true
            guard let font = value as? NSFont,
                  font.fontDescriptor.symbolicTraits.contains(.bold) else {
                allBold = false
                stop.pointee = true
                return
            }
        }
        return sawText && allBold
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func styledText(_ run: InlineRun) -> String {
        guard !run.text.isEmpty else { return "" }
        if run.style.code {
            var maximum = 0
            var current = 0
            for character in run.text {
                if character == "`" {
                    current += 1
                    maximum = max(maximum, current)
                } else {
                    current = 0
                }
            }
            let delimiter = String(repeating: "`", count: maximum + 1)
            let padding = run.text.hasPrefix("`") || run.text.hasSuffix("`")
                || run.text.hasPrefix(" ") || run.text.hasSuffix(" ")
            return delimiter + (padding ? " " : "") + run.text + (padding ? " " : "") + delimiter
        }

        var styled = escapeMarkdown(run.text)
        guard run.text.contains(where: { !$0.isWhitespace }) else { return styled }
        switch (run.style.bold, run.style.italic) {
        case (true, true): styled = "***\(styled)***"
        case (true, false): styled = "**\(styled)**"
        case (false, true): styled = "*\(styled)*"
        case (false, false): break
        }
        if run.style.strikethrough { styled = "~~\(styled)~~" }
        if run.style.underline { styled = "<ins>\(styled)</ins>" }
        if run.style.superscript > 0 {
            styled = "<sup>\(styled)</sup>"
        } else if run.style.superscript < 0 {
            styled = "<sub>\(styled)</sub>"
        }
        return styled
    }

    private static func listDetails(
        in text: String,
        style: NSParagraphStyle?
    ) -> (kind: ListKind?, depth: Int, prefixLength: Int) {
        guard let style, !style.textLists.isEmpty else { return (nil, 0, 0) }
        let kind: ListKind = style.textLists.last?.isOrdered == true ? .ordered : .unordered
        let ns = text as NSString
        let match = try? NSRegularExpression(pattern: #"^\t([^\t]+)\t"#)
            .firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        return (kind, style.textLists.count, match.map { NSMaxRange($0.range) } ?? 0)
    }

    private static func isCodeBlock(
        _ attributed: NSAttributedString,
        range: NSRange,
        paragraphStyle: NSParagraphStyle?
    ) -> Bool {
        guard paragraphStyle?.headerLevel == 0,
              paragraphStyle?.textLists.isEmpty != false,
              paragraphStyle?.paragraphSpacing == 0 else { return false }
        var sawText = false
        var allMonospaced = true
        attributed.enumerateAttribute(.font, in: range) { value, fontRange, stop in
            let text = (attributed.string as NSString).substring(with: fontRange)
            guard text.contains(where: { !$0.isWhitespace }) else { return }
            sawText = true
            guard let font = value as? NSFont,
                  font.fontDescriptor.symbolicTraits.contains(.monoSpace) else {
                allMonospaced = false
                stop.pointee = true
                return
            }
        }
        return sawText && allMonospaced
    }

    private static func render(_ blocks: [Block]) -> String {
        var output = ""
        var index = 0
        while index < blocks.count {
            if blocks[index].kind == .code {
                var lines: [String] = []
                while index < blocks.count, blocks[index].kind == .code {
                    lines.append(blocks[index].text)
                    index += 1
                }
                appendBlock(fencedCode(lines.joined(separator: "\n")), to: &output, separator: "\n\n")
                continue
            }

            let separator: String
            if output.isEmpty {
                separator = ""
            } else if blocks[index].text.isEmpty {
                separator = "\n\n"
            } else if case .list = blocks[index].kind,
                      index > 0,
                      case .list = blocks[index - 1].kind {
                separator = "\n"
            } else {
                separator = "\n\n"
            }
            appendBlock(blocks[index].text, to: &output, separator: separator)
            index += 1
        }
        return output
    }

    private static func appendBlock(_ block: String, to output: inout String, separator: String) {
        guard !block.isEmpty else { return }
        if !output.isEmpty {
            output = output.trimmingCharacters(in: .newlines)
            output += separator
        }
        output += block
    }

    private static func fencedCode(_ text: String) -> String {
        var maximum = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                maximum = max(maximum, current)
            } else {
                current = 0
            }
        }
        let fence = String(repeating: "`", count: max(3, maximum + 1))
        return "\(fence)\n\(text)\n\(fence)"
    }

    private static func escapeMarkdown(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        for (index, character) in characters.enumerated() {
            let shouldEscape: Bool
            switch character {
            case "\\", "`", "*", "[", "]", "<":
                shouldEscape = true
            case "_":
                let previousIsWord = index > 0 && isWordCharacter(characters[index - 1])
                let nextIsWord = index + 1 < characters.count && isWordCharacter(characters[index + 1])
                shouldEscape = !(previousIsWord && nextIsWord)
            default:
                shouldEscape = false
            }
            if shouldEscape { output.append("\\") }
            output.append(character)
        }
        return output
    }

    private static func escapingMarkdownBlockStart(in text: String) -> String {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        for expression in markdownBlockStartExpressions {
            guard let match = expression.firstMatch(in: text, range: fullRange),
                  match.numberOfRanges > 1 else { continue }
            let markerRange = match.range(at: 1)
            guard markerRange.location != NSNotFound else { continue }
            let mutable = NSMutableString(string: text)
            mutable.insert("\\", at: markerRange.location)
            return mutable as String
        }
        return text
    }

    private static func removingAttachmentCharacters(from text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func htmlDeclaresCharacterEncoding(_ data: Data) -> Bool {
        if data.starts(with: [0xEF, 0xBB, 0xBF])
            || data.starts(with: [0xFF, 0xFE])
            || data.starts(with: [0xFE, 0xFF]) {
            return true
        }

        return declaredHTMLCharset(in: data) != nil
    }

    private static func declaredHTMLCharset(in data: Data) -> String? {
        let prefix = data.prefix(8_192)
        guard let header = String(data: prefix, encoding: .isoLatin1) else { return nil }
        let expression = try! NSRegularExpression(
            pattern: #"(?:charset|encoding)\s*=\s*[\"']?\s*([A-Za-z0-9._:-]+)"#,
            options: .caseInsensitive
        )
        let range = NSRange(location: 0, length: (header as NSString).length)
        guard let match = expression.firstMatch(in: header, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        return (header as NSString).substring(with: match.range(at: 1)).lowercased()
    }

    private static func stringEncoding(forHTMLCharset charset: String) -> String.Encoding? {
        switch charset.replacingOccurrences(of: "_", with: "-").lowercased() {
        case "utf-8", "utf8":
            return .utf8
        case "windows-1252", "cp1252", "x-cp1252":
            return .windowsCP1252
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1":
            return .isoLatin1
        case "us-ascii", "ascii":
            return .ascii
        case "utf-16le":
            return .utf16LittleEndian
        case "utf-16be":
            return .utf16BigEndian
        default:
            return nil
        }
    }

    private static func escapedLinkDestination(_ destination: String) -> String {
        destination
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }

    private static func isNewline(_ codeUnit: unichar) -> Bool {
        codeUnit == 0x000A || codeUnit == 0x000D || codeUnit == 0x0085
            || codeUnit == 0x2028 || codeUnit == 0x2029
    }
}
