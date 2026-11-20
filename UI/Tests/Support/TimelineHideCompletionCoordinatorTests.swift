import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class TimelineHideCompletionCoordinatorTests: XCTestCase {
    func testWaitersResumeWhenTimelineFinishesHiding() async {
        let coordinator = TimelineWindowController.HideCompletionCoordinator()

        async let firstWaiter = coordinator.wait()
        async let secondWaiter = coordinator.wait()
        await Task.yield()

        coordinator.resumeAll(hidden: true)

        let didHideFirst = await firstWaiter
        let didHideSecond = await secondWaiter
        XCTAssertTrue(didHideFirst)
        XCTAssertTrue(didHideSecond)
    }

    func testCancelledHideDoesNotLeakIntoFutureWaiters() async {
        let coordinator = TimelineWindowController.HideCompletionCoordinator()

        async let cancelledWaiter = coordinator.wait()
        await Task.yield()

        coordinator.resumeAll(hidden: false)
        let didHideAfterCancellation = await cancelledWaiter
        XCTAssertFalse(didHideAfterCancellation)

        async let hiddenWaiter = coordinator.wait()
        await Task.yield()

        coordinator.resumeAll(hidden: true)
        let didHideAfterRetry = await hiddenWaiter
        XCTAssertTrue(didHideAfterRetry)
    }
}
