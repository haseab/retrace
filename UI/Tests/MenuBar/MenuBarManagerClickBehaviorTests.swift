import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

final class MenuBarManagerClickBehaviorTests: XCTestCase {
    func testLeftMouseDownOpensStatusMenu() {
        XCTAssertTrue(MenuBarManager.shouldOpenStatusMenu(for: .leftMouseDown))
    }

    func testLeftClickOpensStatusMenu() {
        XCTAssertTrue(MenuBarManager.shouldOpenStatusMenu(for: .leftMouseUp))
    }

    func testRightMouseDownOpensStatusMenu() {
        XCTAssertTrue(MenuBarManager.shouldOpenStatusMenu(for: .rightMouseDown))
    }

    func testRightClickOpensStatusMenu() {
        XCTAssertTrue(MenuBarManager.shouldOpenStatusMenu(for: .rightMouseUp))
    }

    func testUnrelatedEventDoesNotOpenStatusMenu() {
        XCTAssertFalse(MenuBarManager.shouldOpenStatusMenu(for: .keyDown))
    }

    func testMissingEventDefaultsToOpenStatusMenu() {
        XCTAssertTrue(MenuBarManager.shouldOpenStatusMenu(for: nil))
    }

    func testPrimaryActionsPlaceSearchDirectlyUnderTimeline() {
        let actions = MenuBarManager.primaryActions(
            isDashboardFrontAndCenter: false,
            isSystemMonitorFrontAndCenter: false
        )

        XCTAssertEqual(actions.timeline.title, "Open Timeline")
        XCTAssertEqual(actions.search.title, "Search Screen History")
        XCTAssertEqual(actions.dashboard.title, "Open Dashboard")
        XCTAssertEqual(actions.monitor.title, "Open System Monitor")
        XCTAssertEqual(actions.search.imageSystemName, "magnifyingglass")
    }
}
