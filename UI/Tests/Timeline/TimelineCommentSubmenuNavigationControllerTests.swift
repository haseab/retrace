import Shared
import XCTest
@testable import Retrace

@MainActor
final class TimelineCommentSubmenuNavigationControllerTests: XCTestCase {
    func testOpenLinkedCommentNavigatesAndClosesOnSuccess() async {
        let controller = TimelineCommentSubmenuNavigationController()
        let comment = makeComment(id: 21)
        let expectedSegmentID = SegmentID(value: 99)
        let navigateExpectation = expectation(description: "navigate called")
        var receivedRequest: TimelineCommentNavigationRequest?
        var didClose = false

        controller.openLinkedComment(
            comment,
            preferredSegmentID: expectedSegmentID
        ) { request in
            receivedRequest = request
            navigateExpectation.fulfill()
            return true
        } onClose: {
            didClose = true
        }

        await fulfillment(of: [navigateExpectation], timeout: 0.2)
        await Task.yield()

        XCTAssertEqual(
            receivedRequest,
            TimelineCommentNavigationRequest(
                comment: comment,
                preferredSegmentID: expectedSegmentID
            )
        )
        XCTAssertFalse(controller.isNavigatingLinkedCommentFrame)
        XCTAssertTrue(didClose)
    }

    func testOpenLinkedCommentIgnoresDuplicateRequestsWhileInFlight() async {
        let controller = TimelineCommentSubmenuNavigationController()
        let comment = makeComment(id: 22)
        let startedExpectation = expectation(description: "first navigation started")
        let finishedExpectation = expectation(description: "first navigation finished")
        var continuation: CheckedContinuation<Bool, Never>?
        var callCount = 0

        controller.openLinkedComment(comment) { _ in
            callCount += 1
            startedExpectation.fulfill()
            let result = await withCheckedContinuation { continuation = $0 }
            finishedExpectation.fulfill()
            return result
        } onClose: {}

        await fulfillment(of: [startedExpectation], timeout: 0.2)
        XCTAssertTrue(controller.isNavigatingLinkedCommentFrame)

        controller.openLinkedComment(makeComment(id: 23)) { _ in
            callCount += 1
            return true
        } onClose: {}

        XCTAssertEqual(callCount, 1)

        continuation?.resume(returning: false)
        await fulfillment(of: [finishedExpectation], timeout: 0.2)

        XCTAssertFalse(controller.isNavigatingLinkedCommentFrame)
        XCTAssertEqual(callCount, 1)
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
