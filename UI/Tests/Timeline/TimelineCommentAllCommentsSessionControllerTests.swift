import Shared
import XCTest
@testable import Retrace

@MainActor
final class TimelineCommentAllCommentsSessionControllerTests: XCTestCase {
    func testOpenAndExitAllCommentsCoordinateBrowserAndWindowControllers() {
        let controller = TimelineCommentAllCommentsSessionController()
        let browserController = TimelineCommentSubmenuBrowserController()
        let windowController = TimelineCommentBrowserWindowController()

        controller.openAllComments(
            anchorID: SegmentCommentID(value: 9),
            browserController: browserController,
            windowController: windowController
        )

        XCTAssertEqual(browserController.mode, .allComments)
        XCTAssertEqual(windowController.anchorID, SegmentCommentID(value: 9))
        XCTAssertFalse(windowController.hasPerformedInitialScroll)

        controller.exitAllComments(
            browserController: browserController,
            windowController: windowController
        )

        XCTAssertEqual(browserController.mode, .thread)
        XCTAssertNil(windowController.anchorID)
        XCTAssertEqual(windowController.visibleBeforeCount, 0)
        XCTAssertEqual(windowController.visibleAfterCount, 0)
    }

    func testSyncVisibleWindowDoesNothingOutsideAllComments() {
        let controller = TimelineCommentAllCommentsSessionController()
        let browserController = TimelineCommentSubmenuBrowserController()
        let windowController = TimelineCommentBrowserWindowController()

        controller.syncVisibleWindow(
            browserController: browserController,
            windowController: windowController,
            forceReset: true,
            anchorIndex: 2,
            totalRowCount: 6,
            selectedCommentIDs: Set(ids([2, 4])),
            rowIDs: ids([1, 2, 3, 4, 5, 6]),
            pageSize: 5
        )

        XCTAssertEqual(windowController.visibleBeforeCount, 0)
        XCTAssertEqual(windowController.visibleAfterCount, 0)
    }

    func testInitialAndPinnedScrollRequestsMapToScrollTargets() {
        let controller = TimelineCommentAllCommentsSessionController()
        let browserController = TimelineCommentSubmenuBrowserController()
        let windowController = TimelineCommentBrowserWindowController()

        controller.openAllComments(
            anchorID: SegmentCommentID(value: 5),
            browserController: browserController,
            windowController: windowController
        )

        XCTAssertEqual(
            controller.initialScrollRequest(
                browserController: browserController,
                windowController: windowController,
                anchorID: SegmentCommentID(value: 5),
                visibleRowIDs: ids([4, 5, 6])
            ),
            .scrollTo(SegmentCommentID(value: 5), animated: true)
        )

        windowController.pinAnchorForNextViewportUpdate(SegmentCommentID(value: 6))
        XCTAssertEqual(
            controller.restorePinnedAnchorRequest(
                browserController: browserController,
                windowController: windowController,
                visibleRowIDs: ids([5, 6, 7])
            ),
            .scrollTo(SegmentCommentID(value: 6), animated: false)
        )
    }

    func testRequestOlderPageAndFinishLoadExpandWindow() {
        let controller = TimelineCommentAllCommentsSessionController()
        let browserController = TimelineCommentSubmenuBrowserController()
        let windowController = TimelineCommentBrowserWindowController()
        controller.openAllComments(
            anchorID: SegmentCommentID(value: 3),
            browserController: browserController,
            windowController: windowController
        )

        let expandPlan = controller.requestOlderPage(
            browserController: browserController,
            windowController: windowController,
            availableBeforeCount: 6,
            pageSize: 4,
            hasMorePages: true,
            isLoadingPage: false,
            anchorID: SegmentCommentID(value: 3)
        )
        XCTAssertEqual(expandPlan, .expandedWindow)
        XCTAssertEqual(windowController.visibleBeforeCount, 4)

        let loadPlan = controller.requestOlderPage(
            browserController: browserController,
            windowController: windowController,
            availableBeforeCount: 4,
            pageSize: 4,
            hasMorePages: true,
            isLoadingPage: false,
            anchorID: SegmentCommentID(value: 3)
        )
        XCTAssertEqual(loadPlan, .loadOlderPage)
        XCTAssertTrue(windowController.isRequestingOlderPage)

        controller.finishOlderPageLoad(
            windowController: windowController,
            refreshedAvailableBeforeCount: 7,
            pageSize: 4,
            anchorID: SegmentCommentID(value: 3)
        )

        XCTAssertFalse(windowController.isRequestingOlderPage)
        XCTAssertEqual(windowController.visibleBeforeCount, 7)
    }

    func testRequestNewerPageAndFinishLoadExpandWindow() {
        let controller = TimelineCommentAllCommentsSessionController()
        let browserController = TimelineCommentSubmenuBrowserController()
        let windowController = TimelineCommentBrowserWindowController()
        controller.openAllComments(
            anchorID: SegmentCommentID(value: 3),
            browserController: browserController,
            windowController: windowController
        )

        let expandPlan = controller.requestNewerPage(
            browserController: browserController,
            windowController: windowController,
            availableAfterCount: 6,
            pageSize: 4,
            hasMorePages: true,
            isLoadingPage: false,
            anchorID: SegmentCommentID(value: 3)
        )
        XCTAssertEqual(expandPlan, .expandedWindow)
        XCTAssertEqual(windowController.visibleAfterCount, 4)

        let loadPlan = controller.requestNewerPage(
            browserController: browserController,
            windowController: windowController,
            availableAfterCount: 4,
            pageSize: 4,
            hasMorePages: true,
            isLoadingPage: false,
            anchorID: SegmentCommentID(value: 3)
        )
        XCTAssertEqual(loadPlan, .loadNewerPage)
        XCTAssertTrue(windowController.isRequestingNewerPage)

        controller.finishNewerPageLoad(
            windowController: windowController,
            refreshedAvailableAfterCount: 6,
            pageSize: 4,
            anchorID: SegmentCommentID(value: 3)
        )

        XCTAssertFalse(windowController.isRequestingNewerPage)
        XCTAssertEqual(windowController.visibleAfterCount, 6)
    }

    private func ids(_ values: [Int64]) -> [SegmentCommentID] {
        values.map(SegmentCommentID.init(value:))
    }
}
