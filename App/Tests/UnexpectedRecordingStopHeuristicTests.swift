import XCTest
@testable import App

final class UnexpectedRecordingStopHeuristicTests: XCTestCase {
    func testUnexpectedCaptureTerminationRequiresRecordingToStillBeMarkedRunning() {
        XCTAssertTrue(
            AppCoordinator.shouldTreatCaptureTerminationAsUnexpected(
                isRunning: true,
                taskWasCancelled: false,
                isCaptureActive: false
            )
        )
        XCTAssertFalse(
            AppCoordinator.shouldTreatCaptureTerminationAsUnexpected(
                isRunning: false,
                taskWasCancelled: false,
                isCaptureActive: false
            )
        )
    }

    func testUnexpectedCaptureTerminationIgnoresIntentionalCancellationAndActiveCapture() {
        XCTAssertFalse(
            AppCoordinator.shouldTreatCaptureTerminationAsUnexpected(
                isRunning: true,
                taskWasCancelled: true,
                isCaptureActive: false
            )
        )
        XCTAssertFalse(
            AppCoordinator.shouldTreatCaptureTerminationAsUnexpected(
                isRunning: true,
                taskWasCancelled: false,
                isCaptureActive: true
            )
        )
    }

    func testStalledUnreadableWriterReturnsWriterWhenAnotherWriterContinues() {
        let now = Date(timeIntervalSince1970: 1_775_100_000)
        let writers = [
            AppCoordinator.UnexpectedRecordingStopWriterSnapshot(
                resolutionKey: "3024x1964",
                videoDBID: 1000059,
                frameCount: 3,
                persistedReadableFrameCount: 0,
                pendingUnreadableFrameCount: 3,
                oldestPendingUnreadableAt: now.addingTimeInterval(-90)
            ),
            AppCoordinator.UnexpectedRecordingStopWriterSnapshot(
                resolutionKey: "1920x1200",
                videoDBID: 1000060,
                frameCount: 5,
                persistedReadableFrameCount: 3,
                pendingUnreadableFrameCount: 0,
                oldestPendingUnreadableAt: nil
            )
        ]

        let stalledWriter = AppCoordinator.stalledUnreadableWriter(
            in: writers,
            now: now,
            threshold: 45,
            minimumPendingFrames: 2
        )

        XCTAssertEqual(stalledWriter?.videoDBID, 1000059)
    }

    func testStalledUnreadableWriterIgnoresSingleWriterWithoutCompetingProgress() {
        let now = Date(timeIntervalSince1970: 1_775_100_000)
        let writers = [
            AppCoordinator.UnexpectedRecordingStopWriterSnapshot(
                resolutionKey: "3024x1964",
                videoDBID: 1000059,
                frameCount: 2,
                persistedReadableFrameCount: 0,
                pendingUnreadableFrameCount: 2,
                oldestPendingUnreadableAt: now.addingTimeInterval(-120)
            )
        ]

        let stalledWriter = AppCoordinator.stalledUnreadableWriter(
            in: writers,
            now: now,
            threshold: 45,
            minimumPendingFrames: 2
        )

        XCTAssertNil(stalledWriter)
    }
}
