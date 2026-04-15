import Shared
import XCTest
@testable import Retrace

@MainActor
final class TimelineCommentAllCommentsFlowControllerTests: XCTestCase {
    func testOpenAllCommentsResetsSearchFocusesOffAndLoadsTimeline() async {
        let controller = TimelineCommentAllCommentsFlowController()
        let sessionController = TimelineCommentAllCommentsSessionController()
        let browserController = TimelineCommentSubmenuBrowserController()
        let windowController = TimelineCommentBrowserWindowController()
        let anchorComment = makeComment(id: 4)
        let loadExpectation = expectation(description: "load timeline")
        var didResetSearch = false
        var focusedValues: [Bool] = []
        var loadedAnchor: SegmentComment?

        controller.openAllComments(
            anchoredAt: anchorComment,
            environment: makeEnvironment(
                sessionController: sessionController,
                browserController: browserController,
                windowController: windowController,
                setSearchFieldFocused: { focusedValues.append($0) },
                resetSearch: { didResetSearch = true },
                loadTimeline: { comment in
                    loadedAnchor = comment
                    loadExpectation.fulfill()
                }
            )
        )

        XCTAssertTrue(didResetSearch)
        XCTAssertEqual(focusedValues, [false])
        XCTAssertEqual(browserController.mode, .allComments)
        XCTAssertEqual(windowController.anchorID, anchorComment.id)

        await fulfillment(of: [loadExpectation], timeout: 0.2)
        XCTAssertEqual(loadedAnchor?.id, anchorComment.id)
    }

    func testExitAllCommentsResetsTimelineAndWindowState() {
        let controller = TimelineCommentAllCommentsFlowController()
        let sessionController = TimelineCommentAllCommentsSessionController()
        let browserController = TimelineCommentSubmenuBrowserController()
        let windowController = TimelineCommentBrowserWindowController()
        var didResetTimeline = false
        var focusedValues: [Bool] = []

        sessionController.openAllComments(
            anchorID: SegmentCommentID(value: 12),
            browserController: browserController,
            windowController: windowController
        )

        controller.exitAllComments(
            environment: makeEnvironment(
                sessionController: sessionController,
                browserController: browserController,
                windowController: windowController,
                setSearchFieldFocused: { focusedValues.append($0) },
                resetTimeline: { didResetTimeline = true }
            )
        )

        XCTAssertEqual(browserController.mode, .thread)
        XCTAssertNil(windowController.anchorID)
        XCTAssertTrue(didResetTimeline)
        XCTAssertEqual(focusedValues, [false])
    }

    func testHandleVisibleRowAppearRequestsOlderPageAtLeadingEdge() async {
        let controller = TimelineCommentAllCommentsFlowController()
        let sessionController = TimelineCommentAllCommentsSessionController()
        let browserController = TimelineCommentSubmenuBrowserController()
        let windowController = TimelineCommentBrowserWindowController()
        let loadExpectation = expectation(description: "load older page")
        let rowIDs = ids([1, 2, 3])
        let rows = rowIDs.map(makeRow(id:))

        sessionController.openAllComments(
            anchorID: SegmentCommentID(value: 2),
            browserController: browserController,
            windowController: windowController
        )
        windowController.visibleBeforeCount = 0

        controller.handleVisibleRowAppear(
            rows[0],
            environment: makeEnvironment(
                sessionController: sessionController,
                browserController: browserController,
                windowController: windowController,
                rowIDs: rowIDs,
                visibleRowIDs: rowIDs,
                hasMoreOlderPages: { true },
                loadOlderPage: {
                    loadExpectation.fulfill()
                }
            )
        )

        await fulfillment(of: [loadExpectation], timeout: 0.2)
        XCTAssertFalse(windowController.isRequestingOlderPage)
    }

    func testHandleVisibleRowAppearRequestsNewerPageAtTrailingEdge() async {
        let controller = TimelineCommentAllCommentsFlowController()
        let sessionController = TimelineCommentAllCommentsSessionController()
        let browserController = TimelineCommentSubmenuBrowserController()
        let windowController = TimelineCommentBrowserWindowController()
        let loadExpectation = expectation(description: "load newer page")
        let rowIDs = ids([1, 2, 3])
        let rows = rowIDs.map(makeRow(id:))

        sessionController.openAllComments(
            anchorID: SegmentCommentID(value: 2),
            browserController: browserController,
            windowController: windowController
        )
        windowController.visibleAfterCount = 0

        controller.handleVisibleRowAppear(
            rows[2],
            environment: makeEnvironment(
                sessionController: sessionController,
                browserController: browserController,
                windowController: windowController,
                rowIDs: rowIDs,
                visibleRowIDs: rowIDs,
                hasMoreNewerPages: { true },
                loadNewerPage: {
                    loadExpectation.fulfill()
                }
            )
        )

        await fulfillment(of: [loadExpectation], timeout: 0.2)
        XCTAssertFalse(windowController.isRequestingNewerPage)
    }

    private func makeEnvironment(
        sessionController: TimelineCommentAllCommentsSessionController? = nil,
        browserController: TimelineCommentSubmenuBrowserController? = nil,
        windowController: TimelineCommentBrowserWindowController? = nil,
        rowIDs: [SegmentCommentID] = [],
        visibleRowIDs: [SegmentCommentID] = [],
        availableBeforeCount: @escaping () -> Int = { 0 },
        availableAfterCount: @escaping () -> Int = { 0 },
        hasMoreOlderPages: @escaping () -> Bool = { false },
        hasMoreNewerPages: @escaping () -> Bool = { false },
        setSearchFieldFocused: @escaping (Bool) -> Void = { _ in },
        resetSearch: @escaping () -> Void = {},
        resetTimeline: @escaping () -> Void = {},
        loadTimeline: @escaping (SegmentComment?) async -> Void = { _ in },
        loadOlderPage: @escaping () async -> Void = {},
        loadNewerPage: @escaping () async -> Void = {}
    ) -> TimelineCommentAllCommentsFlowEnvironment {
        let sessionController = sessionController ?? TimelineCommentAllCommentsSessionController()
        let browserController = browserController ?? TimelineCommentSubmenuBrowserController()
        let windowController = windowController ?? TimelineCommentBrowserWindowController()

        return TimelineCommentAllCommentsFlowEnvironment(
            sessionController: sessionController,
            browserController: browserController,
            windowController: windowController,
            pageSize: 10,
            currentAnchorID: { windowController.anchorID },
            anchorIndex: { rowIDs.firstIndex(of: windowController.anchorID ?? SegmentCommentID(value: -1)) },
            totalRowCount: { rowIDs.count },
            selectedCommentIDs: { Set<SegmentCommentID>() },
            rowIDs: { rowIDs },
            visibleRowIDs: { visibleRowIDs },
            availableBeforeCount: availableBeforeCount,
            availableAfterCount: availableAfterCount,
            hasMoreOlderPages: hasMoreOlderPages,
            hasMoreNewerPages: hasMoreNewerPages,
            isLoadingTimeline: { false },
            isLoadingOlderPage: { false },
            isLoadingNewerPage: { false },
            setSearchFieldFocused: setSearchFieldFocused,
            resetSearch: resetSearch,
            resetTimeline: resetTimeline,
            loadTimeline: loadTimeline,
            loadOlderPage: loadOlderPage,
            loadNewerPage: loadNewerPage,
            performScrollRequest: { _ in }
        )
    }

    private func makeComment(id: Int64) -> SegmentComment {
        SegmentComment(
            id: SegmentCommentID(value: id),
            body: "Comment \(id)",
            author: "Tester",
            createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(id))
        )
    }

    private func makeRow(id: SegmentCommentID) -> CommentTimelineRow {
        CommentTimelineRow(
            comment: makeComment(id: id.value),
            context: nil,
            primaryTagName: nil
        )
    }

    private func ids(_ values: [Int64]) -> [SegmentCommentID] {
        values.map(SegmentCommentID.init(value:))
    }
}
