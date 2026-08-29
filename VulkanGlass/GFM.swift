import Foundation

/// GitHub Flavored Markdown helpers shared by live preview and reading view.
enum GFM {
    struct TableMutation: Equatable {
        var replacement: String
        var selectionOffset: Int
    }

    enum AlertKind: String, Equatable, CaseIterable {
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

    enum Alignment: Equatable {
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

    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
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
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        if isHorizontalRule(trimmed) { return false }
        return splitTableRow(trimmed).count >= 2 || trimmed.hasPrefix("|")
    }

    static func splitTableRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let body: Substring
        if trimmed.hasPrefix("|") {
            body = trimmed.dropFirst()
        } else {
            body = Substring(trimmed)
        }
        let usable = body.hasSuffix("|") && !body.hasSuffix("\\|") ? body.dropLast() : body
        for ch in usable {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
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

    static func mayLoadImage(_ url: URL, loadRemoteImages: Bool) -> Bool {
        url.isFileURL || (loadRemoteImages && isAllowedRemoteURL(url))
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
