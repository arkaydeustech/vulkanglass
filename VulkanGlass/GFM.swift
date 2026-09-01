import Foundation

/// GitHub Flavored Markdown helpers shared by live preview and reading view.
enum GFM {
    struct InlineLink: Equatable {
        var range: NSRange
        var labelRange: NSRange
        var destinationRange: NSRange
        var label: String
        var destination: String
        var isImage: Bool
    }

    struct TableMutation: Equatable {
        var replacement: String
        var selectionOffset: Int
    }

    struct HTMLTable: Equatable {
        var rows: [[String]]
        var hasHeader: Bool
    }

    enum AlertKind: String, Equatable, CaseIterable, Sendable {
        case note = "NOTE"
        case tip = "TIP"
        case important = "IMPORTANT"
        case warning = "WARNING"
        case caution = "CAUTION"

        var title: String {
            switch self {
            case .note: return "Note"
            case .tip: return "Tip"
            case .important: return "Important"
            case .warning: return "Warning"
            case .caution: return "Caution"
            }
        }

        var symbol: String {
            switch self {
            case .note: return "info.circle.fill"
            case .tip: return "lightbulb.fill"
            case .important: return "exclamationmark.square.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .caution: return "exclamationmark.octagon.fill"
            }
        }
    }

    enum Alignment: Equatable, Sendable {
        case left, center, right

        static func parse(_ cell: String) -> Alignment {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let leading = trimmed.hasPrefix(":")
            let trailing = trimmed.hasSuffix(":")
            if leading && trailing { return .center }
            if trailing { return .right }
            return .left
        }
    }

    static func inlineLinks(in source: String, includingImages: Bool = false) -> [InlineLink] {
        let ns = source as NSString
        var links: [InlineLink] = []
        var location = 0
        while location < ns.length {
            let isImage = ns.character(at: location) == 33
                && location + 1 < ns.length
                && ns.character(at: location + 1) == 91
            let isLink = ns.character(at: location) == 91
                && (location == 0 || ns.character(at: location - 1) != 33)
            if (isLink || (includingImages && isImage)),
               let parsed = inlineLink(in: source, startingAt: location, isImage: isImage) {
                links.append(parsed)
                location = NSMaxRange(parsed.range)
            } else {
                location += 1
            }
        }
        return links
    }

    static func inlineLink(
        in source: String,
        startingAt location: Int,
        includingImages: Bool = false
    ) -> InlineLink? {
        let ns = source as NSString
        guard location >= 0, location < ns.length else { return nil }
        let isImage = ns.character(at: location) == 33
            && location + 1 < ns.length
            && ns.character(at: location + 1) == 91
        let isNormalLink = !isImage
            && ns.character(at: location) == 91
            && (location == 0 || ns.character(at: location - 1) != 33)
        guard (isImage && includingImages) || isNormalLink else { return nil }
        return inlineLink(in: source, startingAt: location, isImage: isImage)
    }

    static func serializeInlineLink(label: String, destination: String) -> String {
        let normalizedLabel = label
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let escapedLabel = normalizedLabel
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
        let needsAngleBrackets = destination.contains { character in
            character == "(" || character == ")" || character.isWhitespace
        }
        let normalizedDestination = destination
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "\t", with: "%09")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
        let serializedDestination: String
        if needsAngleBrackets {
            let escapedDestination = normalizedDestination
                .replacingOccurrences(of: "<", with: "%3C")
                .replacingOccurrences(of: ">", with: "%3E")
            serializedDestination = "<\(escapedDestination)>"
        } else {
            serializedDestination = normalizedDestination
        }
        return "[\(escapedLabel)](\(serializedDestination))"
    }

    private static func inlineLink(in source: String, startingAt location: Int, isImage: Bool) -> InlineLink? {
        let ns = source as NSString
        let openingBracket = location + (isImage ? 1 : 0)
        guard openingBracket < ns.length, ns.character(at: openingBracket) == 91 else { return nil }

        var cursor = openingBracket + 1
        var closingBracket: Int?
        while cursor < ns.length {
            let character = ns.character(at: cursor)
            if character == 10 || character == 13 { return nil }
            if character == 93, !isEscaped(cursor, in: ns) {
                closingBracket = cursor
                break
            }
            cursor += 1
        }
        guard let closingBracket,
              closingBracket + 1 < ns.length,
              ns.character(at: closingBracket + 1) == 40 else { return nil }

        let destinationStart = closingBracket + 2
        guard destinationStart < ns.length else { return nil }
        let destinationRange: NSRange
        let closingParenthesis: Int
        if ns.character(at: destinationStart) == 60 {
            var end = destinationStart + 1
            while end < ns.length {
                let character = ns.character(at: end)
                if character == 10 || character == 13 { return nil }
                if character == 62, !isEscaped(end, in: ns) { break }
                end += 1
            }
            guard end < ns.length,
                  end + 1 < ns.length,
                  ns.character(at: end + 1) == 41 else { return nil }
            destinationRange = NSRange(location: destinationStart + 1, length: end - destinationStart - 1)
            closingParenthesis = end + 1
        } else {
            var end = destinationStart
            var depth = 0
            while end < ns.length {
                let character = ns.character(at: end)
                if character == 10 || character == 13 { return nil }
                if !isEscaped(end, in: ns) {
                    if character == 40 {
                        depth += 1
                    } else if character == 41 {
                        if depth == 0 { break }
                        depth -= 1
                    }
                }
                end += 1
            }
            guard end < ns.length, depth == 0 else { return nil }
            destinationRange = NSRange(location: destinationStart, length: end - destinationStart)
            closingParenthesis = end
        }

        let labelRange = NSRange(location: openingBracket + 1, length: closingBracket - openingBracket - 1)
        guard labelRange.length > 0, destinationRange.length > 0 else { return nil }
        let rawLabel = ns.substring(with: labelRange)
        let label = rawLabel
            .replacingOccurrences(of: "\\]", with: "]")
            .replacingOccurrences(of: "\\\\", with: "\\")
        return InlineLink(
            range: NSRange(location: location, length: closingParenthesis - location + 1),
            labelRange: labelRange,
            destinationRange: destinationRange,
            label: label,
            destination: ns.substring(with: destinationRange),
            isImage: isImage
        )
    }

    private static func isEscaped(_ location: Int, in source: NSString) -> Bool {
        var cursor = location
        var slashes = 0
        while cursor > 0, source.character(at: cursor - 1) == 92 {
            slashes += 1
            cursor -= 1
        }
        return !slashes.isMultiple(of: 2)
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isHorizontalRule(trimmed) else { return false }
        guard trimmed.contains("-") else { return false }
        let cells = splitTableRow(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            return value.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    static func looksLikeTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("|") else { return false }
        if isHorizontalRule(trimmed) { return false }
        return splitTableRow(trimmed).count >= 2 || trimmed.hasPrefix("|")
    }

    static func splitTableRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        var start = trimmed.startIndex
        var end = trimmed.endIndex
        if start < end, trimmed[start] == "|" {
            start = trimmed.index(after: start)
        }
        if start < end {
            let last = trimmed.index(before: end)
            if trimmed[last] == "|", !isEscapedPipe(at: last, in: trimmed) {
                end = last
            }
        }

        var index = start
        while index < end {
            if trimmed[index] == "\\" {
                let slashStart = index
                while index < end, trimmed[index] == "\\" {
                    index = trimmed.index(after: index)
                }
                let slashCount = trimmed.distance(from: slashStart, to: index)
                if index < end, trimmed[index] == "|", !slashCount.isMultiple(of: 2) {
                    current += String(repeating: "\\", count: slashCount - 1)
                    current.append("|")
                    index = trimmed.index(after: index)
                } else {
                    current += String(repeating: "\\", count: slashCount)
                }
                continue
            }
            if trimmed[index] == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(trimmed[index])
            }
            index = trimmed.index(after: index)
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func normalizedTableRow(_ line: String, columnCount: Int) -> [String] {
        guard columnCount > 0 else { return [] }
        var cells = Array(splitTableRow(line).prefix(columnCount))
        if cells.count < columnCount {
            cells.append(contentsOf: repeatElement("", count: columnCount - cells.count))
        }
        return cells
    }

    /// Parses the raw HTML form GitHub recommends for tables without a header.
    /// This intentionally handles table structure only; unsupported HTML remains source text.
    static func parseHTMLTable(_ source: String) -> HTMLTable? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^<table(?:\s|>)"#, options: [.regularExpression, .caseInsensitive]) != nil,
              trimmed.range(of: #"</table\s*>$"#, options: [.regularExpression, .caseInsensitive]) != nil
        else { return nil }

        let rowRegex = try! NSRegularExpression(
            pattern: #"<tr(?:\s[^>]*)?>([\s\S]*?)</tr\s*>"#,
            options: .caseInsensitive
        )
        let cellRegex = try! NSRegularExpression(
            pattern: #"<(td|th)(?:\s[^>]*)?>([\s\S]*?)</\1\s*>"#,
            options: .caseInsensitive
        )
        let ns = trimmed as NSString
        var rows: [[String]] = []
        var firstRowIsHeader = false
        for rowMatch in rowRegex.matches(
            in: trimmed,
            range: NSRange(location: 0, length: ns.length)
        ) {
            let rowSource = ns.substring(with: rowMatch.range(at: 1))
            let rowNS = rowSource as NSString
            let matches = cellRegex.matches(
                in: rowSource,
                range: NSRange(location: 0, length: rowNS.length)
            )
            guard !matches.isEmpty else { continue }
            if rows.isEmpty {
                firstRowIsHeader = matches.allSatisfy {
                    rowNS.substring(with: $0.range(at: 1)).caseInsensitiveCompare("th") == .orderedSame
                }
            }
            rows.append(matches.map { htmlCellText(rowNS.substring(with: $0.range(at: 2))) })
        }
        guard !rows.isEmpty else { return nil }
        let columns = rows.map(\.count).max() ?? 0
        rows = rows.map { row in
            var normalized = Array(row.prefix(columns))
            normalized.append(contentsOf: repeatElement("", count: columns - normalized.count))
            return normalized
        }
        return HTMLTable(rows: rows, hasHeader: firstRowIsHeader)
    }

    private static func isEscapedPipe(at index: String.Index, in text: String) -> Bool {
        var cursor = index
        var slashCount = 0
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }
        return !slashCount.isMultiple(of: 2)
    }

    private static func htmlCellText(_ source: String) -> String {
        let withoutTags = source
            .replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodeHTMLEntitiesOnce(withoutTags)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Decodes each entity present in the source exactly once. In particular,
    /// `&amp;lt;` becomes `&lt;`, not `<`.
    private static func decodeHTMLEntitiesOnce(_ source: String) -> String {
        let replacements = [
            "amp": "&",
            "lt": "<",
            "gt": ">",
            "quot": "\"",
            "apos": "'",
            "#39": "'"
        ]
        var result = ""
        var index = source.startIndex
        while index < source.endIndex {
            guard source[index] == "&",
                  let semicolon = source[index...].firstIndex(of: ";"),
                  source.distance(from: index, to: semicolon) <= 8
            else {
                result.append(source[index])
                index = source.index(after: index)
                continue
            }
            let nameStart = source.index(after: index)
            let name = String(source[nameStart..<semicolon])
            if let replacement = replacements[name] {
                result += replacement
                index = source.index(after: semicolon)
            } else {
                result.append(source[index])
                index = source.index(after: index)
            }
        }
        return result
    }

    static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"^(\*{3,}|-{3,}|_{3,})$"#, options: .regularExpression) != nil
    }

    static func isAlertMarker(_ line: String) -> AlertKind? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return nil }
        let inner = trimmed.hasPrefix("> ") ? String(trimmed.dropFirst(2)) : String(trimmed.dropFirst())
        let match = inner.range(of: #"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$"#, options: .regularExpression)
        guard match != nil else { return nil }
        let name = inner.dropFirst(2).prefix(while: { $0 != "]" })
        return AlertKind(rawValue: String(name))
    }

    static func isTable(header: String, separator: String) -> Bool {
        guard looksLikeTableRow(header), isTableSeparator(separator) else { return false }
        return splitTableRow(header).count == splitTableRow(separator).count
    }

    /// Adds an empty cell to the right edge of every source row while preserving the
    /// table's existing text. The returned offset places the caret in the new header cell.
    static func addingTableColumn(to markdown: String) -> TableMutation? {
        let separator = tableLineSeparator(in: markdown)
        let lines = markdown.components(separatedBy: separator)
        guard lines.count >= 2,
              isTable(header: lines[0], separator: lines[1])
        else { return nil }

        let existingColumns = splitTableRow(lines[0]).count
        var caret = 0
        let edited = lines.enumerated().map { index, line in
            var next = line
            if index > 1 {
                while splitTableRow(next).count < existingColumns {
                    next = appendingTableCell("", to: next).line
                }
            }
            let appended = appendingTableCell(index == 1 ? "---" : "", to: next)
            if index == 0 {
                caret = appended.cellInteriorOffset
            }
            return appended.line
        }
        return TableMutation(replacement: edited.joined(separator: separator), selectionOffset: caret)
    }

    /// Appends a blank body row and returns a caret position inside its first cell.
    static func addingTableRow(to markdown: String) -> TableMutation? {
        let separator = tableLineSeparator(in: markdown)
        let lines = markdown.components(separatedBy: separator)
        guard lines.count >= 2,
              isTable(header: lines[0], separator: lines[1])
        else { return nil }
        let columns = splitTableRow(lines[0]).count
        guard columns > 0 else { return nil }

        let row = "| " + Array(repeating: "", count: columns).joined(separator: " | ") + " |"
        let replacement = markdown + separator + row
        return TableMutation(
            replacement: replacement,
            selectionOffset: (markdown as NSString).length + (separator as NSString).length + 2
        )
    }

    private static func tableLineSeparator(in markdown: String) -> String {
        markdown.contains("\r\n") ? "\r\n" : "\n"
    }

    private struct AppendedTableCell {
        var line: String
        var cellInteriorOffset: Int
    }

    private static func appendingTableCell(_ cell: String, to line: String) -> AppendedTableCell {
        let ns = line as NSString
        var bodyEnd = ns.length
        while bodyEnd > 0 {
            let scalar = ns.character(at: bodyEnd - 1)
            guard scalar == 32 || scalar == 9 || scalar == 13 else { break }
            bodyEnd -= 1
        }
        let body = ns.substring(to: bodyEnd)
        let trailing = ns.substring(from: bodyEnd)
        let cellLength = (cell as NSString).length
        if hasUnescapedTrailingPipe(body) {
            let withoutPipe = (body as NSString).substring(to: (body as NSString).length - 1)
            return AppendedTableCell(
                line: withoutPipe + "| \(cell) |" + trailing,
                cellInteriorOffset: (withoutPipe as NSString).length + 2 + cellLength
            )
        }
        return AppendedTableCell(
            line: body + " | \(cell) |" + trailing,
            cellInteriorOffset: (body as NSString).length + 3 + cellLength
        )
    }

    private static func hasUnescapedTrailingPipe(_ line: String) -> Bool {
        guard line.last == "|" else { return false }
        var slashes = 0
        for character in line.dropLast().reversed() {
            guard character == "\\" else { break }
            slashes += 1
        }
        return slashes.isMultiple(of: 2)
    }

    static func emoji(for shortcode: String) -> String? {
        emojis[shortcode.lowercased()]
    }

    static let emojis: [String: String] = [
        "+1": "👍", "-1": "👎", "thumbsup": "👍", "thumbsdown": "👎",
        "smile": "😄", "laughing": "😆", "blush": "😊", "smiley": "😃",
        "relaxed": "☺️", "smirk": "😏", "heart_eyes": "😍", "kissing_heart": "😘",
        "thinking": "🤔", "thinking_face": "🤔", "wink": "😉", "stuck_out_tongue": "😛",
        "stuck_out_tongue_winking_eye": "😜", "disappointed": "😞", "worried": "😟",
        "angry": "😠", "rage": "😡", "cry": "😢", "sob": "😭", "joy": "😂",
        "rofl": "🤣", "sweat_smile": "😅", "satisfied": "😆", "innocent": "😇",
        "rolling_eyes": "🙄", "neutral_face": "😐", "expressionless": "😑",
        "no_mouth": "😶", "hugs": "🤗", "wave": "👋", "clap": "👏", "pray": "🙏",
        "ok_hand": "👌", "point_up": "☝️", "point_down": "👇", "point_left": "👈",
        "point_right": "👉", "raised_hands": "🙌", "muscle": "💪", "eyes": "👀",
        "eye": "👁️", "tongue": "👅", "lips": "👄", "tada": "🎉", "confetti_ball": "🎊",
        "balloon": "🎈", "gift": "🎁", "trophy": "🏆", "medal": "🏅", "star": "⭐",
        "star2": "🌟", "sparkles": "✨", "zap": "⚡", "fire": "🔥", "boom": "💥",
        "collision": "💥", "heart": "❤️", "hearts": "💕", "yellow_heart": "💛",
        "green_heart": "💚", "blue_heart": "💙", "purple_heart": "💜", "black_heart": "🖤",
        "broken_heart": "💔", "100": "💯", "heavy_check_mark": "✅", "white_check_mark": "✅",
        "x": "❌", "negative_squared_cross_mark": "❎", "warning": "⚠️",
        "exclamation": "❗", "question": "❓", "grey_exclamation": "❕", "grey_question": "❔",
        "bulb": "💡", "bell": "🔔", "lock": "🔒", "unlock": "🔓", "key": "🔑",
        "mag": "🔍", "bookmark": "🔖", "link": "🔗", "paperclip": "📎", "pushpin": "📌",
        "pencil": "✏️", "pencil2": "✏️", "memo": "📝", "book": "📖", "books": "📚",
        "calendar": "📅", "date": "📅", "hourglass": "⌛", "watch": "⌚", "alarm_clock": "⏰",
        "rocket": "🚀", "ship": "🚢", "car": "🚗", "bike": "🚲", "airplane": "✈️",
        "coffee": "☕", "tea": "🍵", "beer": "🍺", "pizza": "🍕", "apple": "🍎",
        "sunny": "☀️", "cloud": "☁️", "umbrella": "☔", "snowflake": "❄️", "snowman": "⛄",
        "dog": "🐶", "cat": "🐱", "mouse": "🐭", "panda_face": "🐼", "monkey": "🐵",
        "octocat": "🐙", "shipit": "🐙", "bug": "🐛", "bee": "🐝", "snail": "🐌",
        "computer": "💻", "keyboard": "⌨️", "iphone": "📱", "email": "📧", "envelope": "✉️",
        "mailbox": "📫", "inbox_tray": "📥", "outbox_tray": "📤", "package": "📦",
        "file_folder": "📁", "page_facing_up": "📄", "chart_with_upwards_trend": "📈",
        "heavy_plus_sign": "➕", "heavy_minus_sign": "➖", "heavy_multiplication_x": "✖️",
        "recycle": "♻️", "arrow_right": "➡️", "arrow_left": "⬅️", "arrow_up": "⬆️",
        "arrow_down": "⬇️", "fast_forward": "⏩", "rewind": "⏪", "twisted_rightwards_arrows": "🔀",
        "hash": "#⃣", "zero": "0️⃣", "one": "1️⃣", "two": "2️⃣", "three": "3️⃣",
        "four": "4️⃣", "five": "5️⃣", "six": "6️⃣", "seven": "7️⃣", "eight": "8️⃣",
        "nine": "9️⃣", "keycap_ten": "🔟", "construction": "🚧", "hammer": "🔨",
        "wrench": "🔧", "gear": "⚙️", "triangular_flag_on_post": "🚩", "checkered_flag": "🏁",
        "rainbow": "🌈", "unicorn": "🦄", "ghost": "👻", "skull": "💀", "robot": "🤖",
        "poop": "💩", "hankey": "💩", "see_no_evil": "🙈", "hear_no_evil": "🙉",
        "speak_no_evil": "🙊", "clap_tone": "👏", "raised_hand": "✋", "v": "✌️",
        "peace": "✌️", "ok": "🆗", "new": "🆕", "free": "🆓", "cool": "🆒",
        "sos": "🆘", "up": "🆙", "vs": "🆚", "copyright": "©️", "registered": "®️",
        "tm": "™️"
    ]
}

enum MarkdownResourceResolver {
    static func imageURL(_ raw: String, relativeTo baseURL: URL?) -> URL? {
        if let absolute = URL(string: raw), let scheme = absolute.scheme?.lowercased() {
            guard scheme == "file" || scheme == "http" || scheme == "https" else { return nil }
            return absolute.standardized
        }
        guard let baseURL else { return nil }
        return URL(fileURLWithPath: raw, relativeTo: baseURL).standardizedFileURL
    }

    static func linkURL(_ raw: String, relativeTo baseURL: URL?) -> URL? {
        if let absolute = URL(string: raw), let scheme = absolute.scheme?.lowercased() {
            guard scheme == "http" || scheme == "https" || scheme == "file" else { return nil }
            return absolute
        }
        guard let baseURL else { return nil }
        return URL(fileURLWithPath: raw, relativeTo: baseURL).standardizedFileURL
    }

    static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return false }
        if host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") { return false }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 {
            let first = parts[0]
            let second = parts[1]
            if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
            if first == 169 && second == 254 { return false }
            if first == 172 && (16...31).contains(second) { return false }
            if first == 192 && second == 168 { return false }
            if first == 100 && (64...127).contains(second) { return false }
        }
        return true
    }

    static func mayLoadImage(
        _ url: URL,
        loadLocalImages: Bool = true,
        loadRemoteImages: Bool
    ) -> Bool {
        if url.isFileURL {
            return loadLocalImages
        }
        return loadRemoteImages && isAllowedRemoteURL(url)
    }

    static func imagePlaceholder(
        alt: String,
        resolvedURL: URL?,
        loadLocalImages: Bool,
        loadRemoteImages: Bool
    ) -> String {
        let reason: String?
        if let resolvedURL, resolvedURL.isFileURL, !loadLocalImages {
            reason = "local image blocked"
        } else if let resolvedURL, !resolvedURL.isFileURL, !loadRemoteImages {
            reason = "remote image blocked"
        } else if resolvedURL == nil {
            reason = "image unavailable"
        } else {
            reason = nil
        }

        guard let reason else { return alt }
        return alt.isEmpty ? reason.capitalized : "\(alt) (\(reason))"
    }
}

enum RemoteImageLoadError: Error, Equatable {
    case disallowedURL
    case invalidResponse
    case responseTooLarge
}

final class RemoteImageRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(MarkdownResourceResolver.isAllowedRemoteURL) == true ? request : nil)
    }
}

enum RemoteImageLoader {
    static let maximumBytes = 10 * 1024 * 1024

    static func data(from url: URL, session providedSession: URLSession? = nil) async throws -> Data {
        guard MarkdownResourceResolver.isAllowedRemoteURL(url) else { throw RemoteImageLoadError.disallowedURL }
        let session: URLSession
        if let providedSession {
            session = providedSession
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            session = URLSession(configuration: configuration)
        }
        defer { if providedSession == nil { session.invalidateAndCancel() } }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let delegate = RemoteImageRedirectDelegate()
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RemoteImageLoadError.invalidResponse
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw RemoteImageLoadError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(max(0, min(Int(response.expectedContentLength), maximumBytes)))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw RemoteImageLoadError.responseTooLarge }
            data.append(byte)
        }
        return data
    }
}
