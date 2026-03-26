import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class TimelineRefreshTrimRegressionTests: XCTestCase {
    func testRefreshFrameDataTrimPreservesNewestIndexAfterAppend() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        viewModel.frames = (0..<100).map { offset in
            makeTimelineFrame(
                id: Int64(offset + 1),
                timestamp: baseDate.addingTimeInterval(TimeInterval(offset)),
                frameIndex: offset,
                processingStatus: 4
            )
        }
        viewModel.currentIndex = 95

        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { limit, _ in
            XCTAssertEqual(limit, 50)
            return (100..<112).reversed().map { offset in
                let timestamp = baseDate.addingTimeInterval(TimeInterval(offset))
                return self.makeFrameWithVideoInfo(
                    id: Int64(offset + 1),
                    timestamp: timestamp,
                    frameIndex: offset,
                    processingStatus: 4
                )
            }
        }

        await viewModel.refreshFrameData(navigateToNewest: true)

        XCTAssertEqual(viewModel.frames.count, 100)
        XCTAssertEqual(viewModel.currentIndex, 99)
        XCTAssertEqual(
            viewModel.currentTimelineFrame?.frame.timestamp,
            baseDate.addingTimeInterval(111)
        )
    }

    func testRefreshFrameDataDefersTrimWhileActivelyScrollingAndAnchorsAfterScrollEnds() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_020_000)

        viewModel.frames = (0..<100).map { offset in
            makeTimelineFrame(
                id: Int64(offset + 1),
                timestamp: baseDate.addingTimeInterval(TimeInterval(offset)),
                frameIndex: offset,
                processingStatus: 4
            )
        }
        viewModel.currentIndex = 95
        viewModel.isActivelyScrolling = true

        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { limit, _ in
            XCTAssertEqual(limit, 50)
            return (100..<112).reversed().map { offset in
                let timestamp = baseDate.addingTimeInterval(TimeInterval(offset))
                return self.makeFrameWithVideoInfo(
                    id: Int64(offset + 1),
                    timestamp: timestamp,
                    frameIndex: offset,
                    processingStatus: 4
                )
            }
        }

        await viewModel.refreshFrameData(navigateToNewest: true)

        // While scrubbing, trim should be deferred (window can exceed max in-memory size).
        XCTAssertEqual(viewModel.frames.count, 112)
        XCTAssertEqual(viewModel.currentIndex, 111)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 112)

        // Scroll end should apply deferred trim and keep playhead anchored to the same frame.
        viewModel.isActivelyScrolling = false

        XCTAssertEqual(viewModel.frames.count, 100)
        XCTAssertEqual(viewModel.currentIndex, 99)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 112)
        XCTAssertEqual(
            viewModel.currentTimelineFrame?.frame.timestamp,
            baseDate.addingTimeInterval(111)
        )
    }

    func testDeferredTrimTracksLatestScrubbedFrameBeforeScrollEnds() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_030_000)

        viewModel.frames = (0..<100).map { offset in
            makeTimelineFrame(
                id: Int64(offset + 1),
                timestamp: baseDate.addingTimeInterval(TimeInterval(offset)),
                frameIndex: offset,
                processingStatus: 4
            )
        }
        viewModel.currentIndex = 95
        viewModel.isActivelyScrolling = true

        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { limit, _ in
            XCTAssertEqual(limit, 50)
            return (100..<112).reversed().map { offset in
                let timestamp = baseDate.addingTimeInterval(TimeInterval(offset))
                return self.makeFrameWithVideoInfo(
                    id: Int64(offset + 1),
                    timestamp: timestamp,
                    frameIndex: offset,
                    processingStatus: 4
                )
            }
        }

        await viewModel.refreshFrameData(navigateToNewest: true)

        XCTAssertEqual(viewModel.frames.count, 112)
        XCTAssertEqual(viewModel.currentIndex, 111)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 112)

        // Simulate the user continuing to scrub after the trim was deferred.
        viewModel.currentIndex = 95
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 96)

        viewModel.isActivelyScrolling = false

        XCTAssertEqual(viewModel.frames.count, 100)
        XCTAssertEqual(viewModel.currentIndex, 83)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 96)
        XCTAssertEqual(
            viewModel.currentTimelineFrame?.frame.timestamp,
            baseDate.addingTimeInterval(95)
        )
    }

    func testRefreshFrameDataDoesNotForceNewestReloadWhenNavigateToNewestIsFalseAndWindowIsStale() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_100_000)

        viewModel.filterCriteria = FilterCriteria(selectedApps: ["com.google.Chrome"])
        viewModel.frames = (0..<100).map { offset in
            makeTimelineFrame(
                id: Int64(offset + 1),
                timestamp: baseDate.addingTimeInterval(TimeInterval(offset)),
                frameIndex: offset,
                processingStatus: 2
            )
        }
        viewModel.currentIndex = 10

        let originalFrameIDs = viewModel.frames.map(\.frame.id.value)
        let originalNewestTimestamp = viewModel.frames.last?.frame.timestamp

        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { limit, filters in
            XCTAssertEqual(limit, 50)
            XCTAssertTrue(filters.hasActiveFilters)
            return (200..<250).reversed().map { offset in
                let timestamp = baseDate.addingTimeInterval(TimeInterval(offset))
                return self.makeFrameWithVideoInfo(
                    id: Int64(offset + 1),
                    timestamp: timestamp,
                    frameIndex: offset,
                    processingStatus: 2
                )
            }
        }

        await viewModel.refreshFrameData(navigateToNewest: false, allowNearLiveAutoAdvance: false)

        XCTAssertEqual(viewModel.currentIndex, 10)
        XCTAssertEqual(viewModel.frames.count, 100)
        XCTAssertEqual(viewModel.frames.map(\.frame.id.value), originalFrameIDs)
        XCTAssertEqual(viewModel.frames.last?.frame.timestamp, originalNewestTimestamp)
    }

    func testRefreshFrameDataTreatsStaleLoadedTapeAsHistoricalEvenNearLoadedEdge() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_200_000)

        viewModel.frames = (0..<100).map { offset in
            makeTimelineFrame(
                id: Int64(offset + 1),
                timestamp: baseDate.addingTimeInterval(TimeInterval(offset)),
                frameIndex: offset,
                processingStatus: 2
            )
        }
        viewModel.currentIndex = 95

        let originalFrameIDs = viewModel.frames.map(\.frame.id.value)
        let originalNewestTimestamp = viewModel.frames.last?.frame.timestamp
        var fetchInvocationCount = 0

        viewModel.test_refreshFrameDataHooks.now = {
            baseDate.addingTimeInterval(10 * 24 * 60 * 60)
        }
        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { _, _ in
            fetchInvocationCount += 1
            return []
        }

        await viewModel.refreshFrameData(
            navigateToNewest: false,
            allowNearLiveAutoAdvance: true,
            refreshPresentation: false
        )

        XCTAssertEqual(fetchInvocationCount, 0)
        XCTAssertEqual(viewModel.currentIndex, 95)
        XCTAssertEqual(viewModel.frames.map(\.frame.id.value), originalFrameIDs)
        XCTAssertEqual(viewModel.frames.last?.frame.timestamp, originalNewestTimestamp)
    }

    private func makeTimelineFrame(
        id: Int64,
        timestamp: Date,
        frameIndex: Int,
        processingStatus: Int
    ) -> TimelineFrame {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: "test.app",
                appName: "Test App",
                displayID: 1
            )
        )

        return TimelineFrame(frame: frame, videoInfo: nil, processingStatus: processingStatus)
    }

    private func makeFrameWithVideoInfo(
        id: Int64,
        timestamp: Date,
        frameIndex: Int,
        processingStatus: Int
    ) -> FrameWithVideoInfo {
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: timestamp,
            segmentID: AppSegmentID(value: id),
            frameIndexInSegment: frameIndex,
            metadata: FrameMetadata(
                appBundleID: "test.app",
                appName: "Test App",
                displayID: 1
            )
        )

        return FrameWithVideoInfo(frame: frame, videoInfo: nil, processingStatus: processingStatus)
    }
}
