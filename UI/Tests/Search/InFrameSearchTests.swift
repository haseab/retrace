import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class InFrameSearchTests: XCTestCase {
    func testSetInFrameSearchQueryAppliesHighlightAfterDebounce() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Error in handler")
        ]

        viewModel.openInFrameSearch()
        viewModel.setInFrameSearchQuery("error")

        XCTAssertTrue(viewModel.isInFrameSearchVisible)
        XCTAssertNil(viewModel.searchHighlightQuery)
        XCTAssertFalse(viewModel.isShowingSearchHighlight)

        try? await Task.sleep(for: .milliseconds(60), clock: .continuous)

        XCTAssertEqual(viewModel.searchHighlightQuery, "error")
        XCTAssertTrue(viewModel.isShowingSearchHighlight)
        XCTAssertEqual(viewModel.searchHighlightNodes.map(\.node.id), [1])
    }

    func testCloseInFrameSearchClearsQueryAndHighlight() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Error in handler")
        ]

        viewModel.openInFrameSearch()
        viewModel.setInFrameSearchQuery("error")
        viewModel.closeInFrameSearch(clearQuery: true)
        try? await Task.sleep(for: .milliseconds(60), clock: .continuous)

        XCTAssertFalse(viewModel.isInFrameSearchVisible)
        XCTAssertEqual(viewModel.inFrameSearchQuery, "")
        XCTAssertFalse(viewModel.isShowingSearchHighlight)
        XCTAssertNil(viewModel.searchHighlightQuery)
    }

    func testToggleInFrameSearchClosesWhenAlreadyVisible() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.ocrNodes = [
            makeNode(id: 1, text: "Error in handler")
        ]

        viewModel.toggleInFrameSearch()
        viewModel.setInFrameSearchQuery("error")
        try? await Task.sleep(for: .milliseconds(60), clock: .continuous)
        XCTAssertTrue(viewModel.isInFrameSearchVisible)
        XCTAssertTrue(viewModel.isShowingSearchHighlight)

        viewModel.toggleInFrameSearch()

        XCTAssertFalse(viewModel.isInFrameSearchVisible)
        XCTAssertEqual(viewModel.inFrameSearchQuery, "")
        XCTAssertFalse(viewModel.isShowingSearchHighlight)
        XCTAssertNil(viewModel.searchHighlightQuery)
    }

    func testResetSearchHighlightStateCancelsPendingSearchHighlightPresentation() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())

        viewModel.showSearchHighlight(query: "error")
        viewModel.resetSearchHighlightState()

        XCTAssertFalse(viewModel.isShowingSearchHighlight)
        XCTAssertNil(viewModel.searchHighlightQuery)

        try? await Task.sleep(for: .milliseconds(650), clock: .continuous)

        XCTAssertFalse(viewModel.isShowingSearchHighlight)
        XCTAssertNil(viewModel.searchHighlightQuery)
    }

    func testNavigateToFrameKeepsHighlightWhenInFrameSearchIsActive() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 2, frameIndex: 1, bundleID: "com.apple.Safari")
        ]
        viewModel.currentIndex = 0

        viewModel.openInFrameSearch()
        viewModel.setInFrameSearchQuery("error")
        try? await Task.sleep(for: .milliseconds(60), clock: .continuous)
        viewModel.navigateToFrame(1)

        XCTAssertEqual(viewModel.currentIndex, 1)
        XCTAssertTrue(viewModel.isShowingSearchHighlight)
        XCTAssertEqual(viewModel.searchHighlightQuery, "error")
    }

    func testUndoClearsSearchResultHighlight() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 2, frameIndex: 1, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 3, frameIndex: 2, bundleID: "com.apple.Safari")
        ]
        viewModel.currentIndex = 0

        // Build undo history through real navigation/stopped-position recording.
        viewModel.navigateToFrame(1)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
        viewModel.navigateToFrame(2)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)

        viewModel.showSearchHighlight(query: "error")
        try? await Task.sleep(for: .milliseconds(650), clock: .continuous)
        XCTAssertTrue(viewModel.isShowingSearchHighlight)
        XCTAssertEqual(viewModel.searchHighlightQuery, "error")

        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        XCTAssertEqual(viewModel.currentIndex, 1)
        XCTAssertFalse(viewModel.isShowingSearchHighlight)
        XCTAssertNil(viewModel.searchHighlightQuery)
    }

    func testUndoThreeTimesThenRedoThreeTimesReturnsToOriginalPosition() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 2, frameIndex: 1, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 3, frameIndex: 2, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 4, frameIndex: 3, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 5, frameIndex: 4, bundleID: "com.apple.Safari")
        ]
        viewModel.currentIndex = 0

        // Build stop-history entries at indices 1,2,3,4.
        viewModel.navigateToFrame(1)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
        viewModel.navigateToFrame(2)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
        viewModel.navigateToFrame(3)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
        viewModel.navigateToFrame(4)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)

        XCTAssertEqual(viewModel.currentIndex, 4)

        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        XCTAssertEqual(viewModel.currentIndex, 3)
        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        XCTAssertEqual(viewModel.currentIndex, 2)
        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        XCTAssertEqual(viewModel.currentIndex, 1)

        XCTAssertTrue(viewModel.redoLastUndonePosition())
        XCTAssertEqual(viewModel.currentIndex, 2)
        XCTAssertTrue(viewModel.redoLastUndonePosition())
        XCTAssertEqual(viewModel.currentIndex, 3)
        XCTAssertTrue(viewModel.redoLastUndonePosition())
        XCTAssertEqual(viewModel.currentIndex, 4)
    }

    func testNewNavigationClearsRedoHistoryImmediately() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 2, frameIndex: 1, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 3, frameIndex: 2, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 4, frameIndex: 3, bundleID: "com.apple.Safari")
        ]
        viewModel.currentIndex = 0

        viewModel.navigateToFrame(1)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
        viewModel.navigateToFrame(2)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
        viewModel.navigateToFrame(3)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)

        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        XCTAssertEqual(viewModel.currentIndex, 2)

        // New navigation branch should invalidate redo chain.
        viewModel.navigateToFrame(1)

        XCTAssertFalse(viewModel.redoLastUndonePosition())
    }

    func testUndoSlowPathResetsBoundaryStateViaSharedReloadPath() async {
        final class FetchTracker {
            var reloadWindowFetches = 0
            var postReloadNewerLoadAttempts = 0
        }

        let tracker = FetchTracker()
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        // Build undo history away from boundaries so it doesn't mutate pagination flags.
        viewModel.frames = (0..<50).map { offset in
            makeTimelineFrame(
                id: Int64(offset + 1),
                frameIndex: offset,
                bundleID: "com.apple.Safari"
            )
        }
        viewModel.currentIndex = 24
        viewModel.navigateToFrame(25)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)
        viewModel.navigateToFrame(26)
        try? await Task.sleep(for: .milliseconds(500), clock: .continuous)

        // Replace the in-memory window so undo must take slow path (frame ID #26 no longer loaded).
        viewModel.frames = (0..<10).map { offset in
            makeTimelineFrame(
                id: Int64(200 + offset),
                frameIndex: offset,
                bundleID: "com.apple.Safari"
            )
        }
        viewModel.currentIndex = 8

        viewModel.test_windowFetchHooks.getFramesWithVideoInfoBefore = { _, _, _, _ in [] }
        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { _, _, _, _, reason in
            if reason == "reloadFramesAroundTimestamp" {
                tracker.reloadWindowFetches += 1
                return (0..<10).map { offset in
                    let id: Int64 = (offset == 9) ? 26 : Int64(500 + offset)
                    return self.makeFrameWithVideoInfo(
                        id: id,
                        timestamp: baseDate.addingTimeInterval(120 + TimeInterval(offset)),
                        frameIndex: offset,
                        bundleID: "com.apple.Safari"
                    )
                }
            }

            if reason.contains("loadNewerFrames.reason=reloadFramesAroundTimestamp")
                || reason.contains("loadNewerFrames.reason=navigateToUndoPosition.postReloadFramePin") {
                tracker.postReloadNewerLoadAttempts += 1
                return [
                    self.makeFrameWithVideoInfo(
                        id: 999,
                        timestamp: baseDate.addingTimeInterval(600),
                        frameIndex: 99,
                        bundleID: "com.apple.Safari"
                    )
                ]
            }

            return []
        }

        // Simulate stale boundary state from a previous "hit end" pagination result.
        viewModel.test_setBoundaryPaginationState(hasMoreOlder: true, hasMoreNewer: false)

        // Undo should now go through slow path + shared reload, which resets boundary state.
        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        try? await Task.sleep(for: .milliseconds(180), clock: .continuous)

        XCTAssertEqual(tracker.reloadWindowFetches, 1)
        XCTAssertGreaterThanOrEqual(tracker.postReloadNewerLoadAttempts, 1)
        XCTAssertTrue(viewModel.frames.contains(where: { $0.frame.id.value == 26 }))
    }

    func testNavigateToSearchResultAddsEachClickedResultToUndoHistory() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 2, frameIndex: 1, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 3, frameIndex: 2, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 4, frameIndex: 3, bundleID: "com.apple.Safari")
        ]
        viewModel.currentIndex = 0

        await viewModel.navigateToSearchResult(
            frameID: FrameID(value: 2),
            timestamp: viewModel.frames[1].frame.timestamp,
            highlightQuery: "error"
        )
        XCTAssertEqual(viewModel.currentIndex, 1)

        await viewModel.navigateToSearchResult(
            frameID: FrameID(value: 3),
            timestamp: viewModel.frames[2].frame.timestamp,
            highlightQuery: "error"
        )
        XCTAssertEqual(viewModel.currentIndex, 2)

        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        XCTAssertEqual(viewModel.currentIndex, 1)
        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        XCTAssertEqual(viewModel.currentIndex, 0)
    }

    func testNavigateToSearchResultSlowPathRecordsUndoHistory() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 2, frameIndex: 1, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 3, frameIndex: 2, bundleID: "com.apple.Safari")
        ]
        viewModel.currentIndex = 1

        viewModel.test_windowFetchHooks.getFramesWithVideoInfo = { _, _, _, _, reason in
            switch reason {
            case "navigateToSearchResult":
                return [
                    self.makeFrameWithVideoInfo(
                        id: 49,
                        timestamp: baseDate.addingTimeInterval(119),
                        frameIndex: 49,
                        bundleID: "com.apple.Safari"
                    ),
                    self.makeFrameWithVideoInfo(
                        id: 50,
                        timestamp: baseDate.addingTimeInterval(120),
                        frameIndex: 50,
                        bundleID: "com.apple.Safari"
                    ),
                    self.makeFrameWithVideoInfo(
                        id: 51,
                        timestamp: baseDate.addingTimeInterval(121),
                        frameIndex: 51,
                        bundleID: "com.apple.Safari"
                    )
                ]
            case "reloadFramesAroundTimestamp":
                return [
                    self.makeFrameWithVideoInfo(
                        id: 1,
                        timestamp: baseDate,
                        frameIndex: 0,
                        bundleID: "com.apple.Safari"
                    ),
                    self.makeFrameWithVideoInfo(
                        id: 2,
                        timestamp: baseDate.addingTimeInterval(1),
                        frameIndex: 1,
                        bundleID: "com.apple.Safari"
                    ),
                    self.makeFrameWithVideoInfo(
                        id: 3,
                        timestamp: baseDate.addingTimeInterval(2),
                        frameIndex: 2,
                        bundleID: "com.apple.Safari"
                    )
                ]
            default:
                return []
            }
        }
        viewModel.test_windowFetchHooks.getFramesWithVideoInfoBefore = { _, _, _, _ in [] }
        viewModel.test_windowFetchHooks.getFramesWithVideoInfoAfter = { _, _, _, _ in [] }
        viewModel.test_frameOverlayLoadHooks.getOCRStatus = { _ in .completed }
        viewModel.test_frameOverlayLoadHooks.getAllOCRNodes = { _, _ in [] }

        await viewModel.navigateToSearchResult(
            frameID: FrameID(value: 50),
            timestamp: baseDate.addingTimeInterval(120),
            highlightQuery: "error"
        )

        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 50)
        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        try? await Task.sleep(for: .milliseconds(50), clock: .continuous)
        XCTAssertEqual(viewModel.currentTimelineFrame?.frame.id.value, 2)
    }

    func testUndoAndRedoRestoreSearchResultHighlightQuery() async {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.frames = [
            makeTimelineFrame(id: 1, frameIndex: 0, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 2, frameIndex: 1, bundleID: "com.apple.Safari"),
            makeTimelineFrame(id: 3, frameIndex: 2, bundleID: "com.apple.Safari")
        ]
        viewModel.currentIndex = 0

        await viewModel.navigateToSearchResult(
            frameID: FrameID(value: 2),
            timestamp: viewModel.frames[1].frame.timestamp,
            highlightQuery: "alpha"
        )
        await viewModel.navigateToSearchResult(
            frameID: FrameID(value: 3),
            timestamp: viewModel.frames[2].frame.timestamp,
            highlightQuery: "beta"
        )

        XCTAssertTrue(viewModel.undoToLastStoppedPosition())
        XCTAssertEqual(viewModel.currentIndex, 1)
        XCTAssertEqual(viewModel.searchHighlightQuery, "alpha")
        try? await Task.sleep(for: .milliseconds(650), clock: .continuous)
        XCTAssertTrue(viewModel.isShowingSearchHighlight)

        XCTAssertTrue(viewModel.redoLastUndonePosition())
        XCTAssertEqual(viewModel.currentIndex, 2)
        XCTAssertEqual(viewModel.searchHighlightQuery, "beta")
        try? await Task.sleep(for: .milliseconds(650), clock: .continuous)
        XCTAssertTrue(viewModel.isShowingSearchHighlight)
    }

    private func makeTimelineFrame(id: Int64, frameIndex: Int, bundleID: String) -> TimelineFrame {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let frame = FrameReference(
            id: FrameID(value: id),
            timestamp: baseDate.addingTimeInterval(TimeInterval(frameIndex)),
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

        return FrameWithVideoInfo(frame: frame, videoInfo: nil, processingStatus: 2)
    }

    private func makeNode(id: Int, text: String, x: CGFloat = 0.1, y: CGFloat = 0.1) -> OCRNodeWithText {
        OCRNodeWithText(
            id: id,
            frameId: 1,
            x: x,
            y: y,
            width: 0.3,
            height: 0.1,
            text: text
        )
    }
}
