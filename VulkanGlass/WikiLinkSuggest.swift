import Foundation

/// The open `[[query` under the caret, if the user is currently writing a wiki link.
struct WikiLinkSession: Equatable {
    /// UTF-16 range of the opening `[[`.
    var markerRange: NSRange
    /// UTF-16 range between `[[` and the caret.
    var queryRange: NSRange
    /// Filter text, with heading (`#`) and alias (`|`) suffixes removed.
    var query: String
    /// Existing heading or alias suffix, beginning with `#` or `|`.
    var suffix: String
    /// Whether this session expects a note target rather than a current-note heading.
    var allowsNoteSuggestions: Bool
}

enum WikiLinkSuggest {
    static let limit = 50

    /// Returns the active wiki-link session at `utf16Cursor`, or `nil` if none.
    static func session(in text: String, utf16Cursor: Int) -> WikiLinkSession? {
        let ns = text as NSString
        let cursor = min(max(0, utf16Cursor), ns.length)
        guard cursor >= 2 else { return nil }
        if isInsideFencedCode(ns, cursor: cursor) { return nil }

        var lineStart = 0
        let probe = cursor == 0 ? 0 : cursor - 1
        ns.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: probe, length: 0))
        let prefixRange = NSRange(location: lineStart, length: cursor - lineStart)
        let marker = ns.range(of: "[[", options: .backwards, range: prefixRange)
        guard marker.location != NSNotFound else { return nil }

        let afterMarker = marker.location + marker.length
        let queryRange = NSRange(location: afterMarker, length: cursor - afterMarker)
        let raw = ns.substring(with: queryRange)
        if raw.contains("]]") { return nil }

        let separator = raw.firstIndex { $0 == "#" || $0 == "|" }
        let query = separator.map { String(raw[..<$0]) } ?? raw
        let suffix = separator.map { String(raw[$0...]) } ?? ""
        return WikiLinkSession(
            markerRange: marker,
            queryRange: queryRange,
            query: query,
            suffix: suffix,
            allowsNoteSuggestions: !raw.hasPrefix("#")
        )
    }

    /// Completed text for the full range between `[[` and the caret.
    static func replacement(target: String, in session: WikiLinkSession) -> String {
        target + session.suffix + "]]"
    }

    /// Notes whose title or path match `query`, best matches first.
    static func suggestions(from notes: [NoteMeta], query: String) -> [NoteMeta] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scored: [(NoteMeta, Int)] = notes.compactMap { note in
            guard let rank = rank(note, query: q) else { return nil }
            return (note, rank)
        }
        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending
        }
        .prefix(limit)
        .map(\.0)
    }

    /// Wiki target to insert: title when unique, otherwise the vault-relative path.
    static func insertTarget(for note: NoteMeta, among notes: [NoteMeta]) -> String {
        let duplicates = notes.filter { $0.title.caseInsensitiveCompare(note.title) == .orderedSame }
        if duplicates.count > 1 {
            return wikiPath(note.relativePath)
        }
        return note.title
    }

    /// Folder subtitle shown under the note title, e.g. `Ideas/`.
    static func folderLabel(for note: NoteMeta) -> String {
        let parent = (note.relativePath as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return "" }
        return parent.hasSuffix("/") ? parent : parent + "/"
    }

    private static func rank(_ note: NoteMeta, query: String) -> Int? {
        if query.isEmpty { return 2 }
        let title = note.title.lowercased()
        let path = wikiPath(note.relativePath).lowercased()
        if title == query || path == query { return 0 }
        if title.hasPrefix(query) { return 1 }
        if path.hasPrefix(query) { return 2 }
        if title.contains(query) { return 3 }
        if path.contains(query) || note.relativePath.lowercased().contains(query) { return 4 }
        return nil
    }

    private static func wikiPath(_ relativePath: String) -> String {
        var path = relativePath
        if path.lowercased().hasSuffix(".md") {
            path = String(path.dropLast(3))
        }
        return path
    }

    private static func isInsideFencedCode(_ ns: NSString, cursor: Int) -> Bool {
        let prefix = ns.substring(to: cursor) as String
        var count = 0
        var search = prefix.startIndex
        while let range = prefix.range(of: "```", range: search..<prefix.endIndex) {
            count += 1
            search = range.upperBound
        }
        return count % 2 == 1
    }
}
