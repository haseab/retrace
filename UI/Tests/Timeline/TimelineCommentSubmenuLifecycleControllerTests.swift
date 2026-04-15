import AppKit
import Shared
import XCTest
@testable import Retrace

@MainActor
final class TimelineCommentSubmenuLifecycleControllerTests: XCTestCase {
    func testHandleAppearResetsStateSchedulesEditorFocusAndLoadsTags() async {
        let submenuBrowserController = TimelineCommentSubmenuBrowserController()
        let browserController = TimelineCommentBrowserWindowController()
        let targetPreviewController = TimelineCommentTargetPreviewController()
        let composerController = TimelineCommentComposerController()
        let loadTagsExpectation = expectation(description: "load tags")
        var installedMonitor = false
        var capturedHandler: ((NSEvent) -> Bool)?
        var isSearchFieldFocused = true
        var isAllCommentsBrowserActive = true

        submenuBrowserController.enterAllComments()
        browserController.prepareAllComments(anchorID: SegmentCommentID(value: 99))

        TimelineCommentSubmenuLifecycleController.handleAppear(
            installKeyboardMonitor: { handler in
                installedMonitor = true
                capturedHandler = handler
            },
            submenuBrowserController: submenuBrowserController,
            browserController: browserController,
            targetPreviewController: targetPreviewController,
            composerController: composerController,
            setSearchFieldFocused: { isSearchFieldFocused = $0 },
            setAllCommentsBrowserActive: { isAllCommentsBrowserActive = $0 },
            handleKeyEvent: { _ in false },
            scheduleDeferredAction: { $0() }
        ) {
            loadTagsExpectation.fulfill()
        }

        await fulfillment(of: [loadTagsExpectation], timeout: 0.2)
        XCTAssertTrue(installedMonitor)
        XCTAssertNotNil(capturedHandler)
        XCTAssertEqual(submenuBrowserController.mode, .thread)
        XCTAssertNil(browserController.anchorID)
        XCTAssertFalse(isSearchFieldFocused)
        XCTAssertFalse(isAllCommentsBrowserActive)
        XCTAssertTrue(composerController.isEditorFocused)
    }

    func testHandleModeChangeIntoAllCommentsSyncsAndFocusesSearch() {
        var syncCount = 0
        var isSearchFieldFocused = false
        var isAllCommentsBrowserActive = false

        TimelineCommentSubmenuLifecycleController.handleModeChange(
            mode: .allComments,
            syncHighlightedSelection: { syncCount += 1 },
            setSearchFieldFocused: { isSearchFieldFocused = $0 },
            setAllCommentsBrowserActive: { isAllCommentsBrowserActive = $0 },
            scheduleDeferredAction: { $0() }
        )

        XCTAssertEqual(syncCount, 1)
        XCTAssertTrue(isSearchFieldFocused)
        XCTAssertTrue(isAllCommentsBrowserActive)
    }

    func testHandleModeChangeBackToThreadClearsSearchFocus() {
        var syncCount = 0
        var isSearchFieldFocused = true
        var isAllCommentsBrowserActive = true

        TimelineCommentSubmenuLifecycleController.handleModeChange(
            mode: .thread,
            syncHighlightedSelection: { syncCount += 1 },
            setSearchFieldFocused: { isSearchFieldFocused = $0 },
            setAllCommentsBrowserActive: { isAllCommentsBrowserActive = $0 }
        )

        XCTAssertEqual(syncCount, 0)
        XCTAssertFalse(isSearchFieldFocused)
        XCTAssertFalse(isAllCommentsBrowserActive)
    }

    func testHandleReturnToThreadCommentsSignalOnlyExitsWhenBrowsingAllComments() {
        var exitCount = 0

        TimelineCommentSubmenuLifecycleController.handleReturnToThreadCommentsSignal(
            isBrowsingAllComments: false
        ) {
            exitCount += 1
        }
        TimelineCommentSubmenuLifecycleController.handleReturnToThreadCommentsSignal(
            isBrowsingAllComments: true
        ) {
            exitCount += 1
        }

        XCTAssertEqual(exitCount, 1)
    }

    func testHandleSearchStateChangeInvokesSyncClosure() {
        var syncCount = 0

        TimelineCommentSubmenuLifecycleController.handleSearchStateChange {
            syncCount += 1
        }

        XCTAssertEqual(syncCount, 1)
    }

    func testHandleTagSubmenuChangeDefocusesAndThenRefocusesEditor() {
        let composerController = TimelineCommentComposerController()
        composerController.isEditorFocused = true

        TimelineCommentSubmenuLifecycleController.handleTagSubmenuChange(
            isPresented: true,
            mode: .thread,
            isLinkPopoverPresented: false,
            composerController: composerController
        )
        XCTAssertFalse(composerController.isEditorFocused)

        TimelineCommentSubmenuLifecycleController.handleTagSubmenuChange(
            isPresented: false,
            mode: .thread,
            isLinkPopoverPresented: false,
            composerController: composerController,
            scheduleDeferredAction: { $0() }
        )
        XCTAssertTrue(composerController.isEditorFocused)
    }

    func testHandleCloseLinkPopoverSignalDismissesOnlyWhenPresented() {
        let composerController = TimelineCommentComposerController()

        TimelineCommentSubmenuLifecycleController.handleCloseLinkPopoverSignal(
            composerController: composerController
        )
        XCTAssertFalse(composerController.isEditorFocused)

        composerController.isLinkPopoverPresented = true
        TimelineCommentSubmenuLifecycleController.handleCloseLinkPopoverSignal(
            composerController: composerController
        )

        XCTAssertFalse(composerController.isLinkPopoverPresented)
        XCTAssertTrue(composerController.isEditorFocused)
    }

    func testHandleDisappearRemovesMonitorAndResetsFlags() {
        let targetPreviewController = TimelineCommentTargetPreviewController()
        var removedMonitor = false
        var isCommentLinkPopoverPresented = true
        var isAllCommentsBrowserActive = true
        var isSearchFieldFocused = true
        var resetTimelineCount = 0

        TimelineCommentSubmenuLifecycleController.handleDisappear(
            removeKeyboardMonitor: { removedMonitor = true },
            targetPreviewController: targetPreviewController,
            setCommentLinkPopoverPresented: { isCommentLinkPopoverPresented = $0 },
            setAllCommentsBrowserActive: { isAllCommentsBrowserActive = $0 },
            setSearchFieldFocused: { isSearchFieldFocused = $0 },
            resetTimelineState: { resetTimelineCount += 1 }
        )

        XCTAssertTrue(removedMonitor)
        XCTAssertFalse(isCommentLinkPopoverPresented)
        XCTAssertFalse(isAllCommentsBrowserActive)
        XCTAssertFalse(isSearchFieldFocused)
        XCTAssertEqual(resetTimelineCount, 1)
    }
}
