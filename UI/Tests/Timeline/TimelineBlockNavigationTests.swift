import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class TimelineBlockNavigationTests: XCTestCase {

    func testNavigateToPreviousBlockStartJumpsAcrossBlocks() {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "B", "C"])
        viewModel.currentIndex = 4

        XCTAssertTrue(viewModel.navigateToPreviousBlockStart())
        XCTAssertEqual(viewModel.currentIndex, 2)

        XCTAssertTrue(viewModel.navigateToPreviousBlockStart())
        XCTAssertEqual(viewModel.currentIndex, 0)
    }

    func testNavigateToPreviousBlockStartReturnsFalseAtBeginning() {
        let viewModel = makeViewModelWithFrames(["A", "A", "B"])
        viewModel.currentIndex = 0

        XCTAssertFalse(viewModel.navigateToPreviousBlockStart())
        XCTAssertEqual(viewModel.currentIndex, 0)
    }

    func testNavigateToNextBlockStartJumpsAcrossBlocks() {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "B", "C"])
        viewModel.currentIndex = 0

        XCTAssertTrue(viewModel.navigateToNextBlockStart())
        XCTAssertEqual(viewModel.currentIndex, 2)

        XCTAssertTrue(viewModel.navigateToNextBlockStart())
        XCTAssertEqual(viewModel.currentIndex, 4)
    }

    func testNavigateToNextBlockStartReturnsFalseAtEnd() {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "B", "C"])
        viewModel.currentIndex = 4

        XCTAssertFalse(viewModel.navigateToNextBlockStart())
        XCTAssertEqual(viewModel.currentIndex, 4)
    }

    func testNavigateToNextBlockStartOrNewestFrameJumpsToNewestFrameInLastBlock() {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "C", "C"])
        viewModel.currentIndex = 3

        XCTAssertTrue(viewModel.navigateToNextBlockStartOrNewestFrame())
        XCTAssertEqual(viewModel.currentIndex, 4)
    }

    func testNavigateToNextBlockStartOrNewestFrameReturnsFalseAtNewestFrame() {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "C", "C"])
        viewModel.currentIndex = 4

        XCTAssertFalse(viewModel.navigateToNextBlockStartOrNewestFrame())
        XCTAssertEqual(viewModel.currentIndex, 4)
    }

    func testNavigateToNextBlockStartOrNewestFrameStillJumpsToNextBlockStart() {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "B", "C"])
        viewModel.currentIndex = 1

        XCTAssertTrue(viewModel.navigateToNextBlockStartOrNewestFrame())
        XCTAssertEqual(viewModel.currentIndex, 2)
    }

    private func makeViewModelWithFrames(_ bundleIDs: [String]) -> SimpleTimelineViewModel {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        viewModel.frames = bundleIDs.enumerated().map { index, bundleID in
            let frame = FrameReference(
                id: FrameID(value: Int64(index + 1)),
                timestamp: baseDate.addingTimeInterval(TimeInterval(index)),
                segmentID: AppSegmentID(value: Int64(index + 1)),
                frameIndexInSegment: index,
                metadata: FrameMetadata(
                    appBundleID: bundleID,
                    appName: bundleID,
                    displayID: 1
                )
            )

            return TimelineFrame(frame: frame, videoInfo: nil, processingStatus: 2)
        }

        viewModel.currentIndex = 0
        return viewModel
    }
}
