import Shared
import XCTest
@testable import Retrace

@MainActor
final class TimelineCommentDeletionControllerTests: XCTestCase {
    func testRequestDeleteSetsPendingComment() {
        let controller = TimelineCommentDeletionController()
        let comment = makeComment(id: 11)

        controller.requestDelete(comment)

        XCTAssertEqual(controller.pendingComment, comment)
        XCTAssertFalse(controller.isDeleting)
    }

    func testDismissClearsPendingCommentAndDeletingState() {
        let controller = TimelineCommentDeletionController()
        controller.requestDelete(makeComment(id: 12))
        controller.isDeleting = true

        controller.dismiss()

        XCTAssertNil(controller.pendingComment)
        XCTAssertFalse(controller.isDeleting)
    }

    func testConfirmDeletionClearsPendingCommentAfterSuccessfulDelete() async {
        let controller = TimelineCommentDeletionController()
        let comment = makeComment(id: 13)
        controller.requestDelete(comment)

        let deletedID = await controller.confirmDeletion { pendingComment in
            XCTAssertEqual(pendingComment, comment)
            XCTAssertTrue(controller.isDeleting)
            return true
        }

        XCTAssertEqual(deletedID, comment.id)
        XCTAssertNil(controller.pendingComment)
        XCTAssertFalse(controller.isDeleting)
    }

    func testConfirmDeletionPreservesPendingCommentAfterFailure() async {
        let controller = TimelineCommentDeletionController()
        let comment = makeComment(id: 14)
        controller.requestDelete(comment)

        let deletedID = await controller.confirmDeletion { _ in
            false
        }

        XCTAssertNil(deletedID)
        XCTAssertEqual(controller.pendingComment, comment)
        XCTAssertFalse(controller.isDeleting)
    }

    func testConfirmDeletionReturnsNilWithoutPendingComment() async {
        let controller = TimelineCommentDeletionController()

        let deletedID = await controller.confirmDeletion { _ in
            XCTFail("delete closure should not run without a pending comment")
            return true
        }

        XCTAssertNil(deletedID)
        XCTAssertFalse(controller.isDeleting)
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
}
