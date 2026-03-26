import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class SystemMonitorChartGeometryTests: XCTestCase {
    func testHoveredDataIndexMapsExtremeEdgesToFirstAndLastBars() {
        XCTAssertEqual(
            ActivityBarChart.hoveredDataIndex(
                at: 0,
                dataPointCount: 30,
                barWidth: 10,
                spacing: 1
            ),
            0
        )

        XCTAssertEqual(
            ActivityBarChart.hoveredDataIndex(
                at: 319,
                dataPointCount: 30,
                barWidth: 10,
                spacing: 1
            ),
            29
        )
    }

    func testHoveredDataIndexTransitionsAtAdjacentBarMidpoint() {
        let midpointBetweenFirstTwoBars: CGFloat = 10.5

        XCTAssertEqual(
            ActivityBarChart.hoveredDataIndex(
                at: midpointBetweenFirstTwoBars - 0.1,
                dataPointCount: 30,
                barWidth: 10,
                spacing: 1
            ),
            0
        )

        XCTAssertEqual(
            ActivityBarChart.hoveredDataIndex(
                at: midpointBetweenFirstTwoBars + 0.1,
                dataPointCount: 30,
                barWidth: 10,
                spacing: 1
            ),
            1
        )
    }

    func testClampedTooltipCenterUsesCardPaddingAllowanceOnLeftEdge() {
        let center = ActivityBarChart.clampedTooltipCenterX(
            anchorX: 2,
            containerWidth: 320,
            tooltipWidth: 104,
            horizontalOverflowAllowance: 20
        )

        XCTAssertEqual(center, 32, accuracy: 0.001)
    }

    func testClampedTooltipCenterUsesCardPaddingAllowanceOnRightEdge() {
        let center = ActivityBarChart.clampedTooltipCenterX(
            anchorX: 318,
            containerWidth: 320,
            tooltipWidth: 104,
            horizontalOverflowAllowance: 20
        )

        XCTAssertEqual(center, 288, accuracy: 0.001)
    }
}
