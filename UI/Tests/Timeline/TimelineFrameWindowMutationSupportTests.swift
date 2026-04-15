import XCTest
import Shared
@testable import Retrace

final class TimelineFrameWindowMutationSupportTests: XCTestCase {
    func testApplyOlderPrependsFramesAndRefreshesBoundaryTimestamps() {
        let base = Date(timeIntervalSince1970: 1_700_050_000)
        let existingFrames = makeTimelineFrames(ids: [10, 11], start: base)
        let applyPlan = TimelineOlderBoundaryApplyPlan(
            addedFrames: makeTimelineFrames(ids: [8, 9], start: base.addingTimeInterval(-2)),
            clampedPreviousIndex: 1,
            resultingCurrentIndex: 3,
            previousFrameTimestamp: base.addingTimeInterval(1)
        )

        let result = TimelineFrameWindowMutationSupport.applyOlder(
            existingFrames: existingFrames,
            applyPlan: applyPlan
        )

        XCTAssertEqual(result.frames.map(\.frame.id.value), [8, 9, 10, 11])
        XCTAssertEqual(result.currentIndex, 3)
        XCTAssertEqual(result.oldestTimestamp, base.addingTimeInterval(-2))
        XCTAssertEqual(result.newestTimestamp, base.addingTimeInterval(1))
        XCTAssertFalse(result.shouldResetSubFrameOffset)
    }

    func testApplyNewerAppendsFramesAndMarksSubFrameResetWhenPinned() {
        let base = Date(timeIntervalSince1970: 1_700_050_000)
        let existingFrames = makeTimelineFrames(ids: [10, 11], start: base)
        let applyPlan = TimelineNewerBoundaryApplyPlan(
            addedFrames: makeTimelineFrames(ids: [12, 13], start: base.addingTimeInterval(2)),
            duplicateCount: 0,
            wasAtNewestBeforeAppend: true,
            didPinToNewest: true,
            resultingCurrentIndex: 3
        )

        let result = TimelineFrameWindowMutationSupport.applyNewer(
            existingFrames: existingFrames,
            applyPlan: applyPlan
        )

        XCTAssertEqual(result.frames.map(\.frame.id.value), [10, 11, 12, 13])
        XCTAssertEqual(result.currentIndex, 3)
        XCTAssertEqual(result.oldestTimestamp, base)
        XCTAssertEqual(result.newestTimestamp, base.addingTimeInterval(3))
        XCTAssertTrue(result.shouldResetSubFrameOffset)
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
