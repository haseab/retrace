import AppKit
import Shared
import XCTest
@testable import Retrace

@MainActor
final class TimelineCommentSubmenuRoutingSupportTests: XCTestCase {
    func testLaunchAnchorCommentReturnsMiddleCommentAfterSorting() {
        let comments = [
            makeComment(id: 30, createdAt: 30),
            makeComment(id: 10, createdAt: 10),
            makeComment(id: 20, createdAt: 20)
        ]

        let anchorComment = TimelineCommentSubmenuRoutingSupport.launchAnchorComment(
            from: comments
        )

        XCTAssertEqual(anchorComment?.id, SegmentCommentID(value: 20))
    }

    func testMakeActionsOpenAllCommentsDismissesPendingDeletionAndUsesLaunchAnchor() {
        let browserController = TimelineCommentSubmenuBrowserController()
        let comments = [
            makeComment(id: 30, createdAt: 30),
            makeComment(id: 10, createdAt: 10),
            makeComment(id: 20, createdAt: 20)
        ]
        var dismissedPendingDeletion = false
        var openedAnchorID: SegmentCommentID?

        let actions = TimelineCommentSubmenuRoutingSupport.makeActions(
            browserController: browserController,
            state: makeKeyboardState(),
            selectedBlockComments: comments,
            environment: .init(
                dismissPendingDeletion: { dismissedPendingDeletion = true },
                openAllComments: { openedAnchorID = $0?.id },
                exitAllComments: {},
                openLinkedComment: { _, _ in },
                dismissTagSubmenu: {},
                dismissLinkPopover: {},
                closeSubmenu: {},
                setSearchFieldFocused: { _ in }
            )
        )

        actions.openAllComments()

        XCTAssertTrue(dismissedPendingDeletion)
        XCTAssertEqual(openedAnchorID, SegmentCommentID(value: 20))
    }

    func testMakeActionsHandleKeyEventUsesLaunchAnchorForOptionA() {
        let browserController = TimelineCommentSubmenuBrowserController()
        let comments = [
            makeComment(id: 30, createdAt: 30),
            makeComment(id: 10, createdAt: 10),
            makeComment(id: 20, createdAt: 20)
        ]
        var openedAnchorID: SegmentCommentID?

        let actions = TimelineCommentSubmenuRoutingSupport.makeActions(
            browserController: browserController,
            state: makeKeyboardState(),
            selectedBlockComments: comments,
            environment: .init(
                dismissPendingDeletion: {},
                openAllComments: { openedAnchorID = $0?.id },
                exitAllComments: {},
                openLinkedComment: { _, _ in },
                dismissTagSubmenu: {},
                dismissLinkPopover: {},
                closeSubmenu: {},
                setSearchFieldFocused: { _ in }
            )
        )

        let handled = actions.handleKeyEvent(0, "a", [.option])

        XCTAssertTrue(handled)
        XCTAssertEqual(openedAnchorID, SegmentCommentID(value: 20))
    }

    private func makeKeyboardState() -> TimelineCommentSubmenuKeyboardState {
        TimelineCommentSubmenuKeyboardState(
            isBrowsingAllComments: false,
            hasPendingDeleteConfirmation: false,
            isTagSubmenuVisible: false,
            isLinkPopoverPresented: false,
            isSearchFieldFocused: false,
            hasActiveCommentSearch: false,
            searchResults: [],
            visibleRows: [],
            preferredAnchorID: nil
        )
    }

    private func makeComment(id: Int64, createdAt: TimeInterval) -> SegmentComment {
        SegmentComment(
            id: SegmentCommentID(value: id),
            body: "Comment \(id)",
            author: "Tester",
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}
