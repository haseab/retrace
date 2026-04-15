import XCTest
@testable import Retrace

final class TimelineCommentSubmenuPresentationSupportTests: XCTestCase {
    func testInitialStateReflectsVisibleSubmenu() {
        XCTAssertEqual(
            TimelineCommentSubmenuPresentationSupport.initialState(isVisible: true),
            TimelineCommentSubmenuPresentationState(isMounted: true, visibility: 1)
        )
    }

    func testTransitionShowsAndPrimesMountWhenSubmenuWasUnmounted() {
        XCTAssertEqual(
            TimelineCommentSubmenuPresentationSupport.transition(isVisible: true, isMounted: false),
            .show(shouldPrimeMount: true)
        )
    }

    func testTransitionShowsWithoutPrimingWhenAlreadyMounted() {
        XCTAssertEqual(
            TimelineCommentSubmenuPresentationSupport.transition(isVisible: true, isMounted: true),
            .show(shouldPrimeMount: false)
        )
    }

    func testTransitionSchedulesUnmountWhenHidingMountedSubmenu() {
        XCTAssertEqual(
            TimelineCommentSubmenuPresentationSupport.transition(isVisible: false, isMounted: true),
            .hide(shouldScheduleUnmount: true)
        )
    }

    func testShouldFinalizeUnmountReturnsFalseWhenSubmenuReopened() {
        XCTAssertFalse(
            TimelineCommentSubmenuPresentationSupport.shouldFinalizeUnmount(isStillVisible: true)
        )
    }
}
