import AppKit
import Foundation
import Shared
import XCTest
@testable import Retrace

final class TimelineCommentInteractionSupportTests: XCTestCase {
    func testPreviewLoadActionPrefersLiveScreenshotThenFrameThenClear() {
        XCTAssertEqual(
            TimelineCommentInteractionSupport.previewLoadAction(
                isInLiveMode: true,
                liveScreenshot: NSImage(size: NSSize(width: 1, height: 1)),
                targetFrameID: FrameID(value: 4)
            ),
            .showLiveScreenshot
        )

        XCTAssertEqual(
            TimelineCommentInteractionSupport.previewLoadAction(
                isInLiveMode: false,
                liveScreenshot: nil,
                targetFrameID: FrameID(value: 4)
            ),
            .loadFrame(FrameID(value: 4))
        )

        XCTAssertEqual(
            TimelineCommentInteractionSupport.previewLoadAction(
                isInLiveMode: false,
                liveScreenshot: nil,
                targetFrameID: nil
            ),
            .clear
        )
    }

    func testShouldApplyLoadedPreviewRequiresMatchingTargetAndActiveTask() {
        XCTAssertTrue(
            TimelineCommentInteractionSupport.shouldApplyLoadedPreview(
                isTaskCancelled: false,
                requestedFrameID: FrameID(value: 7),
                currentTargetFrameID: FrameID(value: 7)
            )
        )

        XCTAssertFalse(
            TimelineCommentInteractionSupport.shouldApplyLoadedPreview(
                isTaskCancelled: true,
                requestedFrameID: FrameID(value: 7),
                currentTargetFrameID: FrameID(value: 7)
            )
        )

        XCTAssertFalse(
            TimelineCommentInteractionSupport.shouldApplyLoadedPreview(
                isTaskCancelled: false,
                requestedFrameID: FrameID(value: 7),
                currentTargetFrameID: FrameID(value: 8)
            )
        )
    }

    func testNavigationRequestSuppressesDuplicateNavigationAndPreservesInputs() {
        let comment = SegmentComment(
            id: SegmentCommentID(value: 3),
            body: "Body",
            author: "Tester",
            createdAt: Date(timeIntervalSince1970: 3),
            updatedAt: Date(timeIntervalSince1970: 3)
        )

        XCTAssertNil(
            TimelineCommentInteractionSupport.navigationRequest(
                isNavigating: true,
                comment: comment,
                preferredSegmentID: SegmentID(value: 2)
            )
        )

        XCTAssertEqual(
            TimelineCommentInteractionSupport.navigationRequest(
                isNavigating: false,
                comment: comment,
                preferredSegmentID: SegmentID(value: 2)
            ),
            TimelineCommentNavigationRequest(
                comment: comment,
                preferredSegmentID: SegmentID(value: 2)
            )
        )
    }

    func testShouldCloseSubmenuTracksNavigationOutcome() {
        XCTAssertTrue(TimelineCommentInteractionSupport.shouldCloseSubmenu(afterNavigation: true))
        XCTAssertFalse(TimelineCommentInteractionSupport.shouldCloseSubmenu(afterNavigation: false))
    }
}
