import Shared
import XCTest
@testable import Retrace

@MainActor
final class TimelineCommentSubmenuBrowserControllerTests: XCTestCase {
    func testResetForAppearReturnsToThreadAndClearsHighlight() {
        let controller = TimelineCommentSubmenuBrowserController()
        controller.enterAllComments()
        controller.setHighlightedCommentID(SegmentCommentID(value: 8))

        controller.resetForAppear()

        XCTAssertEqual(controller.mode, .thread)
        XCTAssertNil(controller.highlightedCommentID)
        XCTAssertFalse(controller.isBrowsingAllComments)
    }

    func testEnterAndExitAllCommentsUpdateModeAndHighlight() {
        let controller = TimelineCommentSubmenuBrowserController()
        controller.setHighlightedCommentID(SegmentCommentID(value: 4))

        controller.enterAllComments()

        XCTAssertEqual(controller.mode, .allComments)
        XCTAssertNil(controller.highlightedCommentID)
        XCTAssertTrue(controller.isBrowsingAllComments)

        controller.setHighlightedCommentID(SegmentCommentID(value: 5))
        controller.exitAllComments()

        XCTAssertEqual(controller.mode, .thread)
        XCTAssertNil(controller.highlightedCommentID)
        XCTAssertFalse(controller.isBrowsingAllComments)
    }

    func testSyncHighlightedSelectionUsesKeyboardSupportRules() {
        let controller = TimelineCommentSubmenuBrowserController()
        controller.enterAllComments()

        controller.syncHighlightedSelection(
            resultIDs: ids([2, 4, 6]),
            preferredAnchorID: SegmentCommentID(value: 4)
        )

        XCTAssertEqual(controller.highlightedCommentID, SegmentCommentID(value: 4))
    }

    func testMoveAndSeedHighlightedSelectionFollowKeyboardSupport() {
        let controller = TimelineCommentSubmenuBrowserController()
        controller.enterAllComments()

        controller.seedHighlightedSelectionIfNeeded(
            resultIDs: ids([1, 2, 3, 4]),
            preferredAnchorID: SegmentCommentID(value: 3)
        )
        XCTAssertEqual(controller.highlightedCommentID, SegmentCommentID(value: 3))

        controller.moveHighlightedSelection(
            by: -1,
            resultIDs: ids([1, 2, 3, 4]),
            preferredAnchorID: SegmentCommentID(value: 3)
        )
        XCTAssertEqual(controller.highlightedCommentID, SegmentCommentID(value: 2))
    }

    func testResolvedOpenTargetUpdatesHighlightAndReturnsTarget() {
        let controller = TimelineCommentSubmenuBrowserController()
        controller.enterAllComments()
        controller.setHighlightedCommentID(SegmentCommentID(value: 7))

        let openTarget = controller.resolvedOpenTarget(resultIDs: ids([5, 6, 7]))

        XCTAssertEqual(
            openTarget,
            TimelineCommentBrowserOpenTarget(
                targetID: SegmentCommentID(value: 7),
                resolvedHighlightedID: SegmentCommentID(value: 7)
            )
        )
        XCTAssertEqual(controller.highlightedCommentID, SegmentCommentID(value: 7))
    }

    private func ids(_ values: [Int64]) -> [SegmentCommentID] {
        values.map(SegmentCommentID.init(value:))
    }
}
