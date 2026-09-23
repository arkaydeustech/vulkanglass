import XCTest
import AppKit
import SwiftUI
@testable import VulkanGlass

@MainActor
final class PaletteSearchFieldTests: XCTestCase {
    func testHostedCommandPaletteAndQuickSwitcherTakeKeyboardFocusAndRestoreIt() async throws {
        for kind in [PaletteKind.command, .switcher] {
            let model = AppModel(settings: .default(), bootstrapOnLaunch: false)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            defer { window.orderOut(nil) }
            let document = SourceTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
            document.string = "Note body"
            let updater = AppUpdater(configuration: UpdateConfiguration(info: [:]), disabled: true)
            let hostingView = NSHostingView(rootView: RootView(updater: updater).environment(model))
            hostingView.frame = window.contentView!.bounds
            window.contentView?.addSubview(document)
            window.contentView?.addSubview(hostingView)
            window.makeKeyAndOrderFront(nil)
            XCTAssertTrue(window.makeFirstResponder(document))

            switch kind {
            case .command:
                model.commandOpen = true
            case .switcher:
                model.switcherOpen = true
            }
            let mountedField = await waitForPaletteField(in: hostingView)
            let field = try XCTUnwrap(mountedField)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            XCTAssertTrue(window.firstResponder === editor, "\(kind) should own first responder")

            sendKey("g", keyCode: 5, to: window)
            XCTAssertEqual(field.stringValue, "g")
            let coordinator = try XCTUnwrap(field.delegate as? PaletteSearchField.Coordinator)
            XCTAssertEqual(coordinator.parent.text, "g")
            XCTAssertEqual(document.string, "Note body")

            switch kind {
            case .command: model.commandOpen = false
            case .switcher: model.switcherOpen = false
            }
            hostingView.layoutSubtreeIfNeeded()
            await drainMainQueue()
            XCTAssertNil(paletteField(in: hostingView))
            XCTAssertTrue(window.firstResponder === document, "\(kind) should restore the editor")
        }
    }

    func testHostedSearchFieldPreservesActiveDraftDuringBindingUpdates() async throws {
        let state = PaletteQueryState()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let hostingView = NSHostingView(rootView: HostedPaletteSearchField(state: state))
        hostingView.frame = window.contentView!.bounds
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        let mountedField = await waitForPaletteField(in: hostingView)
        let field = try XCTUnwrap(mountedField)

        sendKey("x", keyCode: 7, to: window)
        XCTAssertEqual(field.stringValue, "x")
        XCTAssertEqual(state.text, "x")

        state.text = "external"
        hostingView.layoutSubtreeIfNeeded()
        await drainMainQueue()
        XCTAssertEqual(field.stringValue, "x", "An active field editor keeps its draft")

        XCTAssertTrue(window.makeFirstResponder(hostingView))
        state.text = "replacement"
        hostingView.layoutSubtreeIfNeeded()
        await drainMainQueue()
        XCTAssertEqual(field.stringValue, "replacement")

        state.show = false
        hostingView.layoutSubtreeIfNeeded()
        await drainMainQueue()
        XCTAssertNil(firstDescendant(of: NSTextField.self, in: hostingView))
    }

    func testDismantleBeforeFocusPreventsLaterFocusAttempts() async {
        var attempts = 0
        let coordinator = PaletteSearchField.Coordinator(
            parent: PaletteSearchField(text: .constant(""), placeholder: "", onSubmit: {}, onCancel: {}),
            focus: { _ in attempts += 1; return true }
        )
        let field = NSTextField()
        coordinator.attach(field)
        coordinator.prepareForDismantle()
        await drainMainQueue()
        coordinator.requestFocus()
        await drainMainQueue()
        XCTAssertEqual(attempts, 0)
        XCTAssertNil(coordinator.previousResponder)
    }

    func testFocusRetryStopsAfterEightAttempts() async {
        var attempts = 0
        let coordinator = PaletteSearchField.Coordinator(
            parent: PaletteSearchField(text: .constant(""), placeholder: "", onSubmit: {}, onCancel: {}),
            focus: { _ in attempts += 1; return false }
        )
        let field = NSTextField()
        coordinator.attach(field)
        for _ in 0..<10 { await drainMainQueue() }
        XCTAssertEqual(attempts, 8)
        withExtendedLifetime(field) {}
    }

    func testPaletteFieldTakesFocusFromDocumentSoTypingGoesToTheQuery() async throws {
        let state = PaletteQueryState()
        let (window, document, field, coordinator) = makePalette(state: state)
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

        XCTAssertEqual(state.text, "graph")
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
        let (window, document, field, coordinator) = makePalette(state: PaletteQueryState())
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
        let (window, document, field, coordinator) = makePalette(state: PaletteQueryState())
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
        state: PaletteQueryState
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
                text: Binding(get: { state.text }, set: { state.text = $0 }),
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

    private func waitForPaletteField(in root: NSView) async -> NSTextField? {
        for _ in 0..<50 {
            root.layoutSubtreeIfNeeded()
            if let field = paletteField(in: root),
               field.currentEditor() != nil {
                return field
            }
            await drainMainQueue()
        }
        return nil
    }

    private func paletteField(in root: NSView) -> NSTextField? {
        if let field = root as? NSTextField,
           field.delegate is PaletteSearchField.Coordinator { return field }
        for subview in root.subviews {
            if let field = paletteField(in: subview) { return field }
        }
        return nil
    }

    private func firstDescendant<View: NSView>(of type: View.Type, in root: NSView) -> View? {
        if let match = root as? View { return match }
        for subview in root.subviews {
            if let match = firstDescendant(of: type, in: subview) { return match }
        }
        return nil
    }

    private func sendKey(_ character: String, keyCode: UInt16, to window: NSWindow) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        )!
        window.sendEvent(event)
    }
}

private enum PaletteKind {
    case command
    case switcher
}

@MainActor
private final class PaletteQueryState: ObservableObject {
    @Published var text = ""
    @Published var show = true
}

private struct HostedPaletteSearchField: View {
    @ObservedObject var state: PaletteQueryState

    var body: some View {
        Group {
            if state.show {
                PaletteSearchField(
                    text: $state.text,
                    placeholder: "Type a command…",
                    onSubmit: {},
                    onCancel: {}
                )
            }
        }
        .frame(width: 300, height: 30)
    }
}
