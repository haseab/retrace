import Foundation
import Shared
import XCTest
@testable import Retrace

final class TimelineCommentBrowserWindowSupportTests: XCTestCase {
    func testResolveAnchorIndexPrefersExplicitAnchorThenFallbackThenMiddle() {
        let rows = makeRows(ids: [1, 2, 3, 4, 5])

        XCTAssertEqual(
            TimelineCommentBrowserWindowSupport.resolveAnchorIndex(
                rows: rows,
                explicitAnchorID: SegmentCommentID(value: 4),
                fallbackAnchorID: SegmentCommentID(value: 2)
            ),
            3
        )

        XCTAssertEqual(
            TimelineCommentBrowserWindowSupport.resolveAnchorIndex(
                rows: rows,
                explicitAnchorID: SegmentCommentID(value: 99),
                fallbackAnchorID: SegmentCommentID(value: 2)
            ),
            1
        )

        XCTAssertEqual(
            TimelineCommentBrowserWindowSupport.resolveAnchorIndex(
                rows: rows,
                explicitAnchorID: nil,
                fallbackAnchorID: nil
            ),
            2
        )
    }

    func testVisibleRowsClampsToAvailableBoundsAroundAnchor() {
        let rows = makeRows(ids: [1, 2, 3, 4, 5])

        let visibleRows = TimelineCommentBrowserWindowSupport.visibleRows(
            rows: rows,
            anchorIndex: 1,
            visibleBeforeCount: 5,
            visibleAfterCount: 2
        )

        XCTAssertEqual(visibleRows.map(\.id.value), [1, 2, 3, 4])
    }

    func testSyncedVisibleCountsIncludesSelectedBlockRangeAroundAnchor() {
        let rows = makeRows(ids: [1, 2, 3, 4, 5, 6, 7])

        let counts = TimelineCommentBrowserWindowSupport.syncedVisibleCounts(
            forceReset: true,
            anchorIndex: 3,
            totalRowCount: rows.count,
            currentBeforeCount: 0,
            currentAfterCount: 0,
            selectedCommentIDs: [SegmentCommentID(value: 2), SegmentCommentID(value: 6)],
            rowIDs: rows.map(\.id),
            pageSize: 5
        )

        XCTAssertEqual(counts, TimelineCommentBrowserVisibleCounts(before: 2, after: 2))
    }

    func testSyncedVisibleCountsClampsExistingCountsWhenNotResetting() {
        let rows = makeRows(ids: [1, 2, 3, 4, 5])

        let counts = TimelineCommentBrowserWindowSupport.syncedVisibleCounts(
            forceReset: false,
            anchorIndex: 2,
            totalRowCount: rows.count,
            currentBeforeCount: 9,
            currentAfterCount: 9,
            selectedCommentIDs: [],
            rowIDs: rows.map(\.id),
            pageSize: 5
        )

        XCTAssertEqual(counts, TimelineCommentBrowserVisibleCounts(before: 2, after: 2))
    }

    func testMakeAllCommentsAndThreadStateResetTransientBrowserFields() {
        XCTAssertEqual(
            TimelineCommentBrowserWindowSupport.makeAllCommentsState(anchorID: SegmentCommentID(value: 9)),
            TimelineCommentBrowserWindowState(
                anchorID: SegmentCommentID(value: 9),
                visibleBeforeCount: 0,
                visibleAfterCount: 0,
                hasPerformedInitialScroll: false,
                isRequestingOlderPage: false,
                isRequestingNewerPage: false,
                pendingAnchorPinnedCommentID: nil
            )
        )

        XCTAssertEqual(
            TimelineCommentBrowserWindowSupport.makeThreadState(),
            TimelineCommentBrowserWindowState(
                anchorID: nil,
                visibleBeforeCount: 0,
                visibleAfterCount: 0,
                hasPerformedInitialScroll: false,
                isRequestingOlderPage: false,
                isRequestingNewerPage: false,
                pendingAnchorPinnedCommentID: nil
            )
        )
    }

    func testExpandedVisibleCountsAdvanceByPageAndClampToAvailableBounds() {
        XCTAssertEqual(
            TimelineCommentBrowserWindowSupport.expandedVisibleBeforeCount(
                currentBeforeCount: 3,
                availableBeforeCount: 9,
                pageSize: 4
            ),
            7
        )

        XCTAssertEqual(
            TimelineCommentBrowserWindowSupport.expandedVisibleAfterCount(
                currentAfterCount: 3,
                availableAfterCount: 5,
                pageSize: 4
            ),
            5
        )
    }

    func testPinnedAnchorIDPrefersExplicitAnchorBeforeFallback() {
        XCTAssertEqual(
            TimelineCommentBrowserWindowSupport.pinnedAnchorID(
                explicitAnchorID: SegmentCommentID(value: 8),
                fallbackAnchorID: SegmentCommentID(value: 3)
            ),
            SegmentCommentID(value: 8)
        )

        XCTAssertEqual(
            TimelineCommentBrowserWindowSupport.pinnedAnchorID(
                explicitAnchorID: nil,
                fallbackAnchorID: SegmentCommentID(value: 3)
            ),
            SegmentCommentID(value: 3)
        )
    }

    private func makeRows(ids: [Int64]) -> [CommentTimelineRow] {
        ids.map { value in
            let commentID = SegmentCommentID(value: value)
            return CommentTimelineRow(
                comment: SegmentComment(
                    id: commentID,
                    body: "Comment \(value)",
                    author: "Tester",
                    createdAt: Date(timeIntervalSince1970: TimeInterval(value)),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(value))
                ),
                context: nil,
                primaryTagName: nil
            )
        }
    }
}
