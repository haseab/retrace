import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class SystemMonitorChartGeometryTests: XCTestCase {
    func testLayoutMetricsClampUndersizedContainerToNonNegativeFrames() {
        let metrics = ActivityBarChart.layoutMetrics(
            totalWidth: 12,
            totalHeight: 8,
            dataPointCount: 30,
            pendingCount: 250,
            backlogBarCap: 100,
            maxVisibleBacklogBars: 10,
            xAxisHeight: 1,
            labelPadding: 4,
            labelHeight: 12,
            singleBarWidth: 28,
            backlogSpacing: 2,
            spacing: 1
        )

        XCTAssertEqual(metrics.chartHeight, 0, accuracy: 0.001)
        XCTAssertEqual(metrics.chartWidth, 0, accuracy: 0.001)
        XCTAssertEqual(metrics.barWidth, 3, accuracy: 0.001)
    }

    func testLayoutMetricsHandleEmptyDataWithoutNonFiniteBarWidth() {
        let metrics = ActivityBarChart.layoutMetrics(
            totalWidth: 320,
            totalHeight: 160,
            dataPointCount: 0,
            pendingCount: 0,
            backlogBarCap: 100,
            maxVisibleBacklogBars: 10,
            xAxisHeight: 1,
            labelPadding: 4,
            labelHeight: 12,
            singleBarWidth: 28,
            backlogSpacing: 2,
            spacing: 1
        )

        XCTAssertEqual(metrics.chartHeight, 143, accuracy: 0.001)
        XCTAssertEqual(metrics.chartWidth, 320, accuracy: 0.001)
        XCTAssertEqual(metrics.barWidth, 320, accuracy: 0.001)
    }

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

    func testYAxisUpperBoundTracksObservedDataInsteadOfFixedBacklogCap() {
        let upperBound = ActivityBarChart.yAxisUpperBound(
            historicalMax: 7,
            liveTotal: 3,
            pendingCount: 0,
            backlogBarCap: 100
        )

        XCTAssertEqual(upperBound, 10)
    }

    func testYAxisUpperBoundIncludesVisibleBacklogChunkWhenPresent() {
        let upperBound = ActivityBarChart.yAxisUpperBound(
            historicalMax: 12,
            liveTotal: 6,
            pendingCount: 250,
            backlogBarCap: 100
        )

        XCTAssertEqual(upperBound, 100)
    }
}
