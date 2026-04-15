import XCTest
@testable import Retrace

@MainActor
final class TimelineCommentComposerControllerTests: XCTestCase {
    func testSendEditorCommandUpdatesCommandAndNonce() {
        let controller = TimelineCommentComposerController()

        controller.sendEditorCommand(.italic)

        XCTAssertEqual(controller.editorCommand, .italic)
        XCTAssertEqual(controller.editorCommandNonce, 1)

        controller.sendEditorCommand(.bold)

        XCTAssertEqual(controller.editorCommand, .bold)
        XCTAssertEqual(controller.editorCommandNonce, 2)
    }

    func testPresentLinkPopoverPreparesDefaultURLAndDefocusesEditor() {
        let controller = TimelineCommentComposerController()
        controller.isEditorFocused = true
        controller.pendingLinkURL = "   "

        controller.presentLinkPopover()

        XCTAssertFalse(controller.isEditorFocused)
        XCTAssertTrue(controller.isLinkPopoverPresented)
        XCTAssertEqual(controller.pendingLinkURL, "https://")
    }

    func testInsertLinkFromPopoverQueuesLinkCommandAndRefocusesEditor() {
        let controller = TimelineCommentComposerController()
        controller.presentLinkPopover()
        controller.pendingLinkURL = "example.com/docs"

        let didInsert = controller.insertLinkFromPopover()

        XCTAssertTrue(didInsert)
        XCTAssertFalse(controller.isLinkPopoverPresented)
        XCTAssertTrue(controller.isEditorFocused)
        XCTAssertEqual(controller.editorCommand, .link(url: "https://example.com/docs"))
        XCTAssertEqual(controller.editorCommandNonce, 1)
    }

    func testInsertLinkFromPopoverLeavesStateUnchangedForInvalidValue() {
        let controller = TimelineCommentComposerController()
        controller.presentLinkPopover()
        controller.pendingLinkURL = "   "

        let didInsert = controller.insertLinkFromPopover()

        XCTAssertFalse(didInsert)
        XCTAssertTrue(controller.isLinkPopoverPresented)
        XCTAssertFalse(controller.isEditorFocused)
        XCTAssertEqual(controller.editorCommandNonce, 0)
    }

    func testDismissLinkPopoverRespectsRequestedRefocusBehavior() {
        let controller = TimelineCommentComposerController()
        controller.isLinkPopoverPresented = true

        controller.dismissLinkPopover(refocusEditor: false)
        XCTAssertFalse(controller.isLinkPopoverPresented)
        XCTAssertFalse(controller.isEditorFocused)

        controller.isLinkPopoverPresented = true
        controller.dismissLinkPopover(refocusEditor: true)
        XCTAssertFalse(controller.isLinkPopoverPresented)
        XCTAssertTrue(controller.isEditorFocused)
    }
}
