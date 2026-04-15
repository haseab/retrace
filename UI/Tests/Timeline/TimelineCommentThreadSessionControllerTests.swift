import XCTest
import Shared
@testable import Retrace

final class TimelineCommentThreadSessionControllerTests: XCTestCase {
    func testBeginCommentsLoadCoalescesMatchingRequestAndForceRefreshStartsNewVersion() {
        let controller = TimelineCommentThreadSessionController()
        let existingTask = Task<Void, Never> {}

        switch controller.beginCommentsLoad(requestSegmentIDValues: [1, 2], forceRefresh: false) {
        case let .start(version):
            XCTAssertEqual(version, 1)
        case .awaitExisting:
            XCTFail("expected initial load to start")
        }

        controller.setLoadTask(existingTask)

        switch controller.beginCommentsLoad(requestSegmentIDValues: [1, 2], forceRefresh: false) {
        case .awaitExisting:
            XCTAssertTrue(true)
        case .start:
            XCTFail("expected matching request to join in-flight task")
        }

        switch controller.beginCommentsLoad(requestSegmentIDValues: [1, 2], forceRefresh: true) {
        case let .start(version):
            XCTAssertEqual(version, 2)
        case .awaitExisting:
            XCTFail("expected force refresh to start new load")
        }
    }

    func testApplyLoadedCommentsStoresPreferredSegmentsAndRemoveSelectedCommentClearsMapping() {
        let controller = TimelineCommentThreadSessionController()
        _ = controller.beginCommentsLoad(requestSegmentIDValues: [42], forceRefresh: false)
        let comment = makeComment(id: 3)
        let segmentID = SegmentID(value: 42)

        XCTAssertTrue(
            controller.applyLoadedComments(
                [(comment: comment, preferredSegmentID: segmentID)],
                version: 1
            )
        )
        XCTAssertTrue(controller.finishCommentsLoad(version: 1))

        XCTAssertEqual(controller.state.selectedBlockComments, [comment])
        XCTAssertEqual(controller.preferredSegmentID(for: comment.id), segmentID)
        XCTAssertFalse(controller.state.isLoadingBlockComments)

        XCTAssertTrue(controller.removeSelectedBlockComment(comment.id))
        XCTAssertTrue(controller.state.selectedBlockComments.isEmpty)
        XCTAssertNil(controller.preferredSegmentID(for: comment.id))
    }

    func testAppendDraftSnippetAndResetSessionClearDraftAndLoadingState() {
        let controller = TimelineCommentThreadSessionController()
        controller.setDraftText("Existing")
        controller.appendDraftSnippet("next")
        controller.setDraftAttachments([makeDraft(fileName: "note.txt")])
        controller.setIsAddingComment(true)
        _ = controller.beginCommentsLoad(requestSegmentIDValues: [9], forceRefresh: false)

        controller.resetSession()

        XCTAssertEqual(controller.state.draftText, "")
        XCTAssertTrue(controller.state.draftAttachments.isEmpty)
        XCTAssertFalse(controller.state.isAddingComment)
        XCTAssertTrue(controller.state.selectedBlockComments.isEmpty)
        XCTAssertFalse(controller.state.isLoadingBlockComments)
        XCTAssertNil(controller.state.blockCommentsLoadError)
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

    private func makeDraft(fileName: String) -> CommentAttachmentDraft {
        CommentAttachmentDraft(
            sourceURL: URL(fileURLWithPath: "/tmp/\(fileName)"),
            fileName: fileName,
            mimeType: "text/plain",
            sizeBytes: 1
        )
    }
}
