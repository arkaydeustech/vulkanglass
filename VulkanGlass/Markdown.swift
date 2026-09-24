import Foundation

enum Markdown {
    private static let wikiRegex = try! NSRegularExpression(
        pattern: #"\[\[([^\]|#]+)(?:#([^\]|]+))?(?:\|([^\]]+))?\]\]"#
    )
    private static let tagRegex = try! NSRegularExpression(pattern: #"(^|\s)#([A-Za-z][\w/-]*)"#)
    private static let detailsTagRegex = try! NSRegularExpression(
        pattern: #"<(/?)details(?:\s[^>]*)?>"#,
        options: .caseInsensitive
    )

    /// Returns the note title for a file path.
    static func title(from path: String) -> String {
        (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "", options: .caseInsensitive)
    }

    /// Extracts unique wiki-link targets.
    static func wikiLinks(in content: String) -> [String] {
        let stripped = strippingFencedCode(from: content)
        return matches(wikiRegex, in: stripped).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return rangeString(match, 1, in: stripped)?.trimmingCharacters(in: .whitespaces)
        }.uniqued()
    }

    /// Extracts #tags, ignoring code fences.
    static func tags(in content: String) -> [String] {
        let stripped = strippingFencedCode(from: content)
        return matches(tagRegex, in: stripped).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            return rangeString(match, 2, in: stripped)
        }.uniqued()
    }

    /// Extracts top-level ATX headings, ignoring code fences and details bodies.
    static func headings(in content: String) -> [NoteHeading] {
        var openFence: MarkdownBlockSyntax.Fence?
        var detailsDepth = 0
        return content.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if let open = openFence {
                if MarkdownBlockSyntax.isFenceClosing(line, opening: open) {
                    openFence = nil
                }
                return nil
            }
            if let fence = MarkdownBlockSyntax.fenceOpening(line) {
                openFence = fence
                return nil
            }
            for tag in detailsTagRegex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                if detailsDepth == 0 {
                    let prefix = (line as NSString).substring(to: tag.range.location)
                    if !prefix.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                }
                if tag.range(at: 1).length > 0 {
                    detailsDepth = max(0, detailsDepth - 1)
                } else {
                    detailsDepth += 1
                }
            }
            guard detailsDepth == 0, let heading = MarkdownBlockSyntax.heading(line) else { return nil }
            return NoteHeading(level: heading.level, text: heading.text, line: index + 1)
        }
    }

    /// Counts words, ignoring fenced code.
    static func wordCount(_ content: String) -> Int {
        let stripped = strippingFencedCode(from: content)
        return stripped.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// Today's daily-note filename.
    static func dailyNoteName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date) + ".md"
    }

    /// Turns wiki links into markdown links with a custom scheme.
    static func rewriteWikiLinks(_ content: String) -> String {
        let ns = content as NSString
        let results = wikiRegex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        var output = content
        for match in results.reversed() {
            guard let target = rangeString(match, 1, in: content)?.trimmingCharacters(in: .whitespaces) else { continue }
            let heading = match.numberOfRanges > 2 ? rangeString(match, 2, in: content) : nil
            let alias = match.numberOfRanges > 3 ? rangeString(match, 3, in: content) : nil
            let label = alias ?? (heading.map { "\(target) › \($0)" } ?? target)
            let href = "wiki://\(target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target)"
            let replacement = "[\(label)](\(href))"
            if let range = Range(match.range, in: output) {
                output.replaceSubrange(range, with: replacement)
            }
        }
        return output
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func rangeString(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        let value = String(text[swiftRange])
        return value.isEmpty ? nil : value
    }

    private static func strippingFencedCode(from content: String) -> String {
        content.replacingOccurrences(
            of: "```[\\s\\S]*?(?:```|$)",
            with: "",
            options: .regularExpression
        )
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
