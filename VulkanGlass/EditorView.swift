import AppKit
import SwiftUI

/// Native NSTextView source editor with `[[` wiki-link completion.
struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    var notes: [NoteMeta]
    var dark: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: { text = $0 })
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = SourceTextView()
        textView.delegate = context.coordinator
        textView.wikiHandler = context.coordinator
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
        context.coordinator.notes = notes
        context.coordinator.dark = dark
        applyChrome(textView)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onChange = { text = $0 }
        context.coordinator.notes = notes
        context.coordinator.dark = dark
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        applyChrome(textView)
        context.coordinator.refreshWikiPopup()
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.dismissPopup()
        if let textView = nsView.documentView as? SourceTextView {
            textView.delegate = nil
            textView.wikiHandler = nil
        }
        coordinator.textView = nil
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

    final class Coordinator: NSObject, NSTextViewDelegate, WikiLinkKeyHandling {
        var onChange: (String) -> Void
        weak var textView: SourceTextView?
        var notes: [NoteMeta] = []
        var dark = true
        private let popup = WikiLinkPopupController()
        private var session: WikiLinkSession?
        private var suggestions: [NoteMeta] = []
        private var selected = 0
        private var dismissedMarker: Int?

        var isPopupVisible: Bool { popup.isVisible }
        var selectedSuggestionIndex: Int { selected }

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
            super.init()
            popup.onChoose = { [weak self] note in
                self?.insert(note)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            onChange(tv.string)
            refreshWikiPopup()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            refreshWikiPopup()
        }

        func refreshWikiPopup() {
            guard let textView else {
                popup.dismiss()
                return
            }
            let next = WikiLinkSuggest.session(in: textView.string, utf16Cursor: textView.selectedRange().location)
            guard let next, next.allowsNoteSuggestions, !notes.isEmpty else {
                session = nil
                dismissedMarker = nil
                popup.dismiss()
                return
            }
            if next.query != session?.query {
                selected = 0
                dismissedMarker = nil
            }
            if dismissedMarker == next.markerRange.location {
                session = next
                popup.dismiss()
                return
            }
            suggestions = WikiLinkSuggest.suggestions(from: notes, query: next.query)
            session = next
            if selected >= suggestions.count { selected = max(0, suggestions.count - 1) }
            let caret = textView.firstRect(
                forCharacterRange: NSRange(location: next.markerRange.location, length: 2),
                actualRange: nil
            )
            popup.show(notes: suggestions, selected: selected, caret: caret, dark: dark)
        }

        func handleCommand(_ selector: Selector) -> Bool {
            guard popup.isVisible else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                moveSelection(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                moveSelection(-1)
                return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                confirmSelection()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                dismissedMarker = session?.markerRange.location
                popup.dismiss()
                return true
            default:
                return false
            }
        }

        func dismissPopup() {
            session = nil
            suggestions = []
            dismissedMarker = nil
            popup.dismiss()
        }

        func dismissWikiPopup() {
            dismissPopup()
        }

        private func moveSelection(_ delta: Int) {
            guard !suggestions.isEmpty else { return }
            selected = min(max(selected + delta, 0), suggestions.count - 1)
            popup.updateSelection(selected)
        }

        private func confirmSelection() {
            if suggestions.indices.contains(selected) {
                insert(suggestions[selected])
            } else if let session, !session.query.isEmpty {
                insert(raw: session.query)
            } else {
                popup.dismiss()
            }
        }

        private func insert(_ note: NoteMeta) {
            insert(raw: WikiLinkSuggest.insertTarget(for: note, among: notes))
        }

        private func insert(raw target: String) {
            guard let textView, let session else { return }
            let replacement = WikiLinkSuggest.replacement(target: target, in: session)
            let range = session.queryRange
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
                let end = range.location + (replacement as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
            }
            popup.dismiss()
        }
    }
}

/// Forwards movement keys to wiki-link completion while the popup is open.
final class SourceTextView: NSTextView {
    weak var wikiHandler: WikiLinkKeyHandling?

    override func doCommand(by selector: Selector) {
        if wikiHandler?.handleCommand(selector) == true { return }
        super.doCommand(by: selector)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { wikiHandler?.dismissWikiPopup() }
        return resigned
    }
}

protocol WikiLinkKeyHandling: AnyObject {
    func handleCommand(_ selector: Selector) -> Bool
    func dismissWikiPopup()
}

/// Floating candidate list anchored to the caret, matching Obsidian's wiki-link picker.
final class WikiLinkPopupController {
    var onChoose: ((NoteMeta) -> Void)?
    private let panel: NSPanel
    private var hosting: NSHostingView<WikiLinkPickerView>?

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }

    func show(notes: [NoteMeta], selected: Int, caret: NSRect, dark: Bool) {
        let root = WikiLinkPickerView(
            notes: notes,
            selected: selected,
            dark: dark,
            onChoose: { [weak self] note in self?.onChoose?(note) }
        )
        let host: NSHostingView<WikiLinkPickerView>
        if let hosting {
            hosting.rootView = root
            host = hosting
        } else {
            host = NSHostingView(rootView: root)
            hosting = host
            panel.contentView = host
        }
        let height = min(300, CGFloat(max(notes.count, 1)) * 44 + 36)
        let size = NSSize(width: 360, height: height)
        host.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)

        let screen = NSScreen.main?.visibleFrame ?? caret
        var origin = NSPoint(x: caret.minX, y: caret.minY - 6 - size.height)
        if origin.y < screen.minY {
            origin.y = caret.maxY + 6
        }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    func updateSelection(_ selected: Int) {
        guard let hosting else { return }
        var root = hosting.rootView
        root.selected = selected
        hosting.rootView = root
    }

    func dismiss() {
        panel.orderOut(nil)
    }
}

struct WikiLinkPickerView: View {
    var notes: [NoteMeta]
    var selected: Int
    var dark: Bool
    var onChoose: (NoteMeta) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if notes.isEmpty {
                Text("No matching notes")
                    .font(.caption)
                    .foregroundStyle(VGTheme.textMuted(dark: dark))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                                Button {
                                    onChoose(note)
                                } label: {
                                    HStack(spacing: 0) {
                                        Rectangle()
                                            .fill(index == selected ? VGTheme.accent : Color.clear)
                                            .frame(width: 2)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(note.title)
                                                .foregroundStyle(VGTheme.textNormal(dark: dark))
                                            let folder = WikiLinkSuggest.folderLabel(for: note)
                                            if !folder.isEmpty {
                                                Text(folder)
                                                    .font(.caption2)
                                                    .foregroundStyle(VGTheme.textFaint(dark: dark))
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(index == selected ? VGTheme.hover(dark: dark) : Color.clear)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                    }
                    .onChange(of: selected) { _, value in
                        proxy.scrollTo(value, anchor: .center)
                    }
                    .onAppear { proxy.scrollTo(selected, anchor: .center) }
                }
            }
            VGTheme.divider(dark: dark).frame(height: 1)
            Text("Enter to insert · Esc to dismiss")
                .font(.caption2)
                .foregroundStyle(VGTheme.textFaint(dark: dark))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .frame(width: 360)
        .background(VGTheme.backgroundSecondary(dark: dark))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(VGTheme.divider(dark: dark), lineWidth: 1)
        )
        .preferredColorScheme(dark ? .dark : .light)
    }
}

struct NoteEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming = false

    var body: some View {
        if let tab = model.activeTab, let index = model.tabs.firstIndex(where: { $0.id == tab.id }) {
            VStack(alignment: .leading, spacing: 0) {
                titleRow(tab)
                if model.editorMode == .preview {
                    MarkdownPreviewView(
                        text: tab.content,
                        noteTitles: Set(model.notes.map { $0.title.lowercased() })
                    ) { target in
                        Task { await model.followWikiLink(target) }
                    }
                } else {
                    SourceEditor(
                        text: Bindable(model).tabs[index].content,
                        notes: model.notes,
                        dark: model.dark
                    )
                        .onChange(of: model.tabs[index].content) { _, newValue in
                            model.updateContent(tab.id, newValue)
                        }
                }
            }
            .onChange(of: tab.path) { _, _ in
                renaming = false
            }
        } else {
            Text("No file is open. Create a note or open a Markdown file.")
                .foregroundStyle(VGTheme.textFaint(dark: model.dark))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func titleRow(_ tab: NoteTab) -> some View {
        Group {
            if renaming {
                InlineRenameField(
                    text: tab.title,
                    font: .system(size: 34, weight: .bold)
                ) { name in
                    renaming = false
                    Task { await model.renameNote(path: tab.path, newName: name) }
                } onCancel: {
                    renaming = false
                }
            } else {
                Text(tab.title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(VGTheme.textNormal(dark: model.dark))
                    .contentShape(Rectangle())
                    .onTapGesture { renaming = true }
                    .help("Rename")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Renames this note")
            }
        }
        .tracking(-0.4)
        .padding(.horizontal, 56)
        .padding(.top, 24)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inline text field used to rename a note title or file tree entry.
struct InlineRenameField: View {
    let text: String
    var font: Font = .body
    var onCommit: (String) -> Void
    var onCancel: () -> Void
    @State private var draft: String
    @State private var finished = false
    @FocusState private var focused: Bool

    init(
        text: String,
        font: Font = .body,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.text = text
        self.font = font
        self.onCommit = onCommit
        self.onCancel = onCancel
        _draft = State(initialValue: text)
    }

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit { commit() }
            .onExitCommand { cancel() }
            .onChange(of: focused) { _, on in
                if !on { commit() }
            }
    }

    private func commit() {
        guard !finished else { return }
        finished = true
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            onCancel()
        } else {
            onCommit(value)
        }
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        onCancel()
    }
}
