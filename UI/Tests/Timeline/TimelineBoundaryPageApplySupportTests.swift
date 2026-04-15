import XCTest
import Shared
@testable import Retrace

final class TimelineBoundaryPageApplySupportTests: XCTestCase {
    func testPrepareOlderLoadOutcomeReturnsReachedStartForNoOverlap() {
        let outcome = TimelineBoundaryPageApplySupport.prepareOlderLoadOutcome(
            pageOutcome: .skippedNoOverlap(
                rangeStart: Date(timeIntervalSince1970: 1_700_030_000),
                rangeEnd: Date(timeIntervalSince1970: 1_700_030_100)
            ),
            existingFrames: [],
            currentIndex: 0
        )

        guard case let .reachedStart(skippedDueToNoOverlap, queryElapsedMs) = outcome else {
            return XCTFail("Expected reached-start outcome")
        }

        XCTAssertTrue(skippedDueToNoOverlap)
        XCTAssertNil(queryElapsedMs)
    }

    func testPrepareOlderLoadOutcomeWrapsLoadedFramesInApplyPlan() {
        let base = Date(timeIntervalSince1970: 1_700_030_000)
        let existingFrames = makeTimelineFrames(ids: [10, 11, 12], start: base)
        let pageOutcome = TimelineOlderBoundaryPageQueryOutcome.loaded(
            TimelineOlderBoundaryPageQueryResult(
                framesDescending: makeFrameWithVideoInfos(
                    ids: [9, 8],
                    start: base.addingTimeInterval(-1),
                    step: -1
                ),
                queryElapsedMs: 12.5
            )
        )

        let outcome = TimelineBoundaryPageApplySupport.prepareOlderLoadOutcome(
            pageOutcome: pageOutcome,
            existingFrames: existingFrames,
            currentIndex: 2
        )

        guard case let .apply(load) = outcome else {
            return XCTFail("Expected apply outcome")
        }

        XCTAssertEqual(load.queryElapsedMs, 12.5)
        XCTAssertEqual(load.applyPlan.addedFrames.map(\.frame.id.value), [8, 9])
        XCTAssertEqual(load.applyPlan.resultingCurrentIndex, 4)
    }

    func testMakeOlderApplyPlanClampsIndexAndPreservesSelectionOffset() {
        let base = Date(timeIntervalSince1970: 1_700_030_000)
        let existingFrames = makeTimelineFrames(ids: [10, 11, 12], start: base)
        let loadedFramesDescending = makeFrameWithVideoInfos(
            ids: [9, 8],
            start: base.addingTimeInterval(-1),
            step: -1
        )

        let plan = TimelineBoundaryPageApplySupport.makeOlderApplyPlan(
            existingFrames: existingFrames,
            currentIndex: 99,
            loadedFramesDescending: loadedFramesDescending
        )

        XCTAssertEqual(plan.addedFrames.map(\.frame.id.value), [8, 9])
        XCTAssertEqual(plan.clampedPreviousIndex, 2)
        XCTAssertEqual(plan.resultingCurrentIndex, 4)
        XCTAssertEqual(plan.previousFrameTimestamp, base.addingTimeInterval(2))
    }

    func testMakeNewerApplyPlanPinsToNewestAndDropsDuplicates() {
        let base = Date(timeIntervalSince1970: 1_700_030_000)
        let existingFrames = makeTimelineFrames(ids: [1, 2, 3], start: base)
        let loadedFrames = makeFrameWithVideoInfos(ids: [3, 4, 5], start: base.addingTimeInterval(2))

        let outcome = TimelineBoundaryPageApplySupport.makeNewerApplyPlan(
            existingFrames: existingFrames,
            currentIndex: 2,
            loadedFrames: loadedFrames,
            shouldTrackNewestWhenAtEdge: true
        )

        guard case let .append(plan) = outcome else {
            return XCTFail("Expected append plan")
        }

        XCTAssertEqual(plan.addedFrames.map(\.frame.id.value), [4, 5])
        XCTAssertEqual(plan.duplicateCount, 1)
        XCTAssertTrue(plan.wasAtNewestBeforeAppend)
        XCTAssertTrue(plan.didPinToNewest)
        XCTAssertEqual(plan.resultingCurrentIndex, 4)
    }

    func testMakeNewerApplyPlanPreservesCurrentIndexWhenNotAtNewestEdge() {
        let base = Date(timeIntervalSince1970: 1_700_030_000)
        let existingFrames = makeTimelineFrames(ids: [1, 2, 3], start: base)
        let loadedFrames = makeFrameWithVideoInfos(ids: [4, 5], start: base.addingTimeInterval(3))

        let outcome = TimelineBoundaryPageApplySupport.makeNewerApplyPlan(
            existingFrames: existingFrames,
            currentIndex: 1,
            loadedFrames: loadedFrames,
            shouldTrackNewestWhenAtEdge: true
        )

        guard case let .append(plan) = outcome else {
            return XCTFail("Expected append plan")
        }

        XCTAssertFalse(plan.wasAtNewestBeforeAppend)
        XCTAssertFalse(plan.didPinToNewest)
        XCTAssertEqual(plan.resultingCurrentIndex, 1)
        XCTAssertEqual(plan.addedFrames.map(\.frame.id.value), [4, 5])
    }

    func testPrepareNewerLoadOutcomeReturnsReachedEndForEmptyPage() {
        let base = Date(timeIntervalSince1970: 1_700_030_000)
        let existingFrames = makeTimelineFrames(ids: [1, 2, 3], start: base)
        let pageResult = TimelineNewerBoundaryPageQueryResult(
            frames: [],
            queryElapsedMs: 8.25
        )

        let outcome = TimelineBoundaryPageApplySupport.prepareNewerLoadOutcome(
            pageResult: pageResult,
            existingFrames: existingFrames,
            currentIndex: 2,
            shouldTrackNewestWhenAtEdge: false
        )

        guard case let .reachedEndEmpty(queryElapsedMs) = outcome else {
            return XCTFail("Expected reached-end-empty outcome")
        }

        XCTAssertEqual(queryElapsedMs, 8.25)
    }

    func testPrepareNewerLoadOutcomeReturnsDuplicateOnlyWhenNothingCanBeAppended() {
        let base = Date(timeIntervalSince1970: 1_700_030_000)
        let existingFrames = makeTimelineFrames(ids: [1, 2, 3], start: base)
        let pageResult = TimelineNewerBoundaryPageQueryResult(
            frames: makeFrameWithVideoInfos(ids: [2, 3], start: base.addingTimeInterval(1)),
            queryElapsedMs: 4.0
        )

        let outcome = TimelineBoundaryPageApplySupport.prepareNewerLoadOutcome(
            pageResult: pageResult,
            existingFrames: existingFrames,
            currentIndex: 2,
            shouldTrackNewestWhenAtEdge: false
        )

        guard case let .reachedEndDuplicateOnly(result, queryElapsedMs) = outcome else {
            return XCTFail("Expected duplicate-only reached-end outcome")
        }

        XCTAssertEqual(queryElapsedMs, 4.0)
        XCTAssertEqual(result.attemptedFrameCount, 2)
        XCTAssertEqual(result.newestFrameID, 3)
        XCTAssertEqual(result.duplicateFrameID, 2)
    }

    func testMakeNewerApplyPlanReturnsDuplicateOnlyWhenNothingCanBeAppended() {
        let base = Date(timeIntervalSince1970: 1_700_030_000)
        let existingFrames = makeTimelineFrames(ids: [1, 2, 3], start: base)
        let loadedFrames = makeFrameWithVideoInfos(ids: [2, 3], start: base.addingTimeInterval(1))

        let outcome = TimelineBoundaryPageApplySupport.makeNewerApplyPlan(
            existingFrames: existingFrames,
            currentIndex: 2,
            loadedFrames: loadedFrames,
            shouldTrackNewestWhenAtEdge: false
        )

        guard case let .duplicateOnly(result) = outcome else {
            return XCTFail("Expected duplicate-only result")
        }

        XCTAssertEqual(result.attemptedFrameCount, 2)
        XCTAssertEqual(result.newestFrameID, 3)
        XCTAssertEqual(result.duplicateFrameID, 2)
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

    private func makeFrameWithVideoInfos(ids: [Int64], start: Date, step: TimeInterval = 1) -> [FrameWithVideoInfo] {
        ids.enumerated().map { offset, id in
            FrameWithVideoInfo(
                frame: FrameReference(
                    id: FrameID(value: id),
                    timestamp: start.addingTimeInterval(TimeInterval(offset) * step),
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
