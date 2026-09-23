import XCTest
import AppKit
import SwiftUI
@testable import VulkanGlass

@MainActor
final class PaletteSearchFieldTests: XCTestCase {
    func testPaletteFieldTakesFocusFromDocumentSoTypingGoesToTheQuery() async throws {
        var query = ""
        let (window, document, field, coordinator) = makePalette(query: { query }, setQuery: { query = $0 })
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(document))

        coordinator.attach(field)
        await drainMainQueue()

        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(coordinator.previousResponder === document)

        editor.insertText("graph", replacementRange: editor.selectedRange())
        coordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )

        XCTAssertEqual(query, "graph")
        XCTAssertEqual(document.string, "Note body")
    }

    func testPaletteFieldRetriesFocusUntilItIsInAWindow() async {
        var attempts = 0
        let focused = expectation(description: "Third focus attempt succeeds")
        let coordinator = PaletteSearchField.Coordinator(
            parent: PaletteSearchField(text: .constant(""), placeholder: "", onSubmit: {}, onCancel: {}),
            focus: { _ in
                attempts += 1
                if attempts == 3 { focused.fulfill() }
                return attempts == 3
            }
        )

        let field = NSTextField()
        coordinator.attach(field)
        await fulfillment(of: [focused], timeout: 1)
        for _ in 0..<3 { await drainMainQueue() }

        XCTAssertEqual(attempts, 3)
        withExtendedLifetime(field) {}
    }

    func testPaletteFieldReturnSubmitsAndEscapeCancels() {
        var submits = 0
        var cancels = 0
        let coordinator = PaletteSearchField.Coordinator(
            parent: PaletteSearchField(
                text: .constant("new"),
                placeholder: "Type a command…",
                onSubmit: { submits += 1 },
                onCancel: { cancels += 1 }
            ),
            focus: { _ in true }
        )
        let field = NSTextField()
        let editor = NSTextView()

        XCTAssertTrue(coordinator.control(
            field,
            textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        XCTAssertTrue(coordinator.control(
            field,
            textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))
        XCTAssertFalse(coordinator.control(
            field,
            textView: editor,
            doCommandBy: #selector(NSResponder.moveLeft(_:))
        ))

        XCTAssertEqual(submits, 1)
        XCTAssertEqual(cancels, 1)
    }

    func testDismissingPaletteReturnsFocusToTheDocument() async {
        let (window, document, field, coordinator) = makePalette(query: { "" }, setQuery: { _ in })
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(document))
        coordinator.attach(field)
        await drainMainQueue()
        XCTAssertFalse(window.firstResponder === document)

        coordinator.prepareForDismantle()
        field.removeFromSuperview()
        await drainMainQueue()

        XCTAssertTrue(window.firstResponder === document)
    }

    func testDismissingPaletteKeepsFocusACommandMovedElsewhere() async {
        let (window, document, field, coordinator) = makePalette(query: { "" }, setQuery: { _ in })
        defer { window.orderOut(nil) }
        let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        window.contentView?.addSubview(other)
        XCTAssertTrue(window.makeFirstResponder(document))
        coordinator.attach(field)
        await drainMainQueue()

        coordinator.prepareForDismantle()
        field.removeFromSuperview()
        XCTAssertTrue(window.makeFirstResponder(other))
        await drainMainQueue()

        XCTAssertTrue(window.firstResponder === other)
    }

    func testPaletteRemembersTheOwningControlRatherThanASharedFieldEditor() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let other = NSTextField(frame: NSRect(x: 20, y: 70, width: 180, height: 24))
        let palette = NSTextField(frame: NSRect(x: 20, y: 30, width: 180, height: 24))
        window.contentView?.addSubview(other)
        window.contentView?.addSubview(palette)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(other))
        let editor = try XCTUnwrap(other.currentEditor())

        XCTAssertTrue(
            PaletteSearchField.Coordinator.restorableResponder(editor, excluding: palette) === other
        )
        XCTAssertNil(PaletteSearchField.Coordinator.restorableResponder(window, excluding: palette))
        XCTAssertNil(PaletteSearchField.Coordinator.restorableResponder(palette, excluding: palette))
    }

    private func makePalette(
        query: @escaping () -> String,
        setQuery: @escaping (String) -> Void
    ) -> (NSWindow, NSTextView, NSTextField, PaletteSearchField.Coordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let document = SourceTextView(frame: NSRect(x: 0, y: 60, width: 400, height: 140))
        document.string = "Note body"
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 300, height: 24))
        window.contentView?.addSubview(document)
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        let coordinator = PaletteSearchField.Coordinator(
            parent: PaletteSearchField(
                text: Binding(get: query, set: setQuery),
                placeholder: "Type a command…",
                onSubmit: {},
                onCancel: {}
            )
        )
        field.delegate = coordinator
        return (window, document, field, coordinator)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
