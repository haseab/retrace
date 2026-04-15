import Foundation
import Shared
import XCTest
@testable import Retrace

@MainActor
final class TimelineCommentBrowserWindowControllerTests: XCTestCase {
    func testApplyAndSnapshotRoundTrip() {
        let controller = TimelineCommentBrowserWindowController()
        let state = TimelineCommentBrowserWindowState(
            anchorID: SegmentCommentID(value: 9),
            visibleBeforeCount: 2,
            visibleAfterCount: 3,
            hasPerformedInitialScroll: true,
            isRequestingOlderPage: true,
            isRequestingNewerPage: false,
            pendingAnchorPinnedCommentID: SegmentCommentID(value: 7)
        )

        controller.apply(state)

        XCTAssertEqual(controller.snapshot(), state)
    }

    func testInitialScrollAnchorIfNeededReturnsAnchorOnceAndMarksPerformed() {
        let controller = TimelineCommentBrowserWindowController()

        let firstAnchor = controller.initialScrollAnchorIfNeeded(
            isBrowsingAllComments: true,
            anchorID: SegmentCommentID(value: 3),
            visibleRowIDs: [SegmentCommentID(value: 1), SegmentCommentID(value: 3)]
        )

        XCTAssertEqual(firstAnchor, SegmentCommentID(value: 3))
        XCTAssertTrue(controller.hasPerformedInitialScroll)

        let secondAnchor = controller.initialScrollAnchorIfNeeded(
            isBrowsingAllComments: true,
            anchorID: SegmentCommentID(value: 3),
            visibleRowIDs: [SegmentCommentID(value: 1), SegmentCommentID(value: 3)]
        )

        XCTAssertNil(secondAnchor)
    }

    func testConsumePinnedAnchorIfVisibleClearsPendingAnchor() {
        let controller = TimelineCommentBrowserWindowController()
        controller.pendingAnchorPinnedCommentID = SegmentCommentID(value: 4)

        let consumed = controller.consumePinnedAnchorIfVisible(
            isBrowsingAllComments: true,
            visibleRowIDs: [SegmentCommentID(value: 2), SegmentCommentID(value: 4)]
        )

        XCTAssertEqual(consumed, SegmentCommentID(value: 4))
        XCTAssertNil(controller.pendingAnchorPinnedCommentID)
    }

    func testSyncVisibleWindowUsesWindowSupportCounts() {
        let controller = TimelineCommentBrowserWindowController()
        let rowIDs = [1, 2, 3, 4, 5, 6].map { SegmentCommentID(value: Int64($0)) }
        let expected = TimelineCommentBrowserWindowSupport.syncedVisibleCounts(
            forceReset: true,
            anchorIndex: 2,
            totalRowCount: rowIDs.count,
            currentBeforeCount: 0,
            currentAfterCount: 0,
            selectedCommentIDs: [SegmentCommentID(value: 2), SegmentCommentID(value: 5)],
            rowIDs: rowIDs,
            pageSize: 5
        )

        controller.syncVisibleWindow(
            forceReset: true,
            anchorIndex: 2,
            totalRowCount: rowIDs.count,
            selectedCommentIDs: [SegmentCommentID(value: 2), SegmentCommentID(value: 5)],
            rowIDs: rowIDs,
            pageSize: 5
        )

        XCTAssertEqual(controller.visibleBeforeCount, expected?.before)
        XCTAssertEqual(controller.visibleAfterCount, expected?.after)
    }

    func testRequestOlderPageActionExpandsWindowBeforeLoading() {
        let controller = TimelineCommentBrowserWindowController()

        let action = controller.requestOlderPageAction(
            availableBeforeCount: 6,
            pageSize: 4,
            hasMorePages: true,
            isLoadingPage: false,
            anchorID: SegmentCommentID(value: 10)
        )

        XCTAssertEqual(action, .expandedWindow)
        XCTAssertEqual(controller.visibleBeforeCount, 4)
        XCTAssertEqual(controller.pendingAnchorPinnedCommentID, SegmentCommentID(value: 10))
        XCTAssertFalse(controller.isRequestingOlderPage)
    }

    func testRequestNewerPageActionStartsLoadWhenWindowAlreadyExpanded() {
        let controller = TimelineCommentBrowserWindowController()
        controller.visibleAfterCount = 5

        let action = controller.requestNewerPageAction(
            availableAfterCount: 5,
            pageSize: 4,
            hasMorePages: true,
            isLoadingPage: false,
            anchorID: SegmentCommentID(value: 8)
        )

        XCTAssertEqual(action, .loadPage)
        XCTAssertTrue(controller.isRequestingNewerPage)
        XCTAssertEqual(controller.pendingAnchorPinnedCommentID, SegmentCommentID(value: 8))

        controller.finishNewerPageRequest()
        XCTAssertFalse(controller.isRequestingNewerPage)
    }
}
