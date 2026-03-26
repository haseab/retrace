import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class TimelineBoundaryNewerFallbackTests: XCTestCase {
    func testLoadNewerFramesFallsBackToNearestQueryAfterEmptyWindowedProbe() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_500_000)
        var recordedWindowCalls: [(from: Date, to: Date, limit: Int, reason: String)] = []
        var recordedAfterCalls: [(timestamp: Date, limit: Int, startDate: Date?, endDate: Date?, reason: String)] = []

        viewModel.frames = [
            makeTimelineFrame(
                id: 20,
                timestamp: baseDate,
                frameIndex: 0,
                bundleID: "com.apple.Safari"
            ),
            makeTimelineFrame(
                id: 21,
                timestamp: baseDate.addingTimeInterval(1),
                frameIndex: 1,
                bundleID: "com.apple.Safari"
            )
        ]
        viewModel.currentIndex = 1
        viewModel.filterCriteria = FilterCriteria()
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: false, hasMoreNewer: true)
        viewModel.test_updateWindowBoundaries()

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { from, to, limit, _, reason in
            recordedWindowCalls.append((from, to, limit, reason))
            XCTAssertEqual(limit, 35)
            XCTAssertTrue(reason.contains("loadNewerFrames.reason=test"))
            return []
        }

        viewModel.test_windowFetchHooks.getFramesWithVideoInfoAfter = { timestamp, limit, filters, reason in
            recordedAfterCalls.append((timestamp, limit, filters.startDate, filters.endDate, reason))
            XCTAssertEqual(timestamp, baseDate.addingTimeInterval(1))
            XCTAssertEqual(limit, 35)
            XCTAssertNil(filters.startDate)
            XCTAssertNil(filters.endDate)
            XCTAssertTrue(reason.contains("nearestFallback"))

            return [
                self.makeFrameWithVideoInfo(
                    id: 22,
                    timestamp: baseDate.addingTimeInterval(120),
                    frameIndex: 2,
                    bundleID: "com.apple.Retrace"
                ),
                self.makeFrameWithVideoInfo(
                    id: 23,
                    timestamp: baseDate.addingTimeInterval(240),
                    frameIndex: 3,
                    bundleID: "com.apple.Retrace"
                )
            ]
        }

        await viewModel.test_loadNewerFrames()

        XCTAssertEqual(recordedWindowCalls.count, 1)
        XCTAssertEqual(recordedWindowCalls.first?.limit, 35)
        XCTAssertEqual(recordedAfterCalls.count, 1)
        XCTAssertEqual(recordedAfterCalls.first?.limit, 35)
        XCTAssertEqual(viewModel.frames.count, 4)
        XCTAssertEqual(viewModel.frames[2].frame.id.value, 22)
        XCTAssertEqual(viewModel.frames[3].frame.id.value, 23)
        XCTAssertEqual(viewModel.currentIndex, 3)

        let paginationState = viewModel.test_boundaryPaginationState()
        XCTAssertTrue(paginationState.hasMoreNewer)
        XCTAssertFalse(paginationState.hasReachedAbsoluteEnd)
    }

    func testLoadNewerFramesDuringFrameIDSearchKeepsCurrentSelection() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_600_000)

        viewModel.frames = [
            makeTimelineFrame(
                id: 30,
                timestamp: baseDate,
                frameIndex: 0,
                bundleID: "com.apple.Safari"
            ),
            makeTimelineFrame(
                id: 31,
                timestamp: baseDate.addingTimeInterval(1),
                frameIndex: 1,
                bundleID: "com.apple.Safari"
            )
        ]
        viewModel.currentIndex = 1
        viewModel.filterCriteria = FilterCriteria()
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: false, hasMoreNewer: true)
        viewModel.test_updateWindowBoundaries()

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { from, to, limit, _, reason in
            XCTAssertEqual(limit, 35)
            XCTAssertTrue(reason.contains("loadNewerFrames.reason=searchForFrameID"))

            return (1...35).map { offset in
                self.makeFrameWithVideoInfo(
                    id: 100 + Int64(offset),
                    timestamp: baseDate.addingTimeInterval(Double(offset + 10)),
                    frameIndex: offset + 1,
                    bundleID: "com.apple.Retrace"
                )
            }
        }

        await viewModel.test_loadNewerFrames(reason: "searchForFrameID")

        XCTAssertEqual(viewModel.frames.count, 37)
        XCTAssertEqual(viewModel.currentIndex, 1)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 31)
    }

    private func makeTimelineFrame(
        id: Int64,
        timestamp: Date,
        frameIndex: Int,
        bundleID: String
    ) -> TimelineFrame {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: bundleID,
                appName: "Test App",
                displayID: 1
            )
        )

        return TimelineFrame(frame: frame, videoInfo: nil, processingStatus: 2)
    }

    private func makeFrameWithVideoInfo(
        id: Int64,
        timestamp: Date,
        frameIndex: Int,
        bundleID: String
    ) -> FrameWithVideoInfo {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: bundleID,
                appName: "Test App",
                displayID: 1
            )
        )

        return FrameWithVideoInfo(
            frame: frame,
            videoInfo: nil,
            processingStatus: 2,
            videoCurrentTime: nil,
            scrollY: nil
        )
    }
}
