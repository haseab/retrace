import XCTest
import Shared
@testable import Retrace

final class TimelineBoundaryLoadCompletionSupportTests: XCTestCase {
    func testMakeOlderApplySummaryCapturesCountsAndBridgeGap() {
        let base = Date(timeIntervalSince1970: 1_700_040_000)
        let applyPlan = TimelineOlderBoundaryApplyPlan(
            addedFrames: makeTimelineFrames(ids: [8, 9], start: base.addingTimeInterval(-2)),
            clampedPreviousIndex: 2,
            resultingCurrentIndex: 4,
            previousFrameTimestamp: base.addingTimeInterval(2)
        )

        let summary = TimelineBoundaryLoadCompletionSupport.makeOlderApplySummary(
            beforeCount: 3,
            oldFirstTimestamp: base,
            applyPlan: applyPlan
        )

        XCTAssertEqual(summary.beforeCount, 3)
        XCTAssertEqual(summary.afterCount, 5)
        XCTAssertEqual(summary.addedCount, 2)
        XCTAssertEqual(summary.previousIndex, 2)
        XCTAssertEqual(summary.currentIndex, 4)
        XCTAssertEqual(summary.previousFrameTimestamp, base.addingTimeInterval(2))
        XCTAssertEqual(summary.bridgeTimestamp, base.addingTimeInterval(-1))
        XCTAssertEqual(summary.bridgeGapSeconds, 1)
    }

    func testMakeNewerApplySummaryCapturesPinningAndBridgeGap() {
        let base = Date(timeIntervalSince1970: 1_700_040_000)
        let applyPlan = TimelineNewerBoundaryApplyPlan(
            addedFrames: makeTimelineFrames(ids: [4, 5], start: base.addingTimeInterval(3)),
            duplicateCount: 1,
            wasAtNewestBeforeAppend: true,
            didPinToNewest: true,
            resultingCurrentIndex: 4
        )

        let summary = TimelineBoundaryLoadCompletionSupport.makeNewerApplySummary(
            beforeCount: 3,
            previousIndex: 2,
            oldLastTimestamp: base.addingTimeInterval(2),
            applyPlan: applyPlan
        )

        XCTAssertEqual(summary.beforeCount, 3)
        XCTAssertEqual(summary.afterCount, 5)
        XCTAssertEqual(summary.addedCount, 2)
        XCTAssertEqual(summary.previousIndex, 2)
        XCTAssertEqual(summary.currentIndex, 4)
        XCTAssertTrue(summary.wasAtNewestBeforeAppend)
        XCTAssertTrue(summary.didPinToNewest)
        XCTAssertEqual(summary.bridgeTimestamp, base.addingTimeInterval(3))
        XCTAssertEqual(summary.bridgeGapSeconds, 1)
    }

    func testMakeTimingComputesLoadAndTraceElapsedMs() {
        let timing = TimelineBoundaryLoadCompletionSupport.makeTiming(
            now: 15,
            loadStartedAt: 10,
            traceStartedAt: 8
        )

        XCTAssertEqual(timing.loadElapsedMs, 5_000)
        XCTAssertEqual(timing.totalFromTraceMs, 7_000)
    }

    private func makeTimelineFrames(ids: [Int64], start: Date) -> [TimelineFrame] {
        ids.enumerated().map { offset, id in
            TimelineFrame(
                frame: FrameReference(
                    id: FrameID(value: id),
                    timestamp: start.addingTimeInterval(TimeInterval(offset)),
                    segmentID: AppSegmentID(value: id),
                    frameIndexInSegment: offset,
                    metadata: FrameMetadata(
                        appBundleID: "com.apple.Safari",
                        appName: "Safari",
                        displayID: 1
                    )
                ),
                videoInfo: nil,
                processingStatus: 2
            )
        }
    }
}
