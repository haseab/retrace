import XCTest
import App
@testable import Retrace

@MainActor
final class TimelineCommentOverlaySessionControllerTests: XCTestCase {
    private let invalidate = {}

    func testPrepareForTimelineContextMenuPresentationResetsOverlayFlags() {
        let store = TimelineCommentsStore()
        store.setTagSubmenuVisible(true, invalidate: invalidate)
        store.setCommentSubmenuVisible(true, invalidate: invalidate)
        store.setCommentLinkPopoverPresented(true, invalidate: invalidate)
        store.setNewTagInputVisible(true, invalidate: invalidate)
        store.setNewTagName("Draft", invalidate: invalidate)
        store.setAllCommentsBrowserActive(true, invalidate: invalidate)
        store.setHoveringAddTagButton(true, invalidate: invalidate)
        store.setHoveringAddCommentButton(true, invalidate: invalidate)
        store.requestCloseCommentLinkPopover(invalidate: invalidate)
        store.requestReturnToThreadComments(invalidate: invalidate)

        store.prepareForTimelineContextMenuPresentation(invalidate: invalidate)

        XCTAssertFalse(store.overlayState.showTagSubmenu)
        XCTAssertFalse(store.overlayState.showCommentSubmenu)
        XCTAssertFalse(store.overlayState.isCommentLinkPopoverPresented)
        XCTAssertEqual(store.overlayState.closeCommentLinkPopoverSignal, 0)
        XCTAssertFalse(store.overlayState.showNewTagInput)
        XCTAssertEqual(store.overlayState.newTagName, "")
        XCTAssertFalse(store.overlayState.isAllCommentsBrowserActive)
        XCTAssertEqual(store.overlayState.returnToThreadCommentsSignal, 0)
        XCTAssertFalse(store.overlayState.isHoveringAddTagButton)
        XCTAssertFalse(store.overlayState.isHoveringAddCommentButton)
    }

    func testPrepareForCommentAndTagSubmenuPresentationSetsExpectedVisibility() {
        let store = TimelineCommentsStore()

        store.prepareForCommentSubmenuPresentation(invalidate: invalidate)
        XCTAssertFalse(store.overlayState.showTagSubmenu)
        XCTAssertTrue(store.overlayState.showCommentSubmenu)
        XCTAssertFalse(store.overlayState.isHoveringAddTagButton)
        XCTAssertFalse(store.overlayState.isHoveringAddCommentButton)

        store.prepareForTagSubmenuPresentation(invalidate: invalidate)
        XCTAssertTrue(store.overlayState.showTagSubmenu)
        XCTAssertFalse(store.overlayState.showCommentSubmenu)
        XCTAssertFalse(store.overlayState.showNewTagInput)
        XCTAssertEqual(store.overlayState.newTagName, "")
        XCTAssertTrue(store.overlayState.isHoveringAddTagButton)
        XCTAssertFalse(store.overlayState.isHoveringAddCommentButton)
    }

    func testDismissCommentSubmenuForFadeOutAndSignalRequestsMutateState() {
        let store = TimelineCommentsStore()
        store.presentTagSubmenuInsideComment(invalidate: invalidate)
        store.setCommentLinkPopoverPresented(true, invalidate: invalidate)

        store.beginCommentSubmenuDismissal(invalidate: invalidate)
        store.requestCloseCommentLinkPopover(invalidate: invalidate)
        store.requestReturnToThreadComments(invalidate: invalidate)

        XCTAssertFalse(store.overlayState.showCommentSubmenu)
        XCTAssertFalse(store.overlayState.showTagSubmenu)
        XCTAssertFalse(store.overlayState.isCommentLinkPopoverPresented)
        XCTAssertEqual(store.overlayState.closeCommentLinkPopoverSignal, 1)
        XCTAssertEqual(store.overlayState.returnToThreadCommentsSignal, 1)
    }

    func testContextMenuSubmenuHelpersPreserveOrClearDraftStateAsExpected() {
        let store = TimelineCommentsStore()
        store.setTagSubmenuVisible(true, invalidate: invalidate)
        store.setNewTagInputVisible(true, invalidate: invalidate)
        store.setNewTagName("Draft", invalidate: invalidate)
        store.setHoveringAddTagButton(true, invalidate: invalidate)

        store.closeTagSubmenuPreservingDraft(invalidate: invalidate)
        XCTAssertFalse(store.overlayState.showTagSubmenu)
        XCTAssertTrue(store.overlayState.showNewTagInput)
        XCTAssertEqual(store.overlayState.newTagName, "Draft")
        XCTAssertTrue(store.overlayState.isHoveringAddTagButton)

        store.showTagSubmenuFromContextMenu(invalidate: invalidate)
        XCTAssertTrue(store.overlayState.showTagSubmenu)
        XCTAssertFalse(store.overlayState.showCommentSubmenu)

        store.presentCommentSubmenuFromContextMenu(invalidate: invalidate)
        XCTAssertFalse(store.overlayState.showTagSubmenu)
        XCTAssertTrue(store.overlayState.showCommentSubmenu)

        store.dismissContextMenuSubmenus(invalidate: invalidate)
        XCTAssertFalse(store.overlayState.showTagSubmenu)
        XCTAssertFalse(store.overlayState.showCommentSubmenu)
        XCTAssertFalse(store.overlayState.showNewTagInput)
        XCTAssertEqual(store.overlayState.newTagName, "")
    }
}

@MainActor
final class TimelineCommentOverlaySessionViewModelBridgeTests: XCTestCase {
    func testDismissTagEditingClearsDraftAndHoverState() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setTagSubmenuVisible(true)
        viewModel.setNewTagInputVisible(true)
        viewModel.setNewTagDraftName("Draft")
        viewModel.setHoveringAddTagButton(true)

        viewModel.dismissTagEditing()

        XCTAssertFalse(viewModel.showTagSubmenu)
        XCTAssertFalse(viewModel.showNewTagInput)
        XCTAssertEqual(viewModel.newTagName, "")
        XCTAssertFalse(viewModel.isHoveringAddTagButton)
    }

    func testCloseTagSubmenuPreservingDraftLeavesDraftVisibleForNextOpen() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        viewModel.setTagSubmenuVisible(true)
        viewModel.setNewTagInputVisible(true)
        viewModel.setNewTagDraftName("Draft")
        viewModel.setHoveringAddTagButton(true)

        viewModel.closeTagSubmenuPreservingDraft()

        XCTAssertFalse(viewModel.showTagSubmenu)
        XCTAssertTrue(viewModel.showNewTagInput)
        XCTAssertEqual(viewModel.newTagName, "Draft")
        XCTAssertTrue(viewModel.isHoveringAddTagButton)
    }

    func testOverlaySessionSetterAPIsUpdatePublishedFlags() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())

        viewModel.setCommentLinkPopoverPresented(true)
        viewModel.setAllCommentsBrowserActive(true)
        viewModel.setHoveringAddTagButton(true)
        viewModel.setHoveringAddCommentButton(true)

        XCTAssertTrue(viewModel.isCommentLinkPopoverPresented)
        XCTAssertTrue(viewModel.isAllCommentsBrowserActive)
        XCTAssertTrue(viewModel.isHoveringAddTagButton)
        XCTAssertTrue(viewModel.isHoveringAddCommentButton)
    }
}
