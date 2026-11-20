import XCTest
@testable import Retrace

final class CumulativeScreenTimeTrackerTests: XCTestCase {
    func testReconciledCumulativeDurationUsesLiveDatabaseTotalWhenStoredCounterLags() {
        let reconciled = CumulativeScreenTimeTracker.reconciledCumulativeDuration(
            storedCumulativeDuration: 990 * 60 * 60,
            incrementalDuration: 0,
            liveDatabaseDuration: 1_004 * 60 * 60
        )

        XCTAssertEqual(reconciled, 1_004 * 60 * 60, accuracy: 0.001)
    }

    func testReconciledCumulativeDurationPreservesHistoricalHoursAcrossDatabaseReset() {
        let reconciled = CumulativeScreenTimeTracker.reconciledCumulativeDuration(
            storedCumulativeDuration: 1_004 * 60 * 60,
            incrementalDuration: 0,
            liveDatabaseDuration: 0
        )

        XCTAssertEqual(reconciled, 1_004 * 60 * 60, accuracy: 0.001)
    }

    func testReconciledCumulativeDurationContinuesGrowingAfterResetWithNewCapture() {
        let reconciled = CumulativeScreenTimeTracker.reconciledCumulativeDuration(
            storedCumulativeDuration: 1_004 * 60 * 60,
            incrementalDuration: 2 * 60 * 60,
            liveDatabaseDuration: 1 * 60 * 60
        )

        XCTAssertEqual(reconciled, 1_006 * 60 * 60, accuracy: 0.001)
    }
}
