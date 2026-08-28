import SwiftUI

struct RightSidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                TitleBarIcon(
                    symbol: "point.3.connected.trianglepath.dotted",
                    help: "Local graph",
                    active: model.rightPanel == .graph
                ) {
                    model.rightPanel = .graph
                }
                TitleBarIcon(symbol: "link", help: "Backlinks", active: model.rightPanel == .backlinks) {
                    model.rightPanel = .backlinks
                }
                TitleBarIcon(
                    symbol: "list.bullet.indent",
                    help: "Outline",
                    active: model.rightPanel == .outline
                ) {
                    model.rightPanel = .outline
                }
                TitleBarIcon(symbol: "number", help: "Tags", active: model.rightPanel == .tags) {
                    model.rightPanel = .tags
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: VGTheme.titleBarHeight)
            .overlay(alignment: .bottom) {
                VGTheme.divider(dark: model.dark).frame(height: 1)
            }

            if model.rightPanel == .graph {
                GraphView(localOnly: true, showCaption: true)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            } else {
                ScrollView {
                    Group {
                        switch model.rightPanel {
                        case .graph: EmptyView()
                        case .backlinks: backlinks
                        case .outline: outline
                        case .tags: tags
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .clipped()
    }

    private var backlinks: some View {
        Group {
            if let tab = model.activeTab {
                let linked = model.notes.filter {
                    $0.wikiLinks.contains { $0.caseInsensitiveCompare(tab.title) == .orderedSame }
                }
                Text("LINKED MENTIONS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(VGTheme.textFaint(dark: model.dark))
                if linked.isEmpty {
                    Text("No backlinks found.").font(.caption).foregroundStyle(VGTheme.textFaint(dark: model.dark))
                } else {
                    ForEach(linked) { note in
                        Button(note.title) { Task { await model.openTab(path: note.path) } }
                            .buttonStyle(.plain)
                            .foregroundStyle(VGTheme.textAccent)
                            .padding(.top, 6)
                    }
                }
            } else {
                Text("Open a note to see backlinks.").font(.caption).foregroundStyle(VGTheme.textFaint(dark: model.dark))
            }
        }
    }

    private var outline: some View {
        Group {
            if let tab = model.activeTab {
                let headings = Markdown.headings(in: tab.content)
                if headings.isEmpty {
                    Text("No headings in this note.").font(.caption).foregroundStyle(VGTheme.textFaint(dark: model.dark))
                } else {
                    ForEach(Array(headings.enumerated()), id: \.offset) { _, heading in
                        Text(heading.text)
                            .padding(.leading, CGFloat(heading.level - 1) * 12)
                            .foregroundStyle(VGTheme.textMuted(dark: model.dark))
                    }
                }
            }
        }
    }

    private var tags: some View {
        let counts = Dictionary(model.notes.flatMap(\.tags).map { ($0, 1) }, uniquingKeysWith: +)
        return Group {
            if counts.isEmpty {
                Text("No tags in this vault.").font(.caption).foregroundStyle(VGTheme.textFaint(dark: model.dark))
            } else {
                ForEach(counts.keys.sorted(), id: \.self) { tag in
                    HStack {
                        Text("#\(tag)")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(VGTheme.accent.opacity(0.22))
                            .foregroundStyle(VGTheme.textAccent)
                            .clipShape(Capsule())
                        Spacer()
                        Text("\(counts[tag] ?? 0)").foregroundStyle(VGTheme.textFaint(dark: model.dark))
                    }
                }
            }
        }
    }
}
