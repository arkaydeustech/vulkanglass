import AppKit
import SwiftUI

/// Native NSTextView source editor.
struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    var dark: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: { text = $0 })
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .systemFont(ofSize: 16)
        textView.textContainerInset = NSSize(width: 40, height: 8)
        textView.drawsBackground = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        scroll.documentView = textView
        context.coordinator.textView = textView
        applyChrome(textView)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onChange = { text = $0 }
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        applyChrome(textView)
    }

    private func applyChrome(_ textView: NSTextView) {
        textView.textColor = dark
            ? NSColor(red: 0.86, green: 0.87, blue: 0.87, alpha: 1)
            : NSColor.textColor
        textView.insertionPointColor = NSColor(red: 0.08, green: 0.72, blue: 0.65, alpha: 1)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(red: 0.08, green: 0.72, blue: 0.65, alpha: 0.28)
        ]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        weak var textView: NSTextView?

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            onChange(tv.string)
        }
    }
}

struct TabBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.tabs) { tab in
                        let active = tab.id == model.activeTabID
                        HStack(spacing: 6) {
                            Button {
                                model.setActiveTab(tab.id)
                            } label: {
                                Text((tab.dirty ? "• " : "") + tab.title)
                                    .lineLimit(1)
                                    .foregroundStyle(active ? VGTheme.textNormal(dark: model.dark) : VGTheme.textMuted(dark: model.dark))
                            }
                            .buttonStyle(.plain)
                            Button {
                                Task { await model.closeTab(tab.id) }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(VGTheme.textFaint(dark: model.dark))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .frame(minWidth: 120, maxWidth: 220)
                        .background(active ? VGTheme.backgroundPrimary(dark: model.dark) : Color.clear)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(active ? VGTheme.accent : Color.clear)
                                .frame(height: 2)
                        }
                        .overlay(alignment: .trailing) {
                            VGTheme.divider(dark: model.dark).frame(width: 1)
                        }
                    }
                }
            }
            Button {
                Task { await model.newNote() }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 36, height: 36)
                    .foregroundStyle(VGTheme.textMuted(dark: model.dark))
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                model.editorMode = model.editorMode == .source ? .preview : .source
            } label: {
                Image(systemName: model.editorMode == .source ? "book" : "square.and.pencil")
                    .frame(width: 28, height: 36)
                    .foregroundStyle(model.editorMode == .preview ? VGTheme.textAccent : VGTheme.textMuted(dark: model.dark))
            }
            .buttonStyle(.plain)
            .help("Toggle reading view")
            Button {
                model.rightOpen.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .frame(width: 28, height: 36)
                    .foregroundStyle(model.rightOpen ? VGTheme.textAccent : VGTheme.textMuted(dark: model.dark))
            }
            .buttonStyle(.plain)
            .help("Toggle right sidebar")
        }
        .background(VGTheme.backgroundSecondary(dark: model.dark))
        .overlay(alignment: .bottom) {
            VGTheme.divider(dark: model.dark).frame(height: 1)
        }
    }
}

struct NoteEditorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let tab = model.activeTab, let index = model.tabs.firstIndex(where: { $0.id == tab.id }) {
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title)
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.4)
                    .padding(.horizontal, 56)
                    .padding(.top, 24)
                    .padding(.bottom, 4)
                    .foregroundStyle(VGTheme.textNormal(dark: model.dark))
                if model.editorMode == .preview {
                    MarkdownPreviewView(
                        text: tab.content,
                        noteTitles: Set(model.notes.map { $0.title.lowercased() })
                    ) { target in
                        Task { await model.followWikiLink(target) }
                    }
                } else {
                    SourceEditor(text: Bindable(model).tabs[index].content, dark: model.dark)
                        .onChange(of: model.tabs[index].content) { _, newValue in
                            model.updateContent(tab.id, newValue)
                        }
                }
            }
        } else {
            Text("No file is open. Create a note or open a Markdown file.")
                .foregroundStyle(VGTheme.textFaint(dark: model.dark))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
