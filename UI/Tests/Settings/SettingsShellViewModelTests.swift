import XCTest
import AppKit
@testable import Retrace

@MainActor
final class SettingsShellViewModelTests: XCTestCase {
    private final class ClipboardSpyTextView: NSTextView {
        var didCopy = false
        var didCut = false
        var didPaste = false

        override func copy(_ sender: Any?) {
            didCopy = true
        }

        override func cut(_ sender: Any?) {
            didCut = true
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

    func testInitializerHonorsInitialTabAndScrollTarget() {
        let viewModel = SettingsShellViewModel(
            initialTab: .power,
            initialScrollTargetID: "settings.powerOCRCard"
        )

        XCTAssertEqual(viewModel.selectedTab, .power)
        XCTAssertEqual(viewModel.pendingScrollTargetID, "settings.powerOCRCard")
    }

    func testSearchResultsMatchKeywordsAndTitles() {
        let ocrResults = SettingsShellViewModel.searchResults(for: "ocr")
        let shortcutResults = SettingsShellViewModel.searchResults(for: "shortcut")
        let captureAnimationResults = SettingsShellViewModel.searchResults(for: "capture animation")

        XCTAssertTrue(ocrResults.contains(where: { $0.id == "power.ocrProcessing" }))
        XCTAssertTrue(shortcutResults.contains(where: { $0.id == "general.shortcuts" }))
        XCTAssertTrue(captureAnimationResults.contains(where: { $0.id == "capture.menuBarIcon" }))
    }

    func testScheduleSettingsSearchResetClearsQueryAfterDelay() async {
        let viewModel = SettingsShellViewModel()
        viewModel.settingsSearchQuery = "privacy"

        viewModel.scheduleSettingsSearchReset()
        try? await Task.sleep(for: .nanoseconds(Int64(250_000_000)), clock: .continuous)

        XCTAssertEqual(viewModel.settingsSearchQuery, "")
    }

    func testCancelSettingsSearchResetKeepsQuery() async {
        let viewModel = SettingsShellViewModel()
        viewModel.settingsSearchQuery = "power"

        viewModel.scheduleSettingsSearchReset()
        viewModel.cancelSettingsSearchReset()
        try? await Task.sleep(for: .nanoseconds(Int64(250_000_000)), clock: .continuous)

        XCTAssertEqual(viewModel.settingsSearchQuery, "power")
    }

    func testSettingsSearchTextFieldCommandASelectsAll() throws {
        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let textField = SettingsSearchTextField(frame: NSRect(x: 20, y: 40, width: 240, height: 24))
        textField.stringValue = "meeting notes"
        contentView.addSubview(textField)

        window.makeKeyAndOrderFront(nil)
        textField.selectText(nil)

        guard let editor = window.fieldEditor(true, for: textField) as? NSTextView else {
            XCTFail("Expected a field editor for SettingsSearchTextField")
            return
        }

        editor.setSelectedRange(NSRange(location: 2, length: 3))

        let commandA = try XCTUnwrap(commandEvent("a", keyCode: 6, windowNumber: window.windowNumber))

        XCTAssertTrue(textField.performKeyEquivalent(with: commandA))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: textField.stringValue.count))
    }

    func testSettingsSearchTextFieldRoutesClipboardShortcutsToFieldEditor() throws {
        let window = ClipboardSpyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let textField = SettingsSearchTextField(frame: NSRect(x: 20, y: 40, width: 240, height: 24))
        textField.stringValue = "meeting notes"
        contentView.addSubview(textField)

        window.makeKeyAndOrderFront(nil)
        textField.selectText(nil)

        let commandC = try XCTUnwrap(commandEvent("c", keyCode: 8, windowNumber: window.windowNumber))
        let commandX = try XCTUnwrap(commandEvent("x", keyCode: 7, windowNumber: window.windowNumber))
        let commandV = try XCTUnwrap(commandEvent("v", keyCode: 9, windowNumber: window.windowNumber))

        XCTAssertTrue(textField.performKeyEquivalent(with: commandC))
        XCTAssertTrue(textField.performKeyEquivalent(with: commandX))
        XCTAssertTrue(textField.performKeyEquivalent(with: commandV))
        XCTAssertTrue(window.spyFieldEditor.didCopy)
        XCTAssertTrue(window.spyFieldEditor.didCut)
        XCTAssertTrue(window.spyFieldEditor.didPaste)
    }

    func testSettingsSearchTextFieldLeavesShortcutsWithTheFocusedField() throws {
        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let searchField = SettingsSearchTextField(frame: NSRect(x: 20, y: 100, width: 240, height: 24))
        searchField.stringValue = "privacy"
        contentView.addSubview(searchField)

        let otherField = NSTextField(frame: NSRect(x: 20, y: 40, width: 240, height: 24))
        otherField.stringValue = "another setting"
        contentView.addSubview(otherField)

        window.makeKeyAndOrderFront(nil)
        otherField.selectText(nil)
        let editor = try XCTUnwrap(otherField.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 3))

        let commandA = try XCTUnwrap(commandEvent("a", keyCode: 6, windowNumber: window.windowNumber))

        XCTAssertFalse(searchField.performKeyEquivalent(with: commandA))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertNotNil(otherField.currentEditor())
        XCTAssertNil(searchField.currentEditor())
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 3))
    }

    private func commandEvent(_ character: String, keyCode: UInt16, windowNumber: Int) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
