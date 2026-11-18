import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

final class TimelineNavigationShortcutDecisionTests: XCTestCase {
    func testShouldNavigateBackwardWithArrowJAndL() {
        XCTAssertTrue(
            TimelineWindowController.shouldNavigateTimelineBackward(
                keyCode: 123,
                charactersIgnoringModifiers: nil,
                modifiers: []
            )
        )
        XCTAssertTrue(
            TimelineWindowController.shouldNavigateTimelineBackward(
                keyCode: 38,
                charactersIgnoringModifiers: "j",
                modifiers: []
            )
        )
        XCTAssertTrue(
            TimelineWindowController.shouldNavigateTimelineBackward(
                keyCode: 37,
                charactersIgnoringModifiers: "l",
                modifiers: []
            )
        )
    }

    func testShouldNavigateForwardWithArrowKAndSemicolon() {
        XCTAssertTrue(
            TimelineWindowController.shouldNavigateTimelineForward(
                keyCode: 124,
                charactersIgnoringModifiers: nil,
                modifiers: []
            )
        )
        XCTAssertTrue(
            TimelineWindowController.shouldNavigateTimelineForward(
                keyCode: 40,
                charactersIgnoringModifiers: "k",
                modifiers: []
            )
        )
        XCTAssertTrue(
            TimelineWindowController.shouldNavigateTimelineForward(
                keyCode: 41,
                charactersIgnoringModifiers: ";",
                modifiers: []
            )
        )
    }

    func testNavigationShortcutSupportsOptionModifier() {
        XCTAssertTrue(
            TimelineWindowController.shouldNavigateTimelineBackward(
                keyCode: 37,
                charactersIgnoringModifiers: "l",
                modifiers: [.option]
            )
        )
        XCTAssertTrue(
            TimelineWindowController.shouldNavigateTimelineForward(
                keyCode: 41,
                charactersIgnoringModifiers: ";",
                modifiers: [.option]
            )
        )
    }

    func testNavigationShortcutRejectsCommandModifier() {
        XCTAssertFalse(
            TimelineWindowController.shouldNavigateTimelineBackward(
                keyCode: 37,
                charactersIgnoringModifiers: "l",
                modifiers: [.command]
            )
        )
        XCTAssertFalse(
            TimelineWindowController.shouldNavigateTimelineForward(
                keyCode: 41,
                charactersIgnoringModifiers: ";",
                modifiers: [.command]
            )
        )
    }

    func testSearchResultNavigationShortcutSupportsCommandShiftArrowInHighlightMode() {
        XCTAssertEqual(
            TimelineWindowController.searchResultNavigationDirection(
                keyCode: 123,
                modifiers: [.command, .shift],
                isSearchResultHighlightVisible: true
            ),
            .previous
        )
        XCTAssertEqual(
            TimelineWindowController.searchResultNavigationDirection(
                keyCode: 124,
                modifiers: [.command, .shift],
                isSearchResultHighlightVisible: true
            ),
            .next
        )
    }

    func testSearchResultNavigationShortcutRejectsPlainCommandArrowInHighlightMode() {
        XCTAssertNil(
            TimelineWindowController.searchResultNavigationDirection(
                keyCode: 123,
                modifiers: [.command],
                isSearchResultHighlightVisible: true
            )
        )
        XCTAssertNil(
            TimelineWindowController.searchResultNavigationDirection(
                keyCode: 124,
                modifiers: [.command],
                isSearchResultHighlightVisible: true
            )
        )
    }

    func testSearchResultNavigationShortcutStaysDisabledOutsideHighlightMode() {
        XCTAssertNil(
            TimelineWindowController.searchResultNavigationDirection(
                keyCode: 123,
                modifiers: [.command],
                isSearchResultHighlightVisible: false
            )
        )
        XCTAssertNil(
            TimelineWindowController.searchResultNavigationDirection(
                keyCode: 124,
                modifiers: [.command, .shift],
                isSearchResultHighlightVisible: false
            )
        )
    }
}
