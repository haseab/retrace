import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class TimelineBlockNavigationTests: XCTestCase {

    func testNavigateToPreviousBlockStartJumpsToCurrentBlockStartWhenInMiddle() async {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "B", "C"])
        viewModel.currentIndex = 3

        let didNavigate = await viewModel.navigateToPreviousBlockStart()
        XCTAssertTrue(didNavigate)
        XCTAssertEqual(viewModel.currentIndex, 2)
    }

    func testNavigateToPreviousBlockStartJumpsAcrossBlocks() async {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "B", "C"])
        viewModel.currentIndex = 4

        let firstNavigation = await viewModel.navigateToPreviousBlockStart()
        XCTAssertTrue(firstNavigation)
        XCTAssertEqual(viewModel.currentIndex, 2)

        let secondNavigation = await viewModel.navigateToPreviousBlockStart()
        XCTAssertTrue(secondNavigation)
        XCTAssertEqual(viewModel.currentIndex, 0)
    }

    func testNavigateToPreviousBlockStartReturnsFalseAtBeginning() async {
        let viewModel = makeViewModelWithFrames(["A", "A", "B"])
        viewModel.currentIndex = 0

        let didNavigate = await viewModel.navigateToPreviousBlockStart()
        XCTAssertFalse(didNavigate)
        XCTAssertEqual(viewModel.currentIndex, 0)
    }

    func testNavigateToPreviousBlockStartResolvesLeadingLoadedBlockFromDatabaseWhenInsideLeftmostBlock() async {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let viewModel = makeViewModelWithFrames(["A", "A", "A", "B"], baseDate: baseDate)
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: true, hasMoreNewer: false)
        viewModel.currentIndex = 2

        let targetFrame = TimelineTestFactories.makeFrameWithVideoInfo(
            id: 10,
            timestamp: baseDate.addingTimeInterval(-180),
            frameIndex: 0,
            bundleID: "A",
        )

        viewModel.test_windowFetchHooks.getVisibleBlockBoundary = { anchorFrame, _, direction in
            XCTAssertEqual(anchorFrame.id.value, 1)
            XCTAssertEqual(direction, .start)
            return VisibleBlockBoundaryHit(
                frameID: targetFrame.frame.id,
                timestamp: targetFrame.frame.timestamp
            )
        }
        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { _, _, _, _, reason in
            XCTAssertEqual(reason, "navigateToPreviousBlockStart")
            return [targetFrame]
        }

        let didNavigate = await viewModel.navigateToPreviousBlockStart()
        XCTAssertTrue(didNavigate)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 10)
        XCTAssertEqual(viewModel.currentIndex, 0)
    }

    func testNavigateToPreviousBlockStartFallsBackToLoadedBlockStartWhenBoundaryLookupFindsNothing() async {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let viewModel = makeViewModelWithFrames(["A", "A", "B"], baseDate: baseDate)
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: true, hasMoreNewer: false)
        viewModel.currentIndex = 1

        viewModel.test_windowFetchHooks.getVisibleBlockBoundary = { anchorFrame, _, direction in
            XCTAssertEqual(anchorFrame.id.value, 1)
            XCTAssertEqual(direction, .start)
            return nil
        }

        let didNavigate = await viewModel.navigateToPreviousBlockStart()
        XCTAssertTrue(didNavigate)
        XCTAssertEqual(viewModel.currentIndex, 0)
    }

    func testNavigateToPreviousBlockStartFallsBackToLoadedBlockStartWhenBoundaryLookupReturnsAnchorFrame() async {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let viewModel = makeViewModelWithFrames(["A", "A", "B"], baseDate: baseDate)
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: true, hasMoreNewer: false)
        viewModel.currentIndex = 1

        viewModel.test_windowFetchHooks.getVisibleBlockBoundary = { anchorFrame, _, direction in
            XCTAssertEqual(anchorFrame.id.value, 1)
            XCTAssertEqual(direction, .start)
            return VisibleBlockBoundaryHit(
                frameID: anchorFrame.id,
                timestamp: anchorFrame.timestamp
            )
        }

        let didNavigate = await viewModel.navigateToPreviousBlockStart()
        XCTAssertTrue(didNavigate)
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

    func testNavigateToNextBlockStartOrNewestFrameJumpsToNewestFrameInLastBlock() async {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "C", "C"])
        viewModel.currentIndex = 3

        let didNavigate = await viewModel.navigateToNextBlockStartOrNewestFrame()
        XCTAssertTrue(didNavigate)
        XCTAssertEqual(viewModel.currentIndex, 4)
    }

    func testNavigateToNextBlockStartOrNewestFrameReturnsFalseAtNewestFrame() async {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "C", "C"])
        viewModel.currentIndex = 4

        let didNavigate = await viewModel.navigateToNextBlockStartOrNewestFrame()
        XCTAssertFalse(didNavigate)
        XCTAssertEqual(viewModel.currentIndex, 4)
    }

    func testNavigateToNextBlockStartOrNewestFrameStillJumpsToNextBlockStart() async {
        let viewModel = makeViewModelWithFrames(["A", "A", "B", "B", "C"])
        viewModel.currentIndex = 1

        let didNavigate = await viewModel.navigateToNextBlockStartOrNewestFrame()
        XCTAssertTrue(didNavigate)
        XCTAssertEqual(viewModel.currentIndex, 2)
    }

    func testNavigateToNextBlockStartOrNewestFrameResolvesTrailingLoadedBlockFromDatabaseWhenInsideRightmostBlock() async {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let viewModel = makeViewModelWithFrames(["A", "B", "B", "B"], baseDate: baseDate)
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: false, hasMoreNewer: true)
        viewModel.currentIndex = 1

        let targetFrame = TimelineTestFactories.makeFrameWithVideoInfo(
            id: 20,
            timestamp: baseDate.addingTimeInterval(180),
            frameIndex: 3,
            bundleID: "B",
        )

        viewModel.test_windowFetchHooks.getVisibleBlockBoundary = { anchorFrame, _, direction in
            XCTAssertEqual(anchorFrame.id.value, 4)
            XCTAssertEqual(direction, .end)
            return VisibleBlockBoundaryHit(
                frameID: targetFrame.frame.id,
                timestamp: targetFrame.frame.timestamp
            )
        }
        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { _, _, _, _, reason in
            XCTAssertEqual(reason, "navigateToNextBlockStartOrNewestFrame")
            return [targetFrame]
        }

        let didNavigate = await viewModel.navigateToNextBlockStartOrNewestFrame()
        XCTAssertTrue(didNavigate)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 20)
        XCTAssertEqual(viewModel.currentIndex, 0)
    }

    func testNavigateToNextBlockStartOrNewestFrameFallsBackToLoadedBlockEndWhenBoundaryLookupFindsNothing() async {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let viewModel = makeViewModelWithFrames(["A", "B", "B"], baseDate: baseDate)
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: false, hasMoreNewer: true)
        viewModel.currentIndex = 1

        viewModel.test_windowFetchHooks.getVisibleBlockBoundary = { anchorFrame, _, direction in
            XCTAssertEqual(anchorFrame.id.value, 3)
            XCTAssertEqual(direction, .end)
            return nil
        }

        let didNavigate = await viewModel.navigateToNextBlockStartOrNewestFrame()
        XCTAssertTrue(didNavigate)
        XCTAssertEqual(viewModel.currentIndex, 2)
    }

    func testNavigateToNextBlockStartOrNewestFrameFallsBackToLoadedBlockEndWhenBoundaryLookupReturnsAnchorFrame() async {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let viewModel = makeViewModelWithFrames(["A", "B", "B"], baseDate: baseDate)
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: false, hasMoreNewer: true)
        viewModel.currentIndex = 1

        viewModel.test_windowFetchHooks.getVisibleBlockBoundary = { anchorFrame, _, direction in
            XCTAssertEqual(anchorFrame.id.value, 3)
            XCTAssertEqual(direction, .end)
            return VisibleBlockBoundaryHit(
                frameID: anchorFrame.id,
                timestamp: anchorFrame.timestamp
            )
        }

        let didNavigate = await viewModel.navigateToNextBlockStartOrNewestFrame()
        XCTAssertTrue(didNavigate)
        XCTAssertEqual(viewModel.currentIndex, 2)
    }

    func testNavigateToPreviousBlockStartIgnoresStaleWindowFetchAfterPlayheadMoves() async {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let viewModel = makeViewModelWithFrames(["A", "A", "A", "B"], baseDate: baseDate)
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: true, hasMoreNewer: false)
        viewModel.currentIndex = 2

        let targetFrame = TimelineTestFactories.makeFrameWithVideoInfo(
            id: 10,
            timestamp: baseDate.addingTimeInterval(-180),
            frameIndex: 0,
            bundleID: "A",
        )
        let fetchStarted = expectation(description: "block navigation fetch started")
        var releaseFetchContinuation: CheckedContinuation<Void, Never>?

        viewModel.test_windowFetchHooks.getVisibleBlockBoundary = { anchorFrame, _, direction in
            XCTAssertEqual(anchorFrame.id.value, 1)
            XCTAssertEqual(direction, .start)
            return VisibleBlockBoundaryHit(
                frameID: targetFrame.frame.id,
                timestamp: targetFrame.frame.timestamp
            )
        }
        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { _, _, _, _, reason in
            XCTAssertEqual(reason, "navigateToPreviousBlockStart")
            fetchStarted.fulfill()
            await withCheckedContinuation { continuation in
                releaseFetchContinuation = continuation
            }
            return [targetFrame]
        }

        let navigationTask = Task {
            await viewModel.navigateToPreviousBlockStart()
        }

        await fulfillment(of: [fetchStarted], timeout: 1.0)
        viewModel.navigateToFrame(3)
        releaseFetchContinuation?.resume()

        let didNavigate = await navigationTask.value
        XCTAssertFalse(didNavigate)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 4)
        XCTAssertEqual(viewModel.frames.map(\.frame.id.value), [1, 2, 3, 4])
    }

    private func makeViewModelWithFrames(
        _ bundleIDs: [String],
        baseDate: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SimpleTimelineViewModel {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())

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
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: false, hasMoreNewer: false)
        return viewModel
    }
}
