import SwiftUI

/// Reading view: headings, lists, teal wiki links, and tag pills.
struct MarkdownPreviewView: View {
    let text: String
    let noteTitles: Set<String>
    var onWiki: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(displayBlocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .padding(.horizontal, 56)
            .padding(.bottom, 96)
            .frame(maxWidth: 780, alignment: .leading)
        }
    }

    /// Drops a leading H1 that duplicates the inline note title.
    private var displayBlocks: [String] {
        var items = blocks
        if let first = items.first, first.hasPrefix("# "), !first.hasPrefix("## ") {
            items.removeFirst()
        }
        return items
    }

    private var blocks: [String] {
        var result: [String] = []
        var buffer: [String] = []
        var inCode = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    buffer.append(line)
                    result.append(buffer.joined(separator: "\n"))
                    buffer = []
                    inCode = false
                } else {
                    if !buffer.isEmpty {
                        result.append(buffer.joined(separator: "\n"))
                        buffer = []
                    }
                    buffer.append(line)
                    inCode = true
                }
            } else if inCode {
                buffer.append(line)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !buffer.isEmpty {
                    result.append(buffer.joined(separator: "\n"))
                    buffer = []
                }
            } else {
                buffer.append(line)
            }
        }
        if !buffer.isEmpty { result.append(buffer.joined(separator: "\n")) }
        return result
    }

    @ViewBuilder
    private func blockView(_ block: String) -> some View {
        if block.hasPrefix("```") {
            let code = block.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n")
            Text(code)
                .font(.system(.body, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VGTheme.backgroundSecondary(dark: true).opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let heading = heading(block) {
            InlineRunsView(text: heading.text, noteTitles: noteTitles, onWiki: onWiki)
                .font(heading.font)
                .fontWeight(.bold)
                .padding(.top, heading.font == .title ? 4 : 10)
        } else if block.hasPrefix("> ") {
            HStack(alignment: .top, spacing: 12) {
                VGTheme.accent.frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(block.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        let clipped = line.hasPrefix("> ") ? String(line.dropFirst(2)) : line
                        InlineRunsView(text: clipped, noteTitles: noteTitles, onWiki: onWiki)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(block.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
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
                InlineRunsView(text: String(line.dropFirst(6)), noteTitles: noteTitles, onWiki: onWiki)
            }
        } else if line.hasPrefix("- ") {
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundStyle(VGTheme.textMuted(dark: true))
                InlineRunsView(text: String(line.dropFirst(2)), noteTitles: noteTitles, onWiki: onWiki)
            }
        } else {
            InlineRunsView(text: line, noteTitles: noteTitles, onWiki: onWiki)
                .lineSpacing(6)
        }
    }

    private func heading(_ block: String) -> (text: String, font: Font)? {
        if block.hasPrefix("###### ") { return (String(block.dropFirst(7)), .title3) }
        if block.hasPrefix("##### ") { return (String(block.dropFirst(6)), .title3) }
        if block.hasPrefix("#### ") { return (String(block.dropFirst(5)), .title3) }
        if block.hasPrefix("### ") { return (String(block.dropFirst(4)), .title2) }
        if block.hasPrefix("## ") { return (String(block.dropFirst(3)), .title2) }
        if block.hasPrefix("# ") { return (String(block.dropFirst(2)), .largeTitle) }
        return nil
    }
}

enum InlineRun: Identifiable, Equatable {
    case text(String)
    case wiki(target: String, label: String)
    case tag(String)

    var id: String {
        switch self {
        case .text(let value): return "t-\(value)"
        case .wiki(let target, let label): return "w-\(target)-\(label)"
        case .tag(let value): return "g-\(value)"
        }
    }
}

struct InlineRunsView: View {
    let text: String
    let noteTitles: Set<String>
    var onWiki: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                switch run {
                case .text(let value):
                    Text(value)
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
                }
            }
        }
    }

    private var runs: [InlineRun] {
        Self.parse(text)
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
