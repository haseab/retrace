import XCTest
import AppKit
@testable import Retrace

@MainActor
final class FocusableTextInputSupportTests: XCTestCase {
    private final class ClipboardSpyTextView: NSTextView {
        var didCopy = false
        var didPaste = false

        override func copy(_ sender: Any?) {
            didCopy = true
        }

        override func paste(_ sender: Any?) {
            didPaste = true
        }
    }

    private final class ClipboardSpyWindow: KeyableWindow {
        let spyFieldEditor = ClipboardSpyTextView(frame: .zero)

        override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
            spyFieldEditor
        }
    }

    func testFocusableTextFieldCommandASelectsAllUsingCharacterEquivalent() throws {
        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let textField = FocusableTextField(frame: NSRect(x: 20, y: 40, width: 240, height: 24))
        textField.stringValue = "meeting notes"
        contentView.addSubview(textField)

        window.makeKeyAndOrderFront(nil)
        textField.selectText(nil)

        guard let editor = window.fieldEditor(true, for: textField) as? NSTextView else {
            XCTFail("Expected a field editor for FocusableTextField")
            return
        }

        editor.setSelectedRange(NSRange(location: 2, length: 3))

        let commandA = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 6
            )
        )

        XCTAssertTrue(textField.performKeyEquivalent(with: commandA))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: textField.stringValue.count))
    }

    func testFocusableTextFieldCommandCCallsFieldEditorCopy() throws {
        let window = ClipboardSpyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let textField = FocusableTextField(frame: NSRect(x: 20, y: 40, width: 240, height: 24))
        textField.stringValue = "meeting notes"
        contentView.addSubview(textField)

        window.makeKeyAndOrderFront(nil)
        textField.selectText(nil)

        let commandC = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "c",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 8
            )
        )

        XCTAssertTrue(textField.performKeyEquivalent(with: commandC))
        XCTAssertTrue(window.spyFieldEditor.didCopy)
    }

    func testFocusableTextFieldCommandVCallsFieldEditorPaste() throws {
        let window = ClipboardSpyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let textField = FocusableTextField(frame: NSRect(x: 20, y: 40, width: 240, height: 24))
        textField.stringValue = "meeting notes"
        contentView.addSubview(textField)

        window.makeKeyAndOrderFront(nil)
        textField.selectText(nil)

        let commandV = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "v",
                charactersIgnoringModifiers: "v",
                isARepeat: false,
                keyCode: 9
            )
        )

        XCTAssertTrue(textField.performKeyEquivalent(with: commandV))
        XCTAssertTrue(window.spyFieldEditor.didPaste)
    }

    func testFocusableTextFieldCommandReturnInvokesCommandReturnCallback() throws {
        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let textField = FocusableTextField(frame: NSRect(x: 20, y: 40, width: 240, height: 24))
        contentView.addSubview(textField)

        var didInvokeCommandReturn = false
        textField.onCommandReturnCallback = {
            didInvokeCommandReturn = true
        }

        let commandReturn = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )

        XCTAssertTrue(textField.performKeyEquivalent(with: commandReturn))
        XCTAssertTrue(didInvokeCommandReturn)
    }

    func testSyncResponderFocusStartsEditingWhenFocusIsRequestedProgrammatically() {
        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let textField = FocusableTextField(frame: NSRect(x: 20, y: 40, width: 240, height: 24))
        textField.stringValue = "Apr 9, 2026"
        contentView.addSubview(textField)

        window.makeKeyAndOrderFront(nil)

        FocusableTextInput.syncResponderFocus(for: textField, wantsFocus: true)

        let currentEditor = textField.currentEditor()
        XCTAssertNotNil(currentEditor)
        XCTAssertTrue(window.firstResponder === textField || window.firstResponder === currentEditor)
    }

    func testCoordinatorRestoresEditingWhenAppKitEndsEditingButFocusIsStillRequested() {
        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let textField = FocusableTextField(frame: NSRect(x: 20, y: 40, width: 240, height: 24))
        textField.stringValue = "Apr 9, 2026"
        contentView.addSubview(textField)

        window.makeKeyAndOrderFront(nil)
        textField.selectText(nil)
        _ = window.makeFirstResponder(nil)

        var isFocused = true
        var focusTransitions: [Bool] = []
        var didBlur = false
        let coordinator = FocusableTextInput.Coordinator(
            text: .constant(textField.stringValue),
            onSubmit: nil,
            onEscape: nil,
            isFocused: { isFocused },
            setFocused: { isNowFocused in
                focusTransitions.append(isNowFocused)
                isFocused = isNowFocused
            },
            onBlur: {
                didBlur = true
            }
        )

        coordinator.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: textField)
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(isFocused)
        XCTAssertTrue(focusTransitions.isEmpty)
        XCTAssertFalse(didBlur)

        let currentEditor = textField.currentEditor()
        XCTAssertNotNil(currentEditor)
        XCTAssertTrue(window.firstResponder === textField || window.firstResponder === currentEditor)
    }

    func testShouldDeferRightClickToTextInputWhenHitEditableTextField() throws {
        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let textField = FocusableTextField(frame: NSRect(x: 20, y: 40, width: 240, height: 24))
        contentView.addSubview(textField)

        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: NSPoint(x: 30, y: 50),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )

        XCTAssertTrue(FocusableTextInputSupport.shouldDeferRightClickToTextInput(window: window, event: event))
    }

    func testShouldNotDeferRightClickOutsideEditableTextInput() throws {
        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let textField = FocusableTextField(frame: NSRect(x: 20, y: 40, width: 240, height: 24))
        contentView.addSubview(textField)

        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: NSPoint(x: 5, y: 5),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )

        XCTAssertFalse(FocusableTextInputSupport.shouldDeferRightClickToTextInput(window: window, event: event))
    }

    func testTextInputContextMenuFilterKeepsOnlyCutCopyPasteItems() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Writing Tools", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Proofread", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "AutoFill", action: nil, keyEquivalent: "")

        let filteredMenu = TextInputContextMenuAutofillFilter.filteredMenu(from: menu)

        XCTAssertEqual(filteredMenu?.items.map(\.title), ["Cut", "Copy", "Paste"])
    }

    func testTextInputContextMenuFilterDropsNestedSubmenusOutsideCutCopyPaste() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")

        let substitutions = NSMenuItem(title: "Substitutions", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Smart Quotes", action: nil, keyEquivalent: "")
        substitutions.submenu = submenu
        menu.addItem(substitutions)

        let filteredMenu = TextInputContextMenuAutofillFilter.filteredMenu(from: menu)

        XCTAssertEqual(filteredMenu?.items.map(\.title), ["Cut", "Copy", "Paste"])
    }

    func testDropdownOverlayHitTestingKeepsInsideClicksOpen() throws {
        let window = makeWindowForDropdownHitTesting()
        let triggerFrame = screenFrame(in: window, origin: NSPoint(x: 20, y: 20), size: CGSize(width: 120, height: 32))
        let contentFrame = screenFrame(in: window, origin: NSPoint(x: 60, y: 72), size: CGSize(width: 220, height: 140))
        let event = try mouseEvent(in: window, location: NSPoint(x: 90, y: 100))

        XCTAssertFalse(
            DropdownOverlayInteraction.shouldDismiss(
                event: event,
                triggerFrame: triggerFrame,
                contentFrame: contentFrame
            )
        )
    }

    func testDropdownOverlayHitTestingDismissesOutsideClicks() throws {
        let window = makeWindowForDropdownHitTesting()
        let triggerFrame = screenFrame(in: window, origin: NSPoint(x: 20, y: 20), size: CGSize(width: 120, height: 32))
        let contentFrame = screenFrame(in: window, origin: NSPoint(x: 60, y: 72), size: CGSize(width: 220, height: 140))
        let event = try mouseEvent(in: window, location: NSPoint(x: 12, y: 12))

        XCTAssertTrue(
            DropdownOverlayInteraction.shouldDismiss(
                event: event,
                triggerFrame: triggerFrame,
                contentFrame: contentFrame
            )
        )
    }

    private func makeWindowForDropdownHitTesting() -> NSWindow {
        let window = KeyableWindow(
            contentRect: NSRect(x: 420, y: 260, width: 360, height: 220),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { window.orderOut(nil) }
        return window
    }

    private func screenFrame(in window: NSWindow, origin: NSPoint, size: CGSize) -> CGRect {
        CGRect(origin: window.convertPoint(toScreen: origin), size: size)
    }

    private func mouseEvent(in window: NSWindow, location: NSPoint) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
    }
}
