import AppKit
import SwiftUI
import XCTest
@testable import VulkanGlass

final class WikiLinkPickerTests: XCTestCase {
    @MainActor
    func testReplacingHostingRootRendersEachNoteOnce() async {
        var original = [note(0), note(1), note(2)]
        original[1].title = original[0].title
        let replacement = [note(2), note(3), note(1)]
        var renderedRows: [WikiLinkPickerRowLayout] = []
        let host = NSHostingView(rootView: picker(notes: original, selected: 0) { renderedRows = $0 })
        let window = show(host)
        defer { window.orderOut(nil) }

        await settle(host)
        XCTAssertEqual(renderedRows.map(\.path), original.map(\.path))

        host.rootView = picker(notes: replacement, selected: 1) { renderedRows = $0 }
        await settle(host)
        XCTAssertEqual(renderedRows.map(\.path), replacement.map(\.path))
    }

    @MainActor
    func testSelectionScrollsToNotePathAndIgnoresInvalidIndices() async throws {
        var notes = (0..<25).map(note)
        notes[notes.count - 1].title = notes[0].title
        var renderedRows: [WikiLinkPickerRowLayout] = []
        let observe: ([WikiLinkPickerRowLayout]) -> Void = { renderedRows = $0 }
        let host = NSHostingView(rootView: picker(notes: notes, selected: 0, onRowsMeasured: observe))
        let window = show(host)
        defer { window.orderOut(nil) }
        await settle(host)

        let scrollView = try XCTUnwrap(firstSubview(of: NSScrollView.self, in: host))
        let initialOffset = scrollView.contentView.bounds.origin.y
        host.rootView = picker(notes: notes, selected: notes.count - 1, onRowsMeasured: observe)
        await settle(host)

        let scrolledOffset = scrollView.contentView.bounds.origin.y
        XCTAssertNotEqual(scrolledOffset, initialOffset)
        let lastRow = try XCTUnwrap(renderedRows.first { $0.path == notes.last?.path })
        let viewport = CGRect(origin: .zero, size: scrollView.contentView.bounds.size)
        XCTAssertTrue(viewport.intersects(lastRow.frame), "Selected row should be inside the scroll viewport")

        host.rootView = picker(notes: notes, selected: notes.count, onRowsMeasured: observe)
        await settle(host)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, scrolledOffset, accuracy: 1)

        host.rootView = picker(notes: notes, selected: -1, onRowsMeasured: observe)
        await settle(host)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, scrolledOffset, accuracy: 1)
    }

    @MainActor
    private func picker(
        notes: [NoteMeta],
        selected: Int,
        onRowsMeasured: @escaping ([WikiLinkPickerRowLayout]) -> Void
    ) -> WikiLinkPickerView {
        WikiLinkPickerView(
            notes: notes,
            selected: selected,
            dark: false,
            onChoose: { _ in },
            onRowsMeasured: onRowsMeasured
        )
    }

    private func note(_ number: Int) -> NoteMeta {
        let name = String(format: "Note %02d", number)
        return NoteMeta(
            path: "/vault/\(name).md",
            relativePath: "\(name).md",
            title: name,
            content: "",
            tags: [],
            wikiLinks: [],
            headings: []
        )
    }

    @MainActor
    private func show(_ host: NSHostingView<WikiLinkPickerView>) -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 360, height: 160)
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        return window
    }

    @MainActor
    private func settle(_ host: NSHostingView<WikiLinkPickerView>) async {
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    private func firstSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        for child in root.subviews {
            if let match = child as? T { return match }
            if let match = firstSubview(of: type, in: child) { return match }
        }
        return nil
    }
}
