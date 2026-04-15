import Shared
import XCTest
@testable import Retrace

final class TimelineCommentAllCommentsDerivedStateSupportTests: XCTestCase {
    func testMakePrefersExplicitAnchorAndBuildsVisibleWindow() {
        let rows = makeRows([1, 2, 3, 4, 5])

        let state = TimelineCommentAllCommentsDerivedStateSupport.make(
            rows: rows,
            explicitAnchorID: SegmentCommentID(value: 4),
            fallbackAnchorID: SegmentCommentID(value: 2),
            visibleBeforeCount: 1,
            visibleAfterCount: 0
        )

        XCTAssertEqual(state.anchorID, SegmentCommentID(value: 4))
        XCTAssertEqual(state.anchorIndex, 3)
        XCTAssertEqual(state.availableBeforeCount, 3)
        XCTAssertEqual(state.availableAfterCount, 1)
        XCTAssertEqual(state.visibleRows.map(\.id.value), [3, 4])
    }

    func testMakeFallsBackToPinnedAnchorWhenExplicitAnchorMissing() {
        let rows = makeRows([10, 11, 12, 13])

        let state = TimelineCommentAllCommentsDerivedStateSupport.make(
            rows: rows,
            explicitAnchorID: nil,
            fallbackAnchorID: SegmentCommentID(value: 11),
            visibleBeforeCount: 0,
            visibleAfterCount: 2
        )

        XCTAssertEqual(state.anchorID, SegmentCommentID(value: 11))
        XCTAssertEqual(state.anchorIndex, 1)
        XCTAssertEqual(state.availableBeforeCount, 1)
        XCTAssertEqual(state.availableAfterCount, 2)
        XCTAssertEqual(state.visibleRows.map(\.id.value), [11, 12, 13])
    }

    private func makeRows(_ values: [Int64]) -> [CommentTimelineRow] {
        values.map { value in
            CommentTimelineRow(
                comment: SegmentComment(
                    id: SegmentCommentID(value: value),
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
