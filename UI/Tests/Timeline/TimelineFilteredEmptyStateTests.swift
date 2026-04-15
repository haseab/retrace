import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class TimelineFilteredEmptyStateTests: XCTestCase {
    func testLoadMostRecentFrameClearsStaleFramesWhenFilteredResultsAreEmpty() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_300_000)

        viewModel.frames = [
            makeTimelineFrame(
                id: 1,
                timestamp: baseDate,
                frameIndex: 0,
                bundleID: "com.apple.Safari"
            )
        ]
        viewModel.currentIndex = 0
        viewModel.currentImage = NSImage(size: NSSize(width: 12, height: 12))
        viewModel.setAppliedFilterCriteria(FilterCriteria(selectedApps: ["com.google.Chrome"]))

        viewModel.test_refreshFrameDataHooks.getMostRecentFramesWithVideoInfo = { limit, filters in
            XCTAssertGreaterThan(limit, 0)
            XCTAssertTrue(filters.hasActiveFilters)
            return []
        }

        await viewModel.loadMostRecentFrame()

        XCTAssertTrue(viewModel.frames.isEmpty)
        XCTAssertEqual(viewModel.currentIndex, 0)
        XCTAssertNil(viewModel.currentFrame)
        XCTAssertNil(viewModel.currentImage)
        XCTAssertEqual(
            viewModel.error,
            "No frames found matching the current filters. Clear filters to see all frames."
        )
        XCTAssertFalse(viewModel.isLoading)
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
}
