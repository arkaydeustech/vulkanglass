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
    }

    private struct Block {
        let text: String
        let kind: BlockKind
    }

    static func markdown(from data: Data, documentType: NSAttributedString.DocumentType) -> String? {
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

            if contentRange.length == 0 {
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

        let escaped = escapeMarkdown(run.text)
        guard run.text.contains(where: { !$0.isWhitespace }) else { return escaped }
        switch (run.style.bold, run.style.italic) {
        case (true, true): return "***\(escaped)***"
        case (true, false): return "**\(escaped)**"
        case (false, true): return "*\(escaped)*"
        case (false, false): return escaped
        }
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

        let prefix = data.prefix(8_192)
        guard let header = String(data: prefix, encoding: .isoLatin1) else { return false }
        return header.range(
            of: #"(?:charset\s*=|<\?xml[^>]+encoding\s*=)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
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
