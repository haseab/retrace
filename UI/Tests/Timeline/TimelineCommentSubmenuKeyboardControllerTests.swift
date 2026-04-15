import AppKit
import Shared
import XCTest
@testable import Retrace

@MainActor
final class TimelineCommentSubmenuKeyboardControllerTests: XCTestCase {
    func testHandleKeyEventDispatchesResolvedAction() {
        var didDismissTagSubmenu = false

        let handled = TimelineCommentSubmenuKeyboardController.handleKeyEvent(
            keyCode: 53,
            charactersIgnoringModifiers: nil,
            modifiers: [],
            state: TimelineCommentSubmenuKeyboardState(
                isBrowsingAllComments: false,
                hasPendingDeleteConfirmation: false,
                isTagSubmenuVisible: true,
                isLinkPopoverPresented: false,
                isSearchFieldFocused: false,
                hasActiveCommentSearch: false,
                searchResults: [],
                visibleRows: [],
                preferredAnchorID: nil
            ),
            environment: TimelineCommentSubmenuActionExecutionEnvironment(
                dismissTagSubmenu: { didDismissTagSubmenu = true },
                dismissLinkPopover: {},
                exitAllComments: {},
                closeSubmenu: {},
                openAllComments: {},
                focusSearchField: {},
                seedHighlightedSelection: {},
                moveHighlightedSelection: { _ in },
                openHighlightedSelection: { false }
            )
        )

        XCTAssertTrue(handled)
        XCTAssertTrue(didDismissTagSubmenu)
    }

    func testOpenHighlightedSelectionUsesSearchResultsWhenSearchIsActive() {
        let browserController = TimelineCommentSubmenuBrowserController()
        let rows = [
            makeRow(id: 20, segmentID: 200),
            makeRow(id: 21, segmentID: 201)
        ]
        browserController.enterAllComments()
        browserController.setHighlightedCommentID(SegmentCommentID(value: 21))
        var openedCommentID: SegmentCommentID?
        var openedSegmentID: SegmentID?

        let didOpen = TimelineCommentSubmenuKeyboardController.openHighlightedSelection(
            browserController: browserController,
            state: TimelineCommentSubmenuKeyboardState(
                isBrowsingAllComments: true,
                hasPendingDeleteConfirmation: false,
                isTagSubmenuVisible: false,
                isLinkPopoverPresented: false,
                isSearchFieldFocused: true,
                hasActiveCommentSearch: true,
                searchResults: rows,
                visibleRows: [],
                preferredAnchorID: nil
            )
        ) { comment, preferredSegmentID in
            openedCommentID = comment.id
            openedSegmentID = preferredSegmentID
        }

        XCTAssertTrue(didOpen)
        XCTAssertEqual(openedCommentID, SegmentCommentID(value: 21))
        XCTAssertEqual(openedSegmentID, SegmentID(value: 201))
    }

    func testSeedAndMoveHighlightedSelectionUseVisibleRowsWhenSearchInactive() {
        let browserController = TimelineCommentSubmenuBrowserController()
        let visibleRows = [
            makeRow(id: 31, segmentID: 301),
            makeRow(id: 32, segmentID: 302),
            makeRow(id: 33, segmentID: 303)
        ]
        browserController.enterAllComments()
        let state = TimelineCommentSubmenuKeyboardState(
            isBrowsingAllComments: true,
            hasPendingDeleteConfirmation: false,
            isTagSubmenuVisible: false,
            isLinkPopoverPresented: false,
            isSearchFieldFocused: false,
            hasActiveCommentSearch: false,
            searchResults: [],
            visibleRows: visibleRows,
            preferredAnchorID: SegmentCommentID(value: 32)
        )

        TimelineCommentSubmenuKeyboardController.seedHighlightedSelectionIfNeeded(
            browserController: browserController,
            state: state
        )
        XCTAssertEqual(browserController.highlightedCommentID, SegmentCommentID(value: 32))

        TimelineCommentSubmenuKeyboardController.moveHighlightedSelection(
            browserController: browserController,
            by: 1,
            state: state
        )
        XCTAssertEqual(browserController.highlightedCommentID, SegmentCommentID(value: 33))
    }

    func testMakeActionEnvironmentBuildsFocusAndOpenHandlers() {
        let browserController = TimelineCommentSubmenuBrowserController()
        let rows = [
            makeRow(id: 41, segmentID: 401),
            makeRow(id: 42, segmentID: 402)
        ]
        browserController.enterAllComments()
        browserController.setHighlightedCommentID(SegmentCommentID(value: 42))
        let state = TimelineCommentSubmenuKeyboardState(
            isBrowsingAllComments: true,
            hasPendingDeleteConfirmation: false,
            isTagSubmenuVisible: false,
            isLinkPopoverPresented: false,
            isSearchFieldFocused: false,
            hasActiveCommentSearch: true,
            searchResults: rows,
            visibleRows: [],
            preferredAnchorID: nil
        )
        var focusedValue = false
        var openedCommentID: SegmentCommentID?

        let environment = TimelineCommentSubmenuKeyboardController.makeActionEnvironment(
            browserController: browserController,
            state: state,
            dismissTagSubmenu: {},
            dismissLinkPopover: {},
            exitAllComments: {},
            closeSubmenu: {},
            openAllComments: {},
            setSearchFieldFocused: { focusedValue = $0 }
        ) { comment, _ in
            openedCommentID = comment.id
        }

        environment.focusSearchField()
        XCTAssertTrue(focusedValue)
        XCTAssertTrue(environment.openHighlightedSelection())
        XCTAssertEqual(openedCommentID, SegmentCommentID(value: 42))
    }

    private func makeRow(id: Int64, segmentID: Int64) -> CommentTimelineRow {
        CommentTimelineRow(
            comment: SegmentComment(
                id: SegmentCommentID(value: id),
                body: "Comment \(id)",
                author: "Tester",
                createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(id))
            ),
            context: CommentTimelineSegmentContext(
                segmentID: SegmentID(value: segmentID),
                appBundleID: nil,
                appName: nil,
                browserURL: nil,
                referenceTimestamp: Date(timeIntervalSince1970: TimeInterval(id))
            ),
            primaryTagName: nil
        )
    }
}
