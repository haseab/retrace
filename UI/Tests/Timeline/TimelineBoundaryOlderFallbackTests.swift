import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class TimelineBoundaryOlderFallbackTests: XCTestCase {
    func testLoadOlderFramesFallsBackToNearestQueryAfterEmptyWindowedProbe() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_400_000)
        var recordedCalls: [(limit: Int, startDate: Date?, endDate: Date?, reason: String)] = []

        viewModel.frames = [
            makeTimelineFrame(
                id: 10,
                timestamp: baseDate,
                frameIndex: 0,
                bundleID: "com.apple.Safari"
            ),
            makeTimelineFrame(
                id: 11,
                timestamp: baseDate.addingTimeInterval(1),
                frameIndex: 1,
                bundleID: "com.apple.Safari"
            )
        ]
        viewModel.currentIndex = 1
        viewModel.filterCriteria = FilterCriteria()
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: true, hasMoreNewer: false)
        viewModel.test_updateWindowBoundaries()

        viewModel.test_windowFetchHooks.getFramesWithVideoInfoBefore = { timestamp, limit, filters, reason in
            recordedCalls.append((limit, filters.startDate, filters.endDate, reason))
            if reason.contains("nearestFallback") {
                XCTAssertEqual(limit, 35)
                XCTAssertNil(filters.startDate)
                XCTAssertNil(filters.endDate)
                XCTAssertTrue(reason.contains("nearestFallback"))

                return [
                    self.makeFrameWithVideoInfo(
                        id: 8,
                        timestamp: baseDate.addingTimeInterval(-120),
                        frameIndex: 8,
                        bundleID: "com.apple.Rewind"
                    ),
                    self.makeFrameWithVideoInfo(
                        id: 7,
                        timestamp: baseDate.addingTimeInterval(-240),
                        frameIndex: 7,
                        bundleID: "com.apple.Rewind"
                    )
                ]
            }

            XCTAssertEqual(limit, 35)
            XCTAssertEqual(timestamp, baseDate)
            XCTAssertNotNil(filters.startDate)
            XCTAssertNotNil(filters.endDate)
            XCTAssertFalse(reason.contains("nearestFallback"))
            return []
        }

        await viewModel.test_loadOlderFrames()

        XCTAssertEqual(recordedCalls.count, 2)
        XCTAssertEqual(recordedCalls.map(\.limit), [35, 35])
        XCTAssertNotNil(recordedCalls[0].startDate)
        XCTAssertNotNil(recordedCalls[0].endDate)
        XCTAssertNil(recordedCalls[1].startDate)
        XCTAssertNil(recordedCalls[1].endDate)
        XCTAssertEqual(viewModel.frames.count, 4)
        XCTAssertEqual(viewModel.frames.first?.frame.id.value, 7)
        XCTAssertEqual(viewModel.frames[1].frame.id.value, 8)
        XCTAssertEqual(viewModel.currentIndex, 3)

        let paginationState = viewModel.test_boundaryPaginationState()
        XCTAssertTrue(paginationState.hasMoreOlder)
        XCTAssertFalse(paginationState.hasReachedAbsoluteStart)
    }

    func testLoadOlderFramesFallsBackToNearestQueryAfterSparseWindowedProbe() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_401_000)
        var recordedCalls: [(limit: Int, startDate: Date?, endDate: Date?, reason: String)] = []

        viewModel.frames = [
            makeTimelineFrame(
                id: 10,
                timestamp: baseDate,
                frameIndex: 0,
                bundleID: "com.apple.Safari"
            ),
            makeTimelineFrame(
                id: 11,
                timestamp: baseDate.addingTimeInterval(1),
                frameIndex: 1,
                bundleID: "com.apple.Safari"
            )
        ]
        viewModel.currentIndex = 1
        viewModel.filterCriteria = FilterCriteria()
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: true, hasMoreNewer: false)
        viewModel.test_updateWindowBoundaries()

        viewModel.test_windowFetchHooks.getFramesWithVideoInfoBefore = { timestamp, limit, filters, reason in
            recordedCalls.append((limit, filters.startDate, filters.endDate, reason))
            if reason.contains("nearestFallback") {
                XCTAssertEqual(limit, 35)
                XCTAssertNil(filters.startDate)
                XCTAssertNil(filters.endDate)
                XCTAssertTrue(reason.contains("nearestFallback"))

                return [
                    self.makeFrameWithVideoInfo(
                        id: 8,
                        timestamp: baseDate.addingTimeInterval(-120),
                        frameIndex: 8,
                        bundleID: "com.apple.Rewind"
                    ),
                    self.makeFrameWithVideoInfo(
                        id: 7,
                        timestamp: baseDate.addingTimeInterval(-240),
                        frameIndex: 7,
                        bundleID: "com.apple.Rewind"
                    )
                ]
            }

            XCTAssertEqual(limit, 35)
            XCTAssertEqual(timestamp, baseDate)
            XCTAssertNotNil(filters.startDate)
            XCTAssertNotNil(filters.endDate)
            XCTAssertFalse(reason.contains("nearestFallback"))
            return [
                self.makeFrameWithVideoInfo(
                    id: 9,
                    timestamp: baseDate.addingTimeInterval(-10),
                    frameIndex: 9,
                    bundleID: "com.apple.Rewind"
                )
            ]
        }

        await viewModel.test_loadOlderFrames()

        XCTAssertEqual(recordedCalls.count, 2)
        XCTAssertEqual(recordedCalls.map(\.limit), [35, 35])
        XCTAssertNotNil(recordedCalls[0].startDate)
        XCTAssertNotNil(recordedCalls[0].endDate)
        XCTAssertNil(recordedCalls[1].startDate)
        XCTAssertNil(recordedCalls[1].endDate)
        XCTAssertEqual(viewModel.frames.count, 4)
        XCTAssertEqual(viewModel.frames.first?.frame.id.value, 7)
        XCTAssertEqual(viewModel.frames[1].frame.id.value, 8)
        XCTAssertEqual(viewModel.currentIndex, 3)

        let paginationState = viewModel.test_boundaryPaginationState()
        XCTAssertTrue(paginationState.hasMoreOlder)
        XCTAssertFalse(paginationState.hasReachedAbsoluteStart)
    }

    func testLoadOlderFramesDropsStaleResultWhenFrameWindowChangesMidFetch() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_402_000)
        var beforeCallCount = 0

        viewModel.frames = [
            makeTimelineFrame(
                id: 10,
                timestamp: baseDate,
                frameIndex: 0,
                bundleID: "com.apple.Safari"
            ),
            makeTimelineFrame(
                id: 11,
                timestamp: baseDate.addingTimeInterval(1),
                frameIndex: 1,
                bundleID: "com.apple.Safari"
            )
        ]
        viewModel.currentIndex = 1
        viewModel.filterCriteria = FilterCriteria()
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: true, hasMoreNewer: false)
        viewModel.test_updateWindowBoundaries()

        viewModel.test_windowFetchHooks.getFramesWithVideoInfoBefore = { _, limit, _, reason in
            beforeCallCount += 1
            XCTAssertEqual(limit, 35)
            XCTAssertTrue(reason.contains("loadOlderFrames.reason=test"))

            // Simulate a jump/reload replacing the frame window while this boundary fetch is in flight.
            viewModel.frames = [
                self.makeTimelineFrame(
                    id: 100,
                    timestamp: baseDate.addingTimeInterval(600),
                    frameIndex: 0,
                    bundleID: "com.apple.Notes"
                ),
                self.makeTimelineFrame(
                    id: 101,
                    timestamp: baseDate.addingTimeInterval(601),
                    frameIndex: 1,
                    bundleID: "com.apple.Notes"
                )
            ]
            viewModel.currentIndex = 1
            viewModel.test_updateWindowBoundaries()

            return [
                self.makeFrameWithVideoInfo(
                    id: 8,
                    timestamp: baseDate.addingTimeInterval(-120),
                    frameIndex: 8,
                    bundleID: "com.apple.Rewind"
                ),
                self.makeFrameWithVideoInfo(
                    id: 7,
                    timestamp: baseDate.addingTimeInterval(-240),
                    frameIndex: 7,
                    bundleID: "com.apple.Rewind"
                )
            ]
        }

        await viewModel.test_loadOlderFrames()

        XCTAssertEqual(beforeCallCount, 2)
        XCTAssertEqual(viewModel.frames.count, 2)
        XCTAssertEqual(viewModel.frames.first?.frame.id.value, 100)
        XCTAssertEqual(viewModel.frames.last?.frame.id.value, 101)

        let paginationState = viewModel.test_boundaryPaginationState()
        XCTAssertTrue(paginationState.hasMoreOlder)
        XCTAssertFalse(paginationState.hasReachedAbsoluteStart)
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
