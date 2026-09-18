import Foundation

/// A deliberately small HTML parser and semantic allowlist used for clipboard import.
/// It preserves document meaning without embedding an unrestricted browser in notes.
enum SemanticHTML {
    private static let maximumNestingDepth = 256
    private static let markdownLineBreakPlaceholder = "\u{E000}"

    final class Node {
        var name: String?
        var attributes: [String: String]
        var children: [Node]
        var text: String?

        init(
            name: String? = nil,
            attributes: [String: String] = [:],
            children: [Node] = [],
            text: String? = nil
        ) {
            self.name = name
            self.attributes = attributes
            self.children = children
            self.text = text
        }

        var plainText: String {
            if let text { return SemanticHTML.decodeEntities(text) }
            return children.map(\.plainText).joined()
        }
    }

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
        "meta", "param", "source", "track", "wbr"
    ]
    private static let ignoredElements: Set<String> = [
        "script", "style", "iframe", "object", "embed", "svg", "canvas", "template",
        "title", "textarea", "xmp", "noembed", "noframes", "plaintext"
    ]
    private static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "div", "dl", "details", "fieldset",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header",
        "hr", "main", "nav", "ol", "p", "pre", "section", "table", "ul"
    ]
    private static let markdownBlockStartExpressions = [
        #"^ {0,3}(#{1,6})(?:[ \t]+|$)"#,
        #"^ {0,3}([+\->])(?=[ \t]+)"#,
        #"^ {0,3}\d{1,9}([.)])(?=[ \t]+)"#,
        #"^ {0,3}(-)(?:[ \t]*-){2,}[ \t]*$"#,
        #"^ {0,3}([*_])(?:[ \t]*\1){2,}[ \t]*$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func parseFragment(_ html: String) -> Node {
        let root = Node(name: "#document")
        var stack = [root]
        var droppedDepth = 0
        var index = html.startIndex

        while index < html.endIndex {
            if html[index...].hasPrefix("<!--") {
                if let end = html.range(of: "-->", range: index..<html.endIndex) {
                    index = end.upperBound
                } else {
                    break
                }
                continue
            }
            guard html[index] == "<" else {
                let end = html[index...].firstIndex(of: "<") ?? html.endIndex
                if droppedDepth == 0 {
                    stack.last?.children.append(Node(text: String(html[index..<end])))
                }
                index = end
                continue
            }
            guard let close = closingAngleBracket(in: html, after: index) else {
                stack.last?.children.append(Node(text: String(html[index...])))
                break
            }

            let contentStart = html.index(after: index)
            var content = String(html[contentStart..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
            index = html.index(after: close)
            guard !content.isEmpty, !content.hasPrefix("!") && !content.hasPrefix("?") else { continue }

            if content.hasPrefix("/") {
                if droppedDepth > 0 {
                    droppedDepth -= 1
                    continue
                }
                let closingName = content.dropFirst().prefix { !$0.isWhitespace && $0 != ">" }.lowercased()
                if let matching = stack.lastIndex(where: { $0.name == closingName }), matching > 0 {
                    stack.removeSubrange(matching..<stack.count)
                }
                continue
            }

            let selfClosing = content.hasSuffix("/")
            if selfClosing { content.removeLast() }
            let parsed = parseOpeningTag(content)
            guard !parsed.name.isEmpty else { continue }
            if droppedDepth > 0 {
                if !selfClosing && !voidElements.contains(parsed.name) { droppedDepth += 1 }
                continue
            }
            if !selfClosing,
               !voidElements.contains(parsed.name),
               stack.count > maximumNestingDepth {
                droppedDepth = 1
                continue
            }
            let node = Node(name: parsed.name, attributes: parsed.attributes)
            stack.last?.children.append(node)
            if !selfClosing && !voidElements.contains(parsed.name) {
                stack.append(node)
            }
        }
        return root
    }

    static func markdown(from html: String, lineBreaksAsMarkdown: Bool = false) -> String? {
        let root = parseFragment(html)
        return markdown(from: root.children, lineBreaksAsMarkdown: lineBreaksAsMarkdown)
    }

    static func markdown(from nodes: [Node], lineBreaksAsMarkdown: Bool = false) -> String? {
        let output = renderBlocks(nodes, lineBreaksAsMarkdown: lineBreaksAsMarkdown)
            .replacingOccurrences(of: #"\n[ \t]+\n"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.contains(where: { !$0.isWhitespace }) ? output : nil
    }

    /// Markdown embedded inside an allowlisted HTML container is already source text.
    /// Preserve its block prefixes while still rendering any nested HTML elements.
    static func embeddedMarkdown(from nodes: [Node]) -> String? {
        var rendered = ""
        for node in nodes {
            if node.name == nil {
                rendered += escapeMarkdownAngles(decodeEntities(node.text ?? ""))
            } else if let name = node.name, ignoredElements.contains(name) {
                continue
            } else if let name = node.name, blockElements.contains(name) {
                if !rendered.hasSuffix("\n\n"), !rendered.isEmpty { rendered += "\n\n" }
                rendered += renderBlock(node)
                rendered += "\n\n"
            } else {
                rendered += renderInline([node])
            }
        }
        let output = rendered
            .replacingOccurrences(of: #"\n[ \t]+\n"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.contains(where: { !$0.isWhitespace }) ? output : nil
    }

    static func inlineMarkdown(from html: String) -> String {
        normalizeInline(renderInline(parseFragment(html).children))
    }

    static func inlineMarkdown(from nodes: [Node]) -> String {
        normalizeInline(renderInline(nodes))
    }

    static func safeInlineMarkdown(from nodes: [Node]) -> String {
        normalizeInline(renderInline(nodes, escapeTextAngles: true))
    }

    static func firstElement(named name: String, in node: Node) -> Node? {
        if node.name == name { return node }
        for child in node.children {
            if let found = firstElement(named: name, in: child) { return found }
        }
        return nil
    }

    static func descendants(named names: Set<String>, in node: Node) -> [Node] {
        var result: [Node] = []
        for child in node.children {
            if let name = child.name, names.contains(name) { result.append(child) }
            result.append(contentsOf: descendants(named: names, in: child))
        }
        return result
    }

    static func safeURL(_ raw: String, image: Bool) -> String? {
        let value = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: {
                  $0.value < 0x20 || (0x7F...0x9F).contains($0.value)
              }),
              !value.hasPrefix("//") else { return nil }
        if let scheme = URL(string: value)?.scheme?.lowercased(), !scheme.isEmpty {
            let allowed = image ? ["http", "https", "file"] : ["http", "https", "file", "mailto"]
            guard allowed.contains(scheme) else { return nil }
        } else {
            let schemeBoundary = value.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? value.endIndex
            guard value[..<schemeBoundary].firstIndex(of: ":") == nil else { return nil }
        }
        return value
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
    }

    static func decodeEntities(_ source: String) -> String {
        let named = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}",
            "ndash": "–", "mdash": "—", "hellip": "…", "copy": "©", "reg": "®"
        ]
        var result = ""
        var index = source.startIndex
        while index < source.endIndex {
            guard source[index] == "&",
                  let semicolon = source[index...].firstIndex(of: ";"),
                  source.distance(from: index, to: semicolon) <= 16 else {
                result.append(source[index])
                index = source.index(after: index)
                continue
            }
            let bodyStart = source.index(after: index)
            let body = String(source[bodyStart..<semicolon])
            let replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map(String.init)
            } else if body.hasPrefix("#") {
                replacement = UInt32(body.dropFirst()).flatMap(UnicodeScalar.init).map(String.init)
            } else {
                replacement = named[body.lowercased()]
            }
            if let replacement {
                result += replacement
                index = source.index(after: semicolon)
            } else {
                result.append("&")
                index = source.index(after: index)
            }
        }
        return result
    }

    private static func renderBlocks(
        _ nodes: [Node],
        preserveHTMLText: Bool = false,
        lineBreaksAsMarkdown: Bool = false
    ) -> String {
        var blocks: [String] = []
        var inlineBuffer: [Node] = []
        func flushInline() {
            let value = escapingMarkdownBlockStarts(in: normalizeInline(renderInline(
                inlineBuffer,
                preserveHTML: preserveHTMLText,
                lineBreaksAsMarkdown: lineBreaksAsMarkdown
            )))
            if !value.isEmpty { blocks.append(value) }
            inlineBuffer.removeAll(keepingCapacity: true)
        }

        for node in nodes {
            guard let name = node.name else {
                inlineBuffer.append(node)
                continue
            }
            if ignoredElements.contains(name) { continue }
            guard blockElements.contains(name) || name == "body" || name == "html" else {
                inlineBuffer.append(node)
                continue
            }
            flushInline()
            let value = renderBlock(
                node,
                preserveHTMLText: preserveHTMLText,
                lineBreaksAsMarkdown: lineBreaksAsMarkdown
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { blocks.append(value) }
        }
        flushInline()
        return blocks.joined(separator: "\n\n")
    }

    private static func renderBlock(
        _ node: Node,
        preserveHTMLText: Bool = false,
        lineBreaksAsMarkdown: Bool = false
    ) -> String {
        guard let name = node.name else { return normalizeInline(node.plainText) }
        if ignoredElements.contains(name) { return "" }
        switch name {
        case "html", "body", "main", "article", "section", "header", "footer", "nav", "aside", "form", "fieldset":
            return renderBlocks(
                node.children,
                preserveHTMLText: preserveHTMLText,
                lineBreaksAsMarkdown: lineBreaksAsMarkdown
            )
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(name.dropFirst()) ?? 1
            return String(repeating: "#", count: level) + " " + normalizeInline(renderInline(
                node.children,
                preserveHTML: preserveHTMLText,
                lineBreaksAsMarkdown: lineBreaksAsMarkdown
            ))
        case "p", "address":
            return escapingMarkdownBlockStarts(in: normalizeInline(renderInline(
                node.children,
                preserveHTML: preserveHTMLText,
                lineBreaksAsMarkdown: lineBreaksAsMarkdown
            )))
        case "div":
            return node.children.contains(where: { $0.name.map(blockElements.contains) == true })
                ? renderBlocks(
                    node.children,
                    preserveHTMLText: preserveHTMLText,
                    lineBreaksAsMarkdown: lineBreaksAsMarkdown
                )
                : escapingMarkdownBlockStarts(in: normalizeInline(renderInline(
                    node.children,
                    preserveHTML: preserveHTMLText,
                    lineBreaksAsMarkdown: lineBreaksAsMarkdown
                )))
        case "blockquote":
            return renderBlocks(
                node.children,
                preserveHTMLText: preserveHTMLText,
                lineBreaksAsMarkdown: lineBreaksAsMarkdown
            )
                .components(separatedBy: "\n").map { line in
                line.isEmpty ? ">" : "> \(line)"
            }.joined(separator: "\n")
        case "ul":
            return renderList(
                node,
                ordered: false,
                preserveHTMLText: preserveHTMLText,
                lineBreaksAsMarkdown: lineBreaksAsMarkdown
            )
        case "ol":
            return renderList(
                node,
                ordered: true,
                preserveHTMLText: preserveHTMLText,
                lineBreaksAsMarkdown: lineBreaksAsMarkdown
            )
        case "pre":
            let language = firstElement(named: "code", in: node)?.attributes["class"]?
                .split(separator: " ").first(where: { $0.hasPrefix("language-") })
                .map { String($0.dropFirst("language-".count)) } ?? ""
            let code = decodeEntities(node.children.map(rawText).joined())
                .trimmingCharacters(in: .newlines)
            if preserveHTMLText {
                let classAttribute = language.isEmpty ? "" : " class=\"language-\(escapeHTML(language))\""
                return "<pre><code\(classAttribute)>\(escapeHTML(code))</code></pre>"
            }
            let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: code) + 1))
            return "\(fence)\(language)\n\(code)\n\(fence)"
        case "hr":
            return "---"
        case "table":
            return sanitizedTable(node)
        case "details":
            return sanitizedDetails(node)
        case "dl":
            return sanitizedDefinitionList(node)
        case "figure":
            return renderBlocks(
                node.children,
                preserveHTMLText: preserveHTMLText,
                lineBreaksAsMarkdown: lineBreaksAsMarkdown
            )
        default:
            return normalizeInline(renderInline(
                node.children,
                preserveHTML: preserveHTMLText,
                lineBreaksAsMarkdown: lineBreaksAsMarkdown
            ))
        }
    }

    private static func renderList(
        _ node: Node,
        ordered: Bool,
        preserveHTMLText: Bool = false,
        lineBreaksAsMarkdown: Bool = false
    ) -> String {
        let items = node.children.filter { $0.name == "li" }
        var number = Int(node.attributes["start"] ?? "") ?? 1
        return items.map { item in
            if let explicit = Int(item.attributes["value"] ?? "") { number = explicit }
            let checkbox = item.children.first {
                $0.name == "input" &&
                ($0.attributes["type"] ?? "").lowercased() == "checkbox"
            }
            let marker: String
            if let checkbox {
                marker = checkbox.attributes["checked"] != nil ? "- [x] " : "- [ ] "
            } else if ordered {
                marker = "\(number). "
            } else {
                marker = "- "
            }
            number += 1
            let content = renderListItem(
                item,
                preserveHTMLText: preserveHTMLText,
                lineBreaksAsMarkdown: lineBreaksAsMarkdown
            )
            let lines = content.components(separatedBy: "\n")
            return marker + (lines.first ?? "") + lines.dropFirst().map { "\n  \($0)" }.joined()
        }.joined(separator: "\n")
    }

    private static func renderListItem(
        _ node: Node,
        preserveHTMLText: Bool = false,
        lineBreaksAsMarkdown: Bool = false
    ) -> String {
        var pieces: [String] = []
        var inline: [Node] = []
        func flush() {
            let value = normalizeInline(renderInline(
                inline,
                preserveHTML: preserveHTMLText,
                lineBreaksAsMarkdown: lineBreaksAsMarkdown
            ))
            if !value.isEmpty { pieces.append(value) }
            inline.removeAll(keepingCapacity: true)
        }
        for child in node.children {
            if child.name == "input" { continue }
            if child.name == "ul" || child.name == "ol" {
                flush()
                pieces.append(renderBlock(
                    child,
                    preserveHTMLText: preserveHTMLText,
                    lineBreaksAsMarkdown: lineBreaksAsMarkdown
                ))
            } else if child.name.map(blockElements.contains) == true {
                flush()
                pieces.append(renderBlock(
                    child,
                    preserveHTMLText: preserveHTMLText,
                    lineBreaksAsMarkdown: lineBreaksAsMarkdown
                ))
            } else {
                inline.append(child)
            }
        }
        flush()
        return pieces.joined(separator: "\n")
    }

    private static func renderInline(
        _ nodes: [Node],
        preserveHTML: Bool = false,
        escapeTextAngles: Bool = false,
        lineBreaksAsMarkdown: Bool = false
    ) -> String {
        nodes.map { node in
            guard let name = node.name else {
                let decoded = decodeEntities(node.text ?? "")
                if preserveHTML { return escapeHTML(decoded) }
                let escaped = escapeMarkdown(decoded)
                return escapeTextAngles ? escapeMarkdownAngles(escaped) : escaped
            }
            if ignoredElements.contains(name) { return "" }
            let inner = renderInline(
                node.children,
                preserveHTML: preserveHTML,
                escapeTextAngles: escapeTextAngles,
                lineBreaksAsMarkdown: lineBreaksAsMarkdown
            )
            switch name {
            case "br":
                return preserveHTML || !lineBreaksAsMarkdown
                    ? "<br>"
                    : markdownLineBreakPlaceholder
            case "wbr": return ""
            case "strong", "b": return preserveHTML ? "<strong>\(inner)</strong>" : "**\(inner)**"
            case "em", "i": return preserveHTML ? "<em>\(inner)</em>" : "*\(inner)*"
            case "del", "s", "strike": return preserveHTML ? "<del>\(inner)</del>" : "~~\(inner)~~"
            case "ins", "u": return "<ins>\(inner)</ins>"
            case "sub": return "<sub>\(inner)</sub>"
            case "sup": return "<sup>\(inner)</sup>"
            case "kbd": return "<kbd>\(inner)</kbd>"
            case "mark": return "<mark>\(inner)</mark>"
            case "code":
                return preserveHTML ? "<code>\(escapeHTML(node.plainText))</code>" : codeSpan(node.plainText)
            case "a":
                guard let href = node.attributes["href"], let safe = safeURL(href, image: false) else { return inner }
                return preserveHTML
                    ? "<a href=\"\(escapeHTML(safe))\">\(inner)</a>"
                    : GFM.serializeInlineLink(label: normalizeInline(inner), destination: safe)
            case "img":
                guard let src = node.attributes["src"], let safe = safeURL(src, image: true) else {
                    return escapeMarkdown(node.attributes["alt"] ?? "")
                }
                let alt = escapeLinkLabel(decodeEntities(node.attributes["alt"] ?? ""))
                return "![\(alt)](\(safe))"
            case "picture":
                if let image = descendants(named: ["img"], in: node).first {
                    return renderInline(
                        [image],
                        preserveHTML: preserveHTML,
                        escapeTextAngles: escapeTextAngles,
                        lineBreaksAsMarkdown: lineBreaksAsMarkdown
                    )
                }
                return ""
            case "table":
                return sanitizedTable(node)
            case "input": return ""
            default:
                return applyingInlineStyle(
                    inner,
                    plainText: node.plainText,
                    from: node.attributes["style"],
                    preserveHTML: preserveHTML
                )
            }
        }.joined()
    }

    private static func sanitizedTable(_ table: Node) -> String {
        var lines = ["<table>"]
        if let caption = table.children.first(where: { $0.name == "caption" }) {
            let value = normalizeInline(renderInline(caption.children, preserveHTML: true))
            if !value.isEmpty { lines.append("  <caption>\(value)</caption>") }
        }
        func appendRows(_ rows: [Node], indent: String) {
            for row in rows {
            let cells = row.children.filter { $0.name == "td" || $0.name == "th" }
            guard !cells.isEmpty else { continue }
            lines.append("\(indent)<tr>")
            for cell in cells {
                let tag = cell.name == "th" ? "th" : "td"
                var attributes = ""
                for key in ["rowspan", "colspan"] {
                    if let raw = cell.attributes[key], let value = Int(raw), (2...100).contains(value) {
                        attributes += " \(key)=\"\(value)\""
                    }
                }
                if let align = cell.attributes["align"]?.lowercased(), ["left", "center", "right"].contains(align) {
                    attributes += " align=\"\(align)\""
                }
                let content = normalizeInline(renderInline(cell.children, preserveHTML: true))
                lines.append("\(indent)  <\(tag)\(attributes)>\(content)</\(tag)>")
            }
            lines.append("\(indent)</tr>")
            }
        }
        let directRows = table.children.filter { $0.name == "tr" }
        appendRows(directRows, indent: "  ")
        for section in table.children where ["thead", "tbody", "tfoot"].contains(section.name ?? "") {
            let name = section.name ?? "tbody"
            lines.append("  <\(name)>")
            appendRows(section.children.filter { $0.name == "tr" }, indent: "    ")
            lines.append("  </\(name)>")
        }
        lines.append("</table>")
        return lines.joined(separator: "\n")
    }

    private static func sanitizedDetails(_ details: Node) -> String {
        let summary = details.children.first(where: { $0.name == "summary" })
        let title = summary.map { normalizeInline(renderInline($0.children, preserveHTML: true)) } ?? "Details"
        let bodyNodes = details.children.filter { $0 !== summary }
        let body = renderBlocks(bodyNodes, preserveHTMLText: true)
        let open = details.attributes["open"] != nil ? " open" : ""
        return "<details\(open)>\n<summary>\(title)</summary>\n\(body)\n</details>"
    }

    private static func sanitizedDefinitionList(_ list: Node) -> String {
        var lines = ["<dl>"]
        for child in list.children where child.name == "dt" || child.name == "dd" {
            let tag = child.name ?? "dd"
            let content = child.children.contains(where: { $0.name.map(blockElements.contains) == true })
                ? renderBlocks(child.children, preserveHTMLText: true)
                : normalizeInline(renderInline(child.children, preserveHTML: true))
            lines.append("<\(tag)>\(content)</\(tag)>")
        }
        lines.append("</dl>")
        return lines.joined(separator: "\n")
    }

    private static func normalizeInline(_ value: String) -> String {
        value.components(separatedBy: markdownLineBreakPlaceholder)
            .map {
                $0.replacingOccurrences(of: #"[ \t\r\n]+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .joined(separator: "  \n")
            .replacingOccurrences(of: " <br> ", with: "<br>")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escapeMarkdown(_ value: String) -> String {
        var output = ""
        for character in value {
            if #"\`*_[]~"#.contains(character) { output.append("\\") }
            output.append(character)
        }
        return output
    }

    private static func escapeMarkdownAngles(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<", with: "\\<")
            .replacingOccurrences(of: ">", with: "\\>")
    }

    private static func escapingMarkdownBlockStarts(in value: String) -> String {
        return value.components(separatedBy: "\n").map { line in
            let range = NSRange(location: 0, length: (line as NSString).length)
            for expression in markdownBlockStartExpressions {
                if let match = expression.firstMatch(in: line, range: range), match.numberOfRanges > 1 {
                    let markerRange = match.range(at: 1)
                    let mutable = NSMutableString(string: line)
                    mutable.insert("\\", at: markerRange.location)
                    return mutable as String
                }
            }
            return line
        }.joined(separator: "\n")
    }

    private static func applyingInlineStyle(
        _ value: String,
        plainText: String,
        from rawStyle: String?,
        preserveHTML: Bool
    ) -> String {
        guard let rawStyle, !rawStyle.isEmpty else { return value }
        var properties: [String: String] = [:]
        for declaration in rawStyle.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            properties[parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        let fontWeight = properties["font-weight"] ?? ""
        let numericWeight = Int(fontWeight.filter(\.isNumber)) ?? 0
        let fontStyle = properties["font-style"] ?? ""
        let decoration = properties["text-decoration"] ?? properties["text-decoration-line"] ?? ""
        let fontFamily = properties["font-family"] ?? ""
        let shorthandFont = properties["font"] ?? ""
        let isBold = fontWeight == "bold" || fontWeight == "bolder" || numericWeight >= 600
            || shorthandFont.range(of: #"(?:^|\s)(?:bold|[6-9]00)(?:\s|$)"#, options: .regularExpression) != nil
        let isItalic = fontStyle == "italic" || fontStyle == "oblique"
            || shorthandFont.contains("italic") || shorthandFont.contains("oblique")
        let isMonospace = fontFamily.contains("monospace") || shorthandFont.contains("monospace")

        var output = value
        if isMonospace { output = preserveHTML ? "<code>\(output)</code>" : codeSpan(plainText) }
        if isBold { output = preserveHTML ? "<strong>\(output)</strong>" : "**\(output)**" }
        if isItalic { output = preserveHTML ? "<em>\(output)</em>" : "*\(output)*" }
        if decoration.contains("line-through") {
            output = preserveHTML ? "<del>\(output)</del>" : "~~\(output)~~"
        }
        if decoration.contains("underline") { output = "<ins>\(output)</ins>" }
        return output
    }

    private static func longestRun(of target: Character, in value: String) -> Int {
        var longest = 0
        var current = 0
        for character in value {
            if character == target {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private static func escapeLinkLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "]", with: "\\]")
    }

    private static func codeSpan(_ value: String) -> String {
        var longest = 0
        var current = 0
        for character in value {
            if character == "`" { current += 1; longest = max(longest, current) } else { current = 0 }
        }
        let delimiter = String(repeating: "`", count: longest + 1)
        let padding = value.hasPrefix("`") || value.hasSuffix("`") || value.hasPrefix(" ") || value.hasSuffix(" ")
        return delimiter + (padding ? " " : "") + value + (padding ? " " : "") + delimiter
    }

    private static func rawText(_ node: Node) -> String {
        node.text ?? node.children.map(rawText).joined()
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func closingAngleBracket(in html: String, after opening: String.Index) -> String.Index? {
        var index = html.index(after: opening)
        var quote: Character?
        while index < html.endIndex {
            let character = html[index]
            if let currentQuote = quote {
                if character == currentQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = html.index(after: index)
        }
        return nil
    }

    private static func parseOpeningTag(_ source: String) -> (name: String, attributes: [String: String]) {
        var index = source.startIndex
        while index < source.endIndex, source[index].isWhitespace { index = source.index(after: index) }
        let nameStart = index
        while index < source.endIndex, source[index].isLetter || source[index].isNumber || source[index] == "-" {
            index = source.index(after: index)
        }
        let name = String(source[nameStart..<index]).lowercased()
        var attributes: [String: String] = [:]
        while index < source.endIndex {
            while index < source.endIndex, source[index].isWhitespace { index = source.index(after: index) }
            guard index < source.endIndex else { break }
            let keyStart = index
            while index < source.endIndex,
                  !source[index].isWhitespace, source[index] != "=", source[index] != "/" {
                index = source.index(after: index)
            }
            let key = String(source[keyStart..<index]).lowercased()
            guard !key.isEmpty else { index = source.index(after: index); continue }
            while index < source.endIndex, source[index].isWhitespace { index = source.index(after: index) }
            var value = ""
            if index < source.endIndex, source[index] == "=" {
                index = source.index(after: index)
                while index < source.endIndex, source[index].isWhitespace { index = source.index(after: index) }
                if index < source.endIndex, source[index] == "\"" || source[index] == "'" {
                    let quote = source[index]
                    index = source.index(after: index)
                    let valueStart = index
                    while index < source.endIndex, source[index] != quote { index = source.index(after: index) }
                    value = String(source[valueStart..<index])
                    if index < source.endIndex { index = source.index(after: index) }
                } else {
                    let valueStart = index
                    while index < source.endIndex, !source[index].isWhitespace, source[index] != "/" {
                        index = source.index(after: index)
                    }
                    value = String(source[valueStart..<index])
                }
            }
            attributes[key] = value
        }
        return (name, attributes)
    }
}
