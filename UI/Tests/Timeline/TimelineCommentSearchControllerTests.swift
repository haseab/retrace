import XCTest
import Shared
@testable import Retrace

final class TimelineCommentSearchControllerTests: XCTestCase {
    func testUpdateQueryTrimsRequestAndResetsSearchState() {
        let controller = TimelineCommentSearchController()
        controller.applyFailure(query: "stale", append: false, message: "Old error")

        let request = controller.updateQuery("  release notes  ")

        XCTAssertEqual(
            request,
            TimelineCommentSearchRequest(query: "release notes", offset: 0, append: false)
        )
        XCTAssertEqual(controller.state.text, "  release notes  ")
        XCTAssertTrue(controller.state.results.isEmpty)
        XCTAssertTrue(controller.state.isSearching)
        XCTAssertFalse(controller.state.hasMoreResults)
        XCTAssertNil(controller.state.error)
    }

    func testWhitespaceQueryClearsResultsButPreservesRawText() {
        let controller = TimelineCommentSearchController()
        _ = controller.updateQuery("comment")
        XCTAssertTrue(
            controller.applyResults(
                query: "comment",
                offset: 0,
                append: false,
                results: [makeRow(id: 1)],
                pageSize: 10
            )
        )

        let request = controller.updateQuery("   ")

        XCTAssertNil(request)
        XCTAssertEqual(controller.state.text, "   ")
        XCTAssertTrue(controller.state.results.isEmpty)
        XCTAssertFalse(controller.state.hasMoreResults)
        XCTAssertFalse(controller.state.isSearching)
        XCTAssertNil(controller.state.error)
    }

    func testLoadMoreRequestUsesTailOffsetAndAppendsResults() {
        let controller = TimelineCommentSearchController()
        _ = controller.updateQuery("comment")
        XCTAssertTrue(
            controller.applyResults(
                query: "comment",
                offset: 0,
                append: false,
                results: [makeRow(id: 1), makeRow(id: 2)],
                pageSize: 2
            )
        )

        let request = controller.loadMoreResultsIfNeeded(currentCommentID: SegmentCommentID(value: 2))

        XCTAssertEqual(
            request,
            TimelineCommentSearchRequest(query: "comment", offset: 2, append: true)
        )

        XCTAssertTrue(
            controller.applyResults(
                query: "comment",
                offset: 2,
                append: true,
                results: [makeRow(id: 3)],
                pageSize: 2
            )
        )

        XCTAssertEqual(controller.state.results.map(\.id.value), [1, 2, 3])
        XCTAssertFalse(controller.state.hasMoreResults)
        XCTAssertFalse(controller.state.isSearching)
    }

    func testStaleResultApplicationIsIgnoredAfterNewerQueryStarts() {
        let controller = TimelineCommentSearchController()
        _ = controller.updateQuery("first")
        _ = controller.updateQuery("second")

        let didApply = controller.applyResults(
            query: "first",
            offset: 0,
            append: false,
            results: [makeRow(id: 1)],
            pageSize: 10
        )

        XCTAssertFalse(didApply)
        XCTAssertTrue(controller.state.results.isEmpty)
        XCTAssertTrue(controller.state.isSearching)
        XCTAssertNil(controller.state.error)
    }

    private func makeRow(id: Int64) -> CommentTimelineRow {
        CommentTimelineRow(
            comment: SegmentComment(
                id: SegmentCommentID(value: id),
                body: "Comment \(id)",
                author: "Tester",
                createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(id))
            ),
            context: nil,
            primaryTagName: nil
        )
    }
}
