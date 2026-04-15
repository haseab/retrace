import XCTest
import Shared
@testable import Retrace

final class TimelineFrameWindowSupportTests: XCTestCase {
    func testMakeBoundedBoundaryFiltersClampsToExistingCriteriaRange() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3_600)
        let criteria = FilterCriteria(
            startDate: start.addingTimeInterval(600),
            endDate: end.addingTimeInterval(600)
        )

        let bounded = TimelineFrameWindowSupport.makeBoundedBoundaryFilters(
            rangeStart: start,
            rangeEnd: end,
            criteria: criteria
        )

        XCTAssertEqual(bounded?.startDate, start.addingTimeInterval(600))
        XCTAssertEqual(bounded?.endDate, end)
    }

    func testMakeBoundedBoundaryFiltersReturnsNilWhenRangesDoNotOverlap() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3_600)
        let criteria = FilterCriteria(
            startDate: end.addingTimeInterval(1),
            endDate: end.addingTimeInterval(600)
        )

        XCTAssertNil(
            TimelineFrameWindowSupport.makeBoundedBoundaryFilters(
                rangeStart: start,
                rangeEnd: end,
                criteria: criteria
            )
        )
    }

    func testTrimPreservingNewerAnchorsToFrameIDInsideTrimmedWindow() {
        let base = Date(timeIntervalSince1970: 1_700_010_000)
        let frames = makeFrames(count: 6, start: base)

        let result = TimelineFrameWindowSupport.trim(
            frames: frames,
            preserveDirection: .newer,
            currentIndex: 5,
            maxFrames: 4,
            anchorFrameID: frames[3].frame.id,
            anchorTimestamp: nil
        )

        XCTAssertEqual(result?.frames.map(\.frame.id.value), [3, 4, 5, 6])
        XCTAssertEqual(result?.targetIndexAfterTrim, 1)
        XCTAssertEqual(result?.excessCount, 2)
    }

    func testBoundaryLoadTriggerRequiresThresholdAvailabilityAndIdleState() {
        let trigger = TimelineFrameWindowSupport.boundaryLoadTrigger(
            currentIndex: 2,
            frameCount: 10,
            loadThreshold: 3,
            hasMoreOlder: true,
            hasMoreNewer: true,
            isLoadingOlder: false,
            isLoadingNewer: true
        )

        XCTAssertTrue(trigger.older)
        XCTAssertFalse(trigger.newer)
        XCTAssertTrue(trigger.any)
    }

    func testCheckAndScheduleBoundaryLoadsSuppressesMissingBoundaryTimestamp() {
        let controller = TimelineFrameWindowStateController()
        let counter = TaskScheduleCounter()

        let trigger = controller.checkAndScheduleBoundaryLoads(
            currentIndex: 0,
            frameCount: 10,
            loadThreshold: 3,
            reason: "test.missingTimestamp",
            isActivelyScrolling: false,
            subFrameOffset: 0,
            cmdFTraceID: nil,
            olderTask: counter.makeOlderTask(),
            newerTask: counter.makeNewerTask()
        )

        XCTAssertFalse(trigger.older)
        XCTAssertFalse(trigger.newer)
        XCTAssertFalse(trigger.any)
        XCTAssertEqual(counter.olderScheduledCount, 0)
        XCTAssertEqual(counter.newerScheduledCount, 0)
    }

    func testCheckAndScheduleBoundaryLoadsPreservesQueuedBoundaryLoadWithoutRescheduling() {
        let controller = TimelineFrameWindowStateController()
        let counter = TaskScheduleCounter()
        let pendingOlderTask = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(5), clock: .continuous)
        }
        controller.setWindowBoundaries(
            oldest: Date(timeIntervalSince1970: 1_700_000_000),
            newest: Date(timeIntervalSince1970: 1_700_000_010)
        )
        controller.replaceBoundaryLoadTask(direction: .older, task: pendingOlderTask)

        defer {
            pendingOlderTask.cancel()
            _ = controller.cancelBoundaryLoadTasks()
        }

        let trigger = controller.checkAndScheduleBoundaryLoads(
            currentIndex: 0,
            frameCount: 10,
            loadThreshold: 3,
            reason: "test.pendingOlderTask",
            isActivelyScrolling: false,
            subFrameOffset: 0,
            cmdFTraceID: nil,
            olderTask: counter.makeOlderTask(),
            newerTask: counter.makeNewerTask()
        )

        XCTAssertTrue(trigger.older)
        XCTAssertFalse(trigger.newer)
        XCTAssertTrue(trigger.any)
        XCTAssertEqual(counter.olderScheduledCount, 0)
        XCTAssertEqual(counter.newerScheduledCount, 0)
    }

    private func makeFrames(count: Int, start: Date) -> [TimelineFrame] {
        (0..<count).map { offset in
            let id = Int64(offset + 1)
            let frame = FrameReference(
                id: FrameID(value: id),
                timestamp: start.addingTimeInterval(TimeInterval(offset)),
                segmentID: AppSegmentID(value: id),
                frameIndexInSegment: offset,
                metadata: FrameMetadata(
                    appBundleID: "com.apple.Safari",
                    appName: "Safari",
                    displayID: 1
                )
            )

            return TimelineFrame(
                frame: frame,
                videoInfo: nil,
                processingStatus: 2
            )
        }
    }
}

private final class TaskScheduleCounter {
    private(set) var olderScheduledCount = 0
    private(set) var newerScheduledCount = 0

    func makeOlderTask() -> Task<Void, Never> {
        olderScheduledCount += 1
        return Task {}
    }

    func makeNewerTask() -> Task<Void, Never> {
        newerScheduledCount += 1
        return Task {}
    }
}
