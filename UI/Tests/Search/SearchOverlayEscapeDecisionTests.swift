import XCTest
import AppKit
import App
@testable import Retrace

@MainActor
final class SearchOverlayEscapeDecisionTests: XCTestCase {
    func testExpandedOverlayEscShouldCollapseWithoutSubmittedSearch() {
        XCTAssertFalse(
            SearchViewModel.shouldDismissExpandedOverlayOnEscape(
                committedSearchQuery: "",
                hasSearchResultsPayload: false
            )
        )
    }

    func testExpandedOverlayEscShouldDismissWhenCommittedQueryExists() {
        XCTAssertTrue(
            SearchViewModel.shouldDismissExpandedOverlayOnEscape(
                committedSearchQuery: "meeting notes",
                hasSearchResultsPayload: false
            )
        )
    }

    func testExpandedOverlayEscShouldDismissWhenResultsPayloadExists() {
        XCTAssertTrue(
            SearchViewModel.shouldDismissExpandedOverlayOnEscape(
                committedSearchQuery: "",
                hasSearchResultsPayload: true
            )
        )
    }

    func testExpandedOverlayEscShouldRefocusSearchFieldBeforeDismissWhenQueryExistsAndFieldIsNotFocused() {
        XCTAssertTrue(
            SearchViewModel.shouldRefocusSearchFieldOnEscape(
                committedSearchQuery: "meeting notes",
                hasSearchResultsPayload: false,
                isSearchFieldFocused: false
            )
        )
    }

    func testExpandedOverlayEscShouldRefocusSearchFieldBeforeDismissWhenResultsExistAndFieldIsNotFocused() {
        XCTAssertTrue(
            SearchViewModel.shouldRefocusSearchFieldOnEscape(
                committedSearchQuery: "",
                hasSearchResultsPayload: true,
                isSearchFieldFocused: false
            )
        )
    }

    func testExpandedOverlayEscShouldNotRefocusSearchFieldWhenFieldIsAlreadyFocused() {
        XCTAssertFalse(
            SearchViewModel.shouldRefocusSearchFieldOnEscape(
                committedSearchQuery: "meeting notes",
                hasSearchResultsPayload: true,
                isSearchFieldFocused: true
            )
        )
    }

    func testRequestSearchFieldFocusCanRequestSelectAll() {
        let viewModel = SearchViewModel(coordinator: AppCoordinator())

        viewModel.requestSearchFieldFocus(selectAll: true)

        XCTAssertTrue(viewModel.focusSearchFieldSignal.selectAll)
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
}
