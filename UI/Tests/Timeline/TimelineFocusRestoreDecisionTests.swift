import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

final class TimelineFocusRestoreDecisionTests: XCTestCase {
    func testShouldCaptureFocusRestoreTargetForExternalFrontmostApp() {
        XCTAssertTrue(
            TimelineWindowController.shouldCaptureFocusRestoreTarget(
                frontmostProcessID: 222,
                currentProcessID: 111
            )
        )
    }

    func testShouldNotCaptureFocusRestoreTargetWhenFrontmostIsRetrace() {
        XCTAssertFalse(
            TimelineWindowController.shouldCaptureFocusRestoreTarget(
                frontmostProcessID: 111,
                currentProcessID: 111
            )
        )
    }

    func testShouldNotCaptureFocusRestoreTargetWhenFrontmostUnavailable() {
        XCTAssertFalse(
            TimelineWindowController.shouldCaptureFocusRestoreTarget(
                frontmostProcessID: nil,
                currentProcessID: 111
            )
        )
    }

    func testShouldRestoreFocusWhenRequestedAndTargetExternal() {
        XCTAssertTrue(
            TimelineWindowController.shouldRestoreFocus(
                requestedRestore: true,
                isHidingToShowDashboard: false,
                targetProcessID: 222,
                currentProcessID: 111
            )
        )
    }

    func testShouldNotRestoreFocusWhenHideWasForDashboard() {
        XCTAssertFalse(
            TimelineWindowController.shouldRestoreFocus(
                requestedRestore: true,
                isHidingToShowDashboard: true,
                targetProcessID: 222,
                currentProcessID: 111
            )
        )
    }

    func testShouldNotRestoreFocusWhenNotRequested() {
        XCTAssertFalse(
            TimelineWindowController.shouldRestoreFocus(
                requestedRestore: false,
                isHidingToShowDashboard: false,
                targetProcessID: 222,
                currentProcessID: 111
            )
        )
    }

    func testShouldNotRestoreFocusWhenTargetIsCurrentProcess() {
        XCTAssertFalse(
            TimelineWindowController.shouldRestoreFocus(
                requestedRestore: true,
                isHidingToShowDashboard: false,
                targetProcessID: 111,
                currentProcessID: 111
            )
        )
    }
}
