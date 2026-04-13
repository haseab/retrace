import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class TimelineKeyboardShortcutDecisionTests: XCTestCase {
    private let searchOverlayVisibilityDefaultsKey = "searchOverlayVisible"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: searchOverlayVisibilityDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: searchOverlayVisibilityDefaultsKey)
        super.tearDown()
    }

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

    func testSearchOverlayShortcutOpensOverlayWhenHidden() {
        XCTAssertEqual(
            TimelineWindowController.searchOverlayShortcutAction(
                isSearchOverlayVisible: false,
                shouldRefocusSearchFieldBeforeClose: false
            ),
            .open
        )
    }

    func testSearchOverlayShortcutFocusesFieldBeforeClosingWhenVisibleResultsOwnFocus() {
        XCTAssertEqual(
            TimelineWindowController.searchOverlayShortcutAction(
                isSearchOverlayVisible: true,
                shouldRefocusSearchFieldBeforeClose: true
            ),
            .focusField
        )
    }

    func testSearchOverlayShortcutClosesOverlayWhenVisibleAndFieldAlreadyFocused() {
        XCTAssertEqual(
            TimelineWindowController.searchOverlayShortcutAction(
                isSearchOverlayVisible: true,
                shouldRefocusSearchFieldBeforeClose: false
            ),
            .close
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

    func testPresentSearchOverlayOpensWithoutClearingSearchQuery() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.searchViewModel.searchQuery = "network timeout"
        viewModel.isSearchOverlayVisible = false

        let didOpen = TimelineWindowController.presentSearchOverlay(
            on: viewModel,
            coordinator: nil,
            recentEntriesRevealDelay: 0.3
        )

        XCTAssertTrue(didOpen)
        XCTAssertTrue(viewModel.isSearchOverlayVisible)
        XCTAssertEqual(viewModel.searchViewModel.searchQuery, "network timeout")
    }

    func testPresentSearchOverlayDoesNotToggleClosedWhenAlreadyVisible() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.searchViewModel.searchQuery = "crash"
        viewModel.isSearchOverlayVisible = true

        let didOpen = TimelineWindowController.presentSearchOverlay(
            on: viewModel,
            coordinator: nil,
            recentEntriesRevealDelay: 0.3
        )

        XCTAssertFalse(didOpen)
        XCTAssertTrue(viewModel.isSearchOverlayVisible)
        XCTAssertEqual(viewModel.searchViewModel.searchQuery, "crash")
    }
}
