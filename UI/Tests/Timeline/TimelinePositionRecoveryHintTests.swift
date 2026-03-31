import XCTest
import App
@testable import Retrace

@MainActor
final class TimelinePositionRecoveryHintTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SimpleTimelineViewModel.resetPositionRecoveryHintDismissalForTesting()
    }

    override func tearDown() {
        SimpleTimelineViewModel.resetPositionRecoveryHintDismissalForTesting()
        super.tearDown()
    }

    func testPositionRecoveryHintAutoDismisses() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())

        viewModel.showPositionRecoveryHint(hiddenElapsedSeconds: 75, autoDismissAfter: 0.05)
        XCTAssertTrue(viewModel.showPositionRecoveryHintBanner)

        try? await Task.sleep(for: .milliseconds(120), clock: .continuous)

        XCTAssertFalse(viewModel.showPositionRecoveryHintBanner)
    }

    func testPositionRecoveryHintDismissalSuppressesFutureShowsForCurrentSession() {
        let firstViewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())

        firstViewModel.showPositionRecoveryHint(hiddenElapsedSeconds: 75, autoDismissAfter: 10)
        XCTAssertTrue(firstViewModel.showPositionRecoveryHintBanner)

        firstViewModel.dismissPositionRecoveryHint()
        XCTAssertFalse(firstViewModel.showPositionRecoveryHintBanner)

        let secondViewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        secondViewModel.showPositionRecoveryHint(hiddenElapsedSeconds: 75, autoDismissAfter: 10)

        XCTAssertFalse(secondViewModel.showPositionRecoveryHintBanner)
    }

    func testPositionRecoveryHintShowsOnlyInsidePostCacheBustGraceWindow() {
        XCTAssertTrue(
            TimelineWindowController.shouldShowPositionRecoveryHintOnReopen(
                hiddenElapsedSeconds: 75,
                didSnapToNewest: true
            )
        )
        XCTAssertTrue(
            TimelineWindowController.shouldShowPositionRecoveryHintOnReopen(
                hiddenElapsedSeconds: 120,
                didSnapToNewest: true
            )
        )
    }

    func testPositionRecoveryHintDoesNotShowBeforeCacheBust() {
        XCTAssertFalse(
            TimelineWindowController.shouldShowPositionRecoveryHintOnReopen(
                hiddenElapsedSeconds: 59,
                didSnapToNewest: true
            )
        )
    }

    func testPositionRecoveryHintDoesNotShowLongAfterCacheBust() {
        XCTAssertFalse(
            TimelineWindowController.shouldShowPositionRecoveryHintOnReopen(
                hiddenElapsedSeconds: 121,
                didSnapToNewest: true
            )
        )
    }

    func testPositionRecoveryHintDoesNotShowWithoutLosingPosition() {
        XCTAssertFalse(
            TimelineWindowController.shouldShowPositionRecoveryHintOnReopen(
                hiddenElapsedSeconds: 75,
                didSnapToNewest: false
            )
        )
    }
}
