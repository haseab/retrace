import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

final class TimelineKeyboardShortcutDecisionTests: XCTestCase {
    func testShouldHandleKeyboardShortcutsWhenTimelineVisibleAndFrontmost() {
        XCTAssertTrue(
            TimelineWindowController.shouldHandleTimelineKeyboardShortcuts(
                isTimelineVisible: true,
                frontmostProcessID: 111,
                currentProcessID: 111
            )
        )
    }

    func testShouldIgnoreKeyboardShortcutsWhenTimelineHidden() {
        XCTAssertFalse(
            TimelineWindowController.shouldHandleTimelineKeyboardShortcuts(
                isTimelineVisible: false,
                frontmostProcessID: 111,
                currentProcessID: 111
            )
        )
    }

    func testShouldIgnoreKeyboardShortcutsWhenAnotherAppIsFrontmost() {
        XCTAssertFalse(
            TimelineWindowController.shouldHandleTimelineKeyboardShortcuts(
                isTimelineVisible: true,
                frontmostProcessID: 222,
                currentProcessID: 111
            )
        )
    }

    func testShouldIgnoreKeyboardShortcutsWhenFrontmostAppIsUnknown() {
        XCTAssertFalse(
            TimelineWindowController.shouldHandleTimelineKeyboardShortcuts(
                isTimelineVisible: true,
                frontmostProcessID: nil,
                currentProcessID: 111
            )
        )
    }

    func testShouldToggleSearchOverlayShortcutWhenScrollIsNotActive() {
        XCTAssertTrue(
            TimelineWindowController.shouldToggleSearchOverlayFromShortcut(isActivelyScrolling: false)
        )
    }

    func testShouldNotToggleSearchOverlayShortcutWhenScrollIsActive() {
        XCTAssertFalse(
            TimelineWindowController.shouldToggleSearchOverlayFromShortcut(isActivelyScrolling: true)
        )
    }

    func testShouldDismissTimelineWithCommandW() {
        XCTAssertTrue(
            TimelineWindowController.shouldDismissTimelineWithCommandW(
                keyCode: 13,
                charactersIgnoringModifiers: "w",
                modifiers: [.command]
            )
        )
    }

    func testShouldNotDismissTimelineWithExtraModifierOrWrongKey() {
        XCTAssertFalse(
            TimelineWindowController.shouldDismissTimelineWithCommandW(
                keyCode: 13,
                charactersIgnoringModifiers: "w",
                modifiers: [.command, .shift]
            )
        )
        XCTAssertFalse(
            TimelineWindowController.shouldDismissTimelineWithCommandW(
                keyCode: 14,
                charactersIgnoringModifiers: "e",
                modifiers: [.command]
            )
        )
    }
}
