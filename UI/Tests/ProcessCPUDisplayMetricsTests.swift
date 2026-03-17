import XCTest
@testable import Retrace

final class ProcessCPUDisplayMetricsTests: XCTestCase {
    func testBuildRowsUsesLatestSamplePercentForCurrentColumnWhileKeepingAverageSortOrder() {
        let rows = ProcessCPUDisplayMetrics.buildRows(
            cumulativeNanosecondsByGroup: [
                "bundle:io.retrace.app": 15_000_000_000,
                "bundle:com.google.Chrome": 10_000_000_000
            ],
            latestDeltaNanosecondsByGroup: [
                "bundle:io.retrace.app": 250_000_000,
                "bundle:com.google.Chrome": 1_000_000_000
            ],
            latestSampleDurationSeconds: 1,
            energyNanojoulesByGroup: [:],
            peakPowerWattsByGroup: [:],
            displayNamesByKey: [
                "bundle:io.retrace.app": "Retrace",
                "bundle:com.google.Chrome": "Google Chrome"
            ],
            totalDuration: 100,
            logicalCoreCount: 10
        )

        XCTAssertEqual(rows.map(\.id), [
            "bundle:io.retrace.app",
            "bundle:com.google.Chrome"
        ])
        XCTAssertEqual(rows[0].currentCapacityPercent, 2.5, accuracy: 0.000_1)
        XCTAssertEqual(rows[1].currentCapacityPercent, 10.0, accuracy: 0.000_1)
        XCTAssertEqual(rows[0].capacityPercent, 1.5, accuracy: 0.000_1)
        XCTAssertEqual(rows[1].capacityPercent, 1.0, accuracy: 0.000_1)
    }

    func testCapacityPercentReturnsZeroWithoutUsableLatestSampleDuration() {
        XCTAssertEqual(
            ProcessCPUDisplayMetrics.capacityPercent(
                deltaNanoseconds: 1_000_000_000,
                sampleDurationSeconds: 0,
                logicalCoreCount: 10
            ),
            0,
            accuracy: 0.000_1
        )
    }
}
