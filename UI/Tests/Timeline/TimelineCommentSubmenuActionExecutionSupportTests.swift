import XCTest
@testable import Retrace

final class TimelineCommentSubmenuActionExecutionSupportTests: XCTestCase {
    func testExecuteDispatchesEnvironmentActions() {
        var dismissedTag = false
        var dismissedLink = false
        var exited = false
        var closed = false
        var openedAll = false
        var focusedSearch = false
        var seeded = false
        var movedDelta: Int?

        let environment = TimelineCommentSubmenuActionExecutionEnvironment(
            dismissTagSubmenu: { dismissedTag = true },
            dismissLinkPopover: { dismissedLink = true },
            exitAllComments: { exited = true },
            closeSubmenu: { closed = true },
            openAllComments: { openedAll = true },
            focusSearchField: { focusedSearch = true },
            seedHighlightedSelection: { seeded = true },
            moveHighlightedSelection: { movedDelta = $0 },
            openHighlightedSelection: { true }
        )

        XCTAssertTrue(TimelineCommentSubmenuActionExecutionSupport.execute(.dismissTagSubmenu, environment: environment))
        XCTAssertTrue(dismissedTag)

        XCTAssertTrue(TimelineCommentSubmenuActionExecutionSupport.execute(.dismissLinkPopover, environment: environment))
        XCTAssertTrue(dismissedLink)

        XCTAssertTrue(TimelineCommentSubmenuActionExecutionSupport.execute(.exitAllComments, environment: environment))
        XCTAssertTrue(exited)

        XCTAssertTrue(TimelineCommentSubmenuActionExecutionSupport.execute(.closeSubmenu, environment: environment))
        XCTAssertTrue(closed)

        XCTAssertTrue(TimelineCommentSubmenuActionExecutionSupport.execute(.openAllComments, environment: environment))
        XCTAssertTrue(openedAll)

        XCTAssertTrue(TimelineCommentSubmenuActionExecutionSupport.execute(.focusSearchField, environment: environment))
        XCTAssertTrue(focusedSearch)

        XCTAssertTrue(TimelineCommentSubmenuActionExecutionSupport.execute(.seedHighlightedSelection, environment: environment))
        XCTAssertTrue(seeded)

        XCTAssertTrue(TimelineCommentSubmenuActionExecutionSupport.execute(.moveHighlightedSelection(delta: -1), environment: environment))
        XCTAssertEqual(movedDelta, -1)
    }

    func testExecuteReturnsFalseForNoneAndOpenSelectionUsesEnvironmentResult() {
        let falseEnvironment = TimelineCommentSubmenuActionExecutionEnvironment(
            dismissTagSubmenu: {},
            dismissLinkPopover: {},
            exitAllComments: {},
            closeSubmenu: {},
            openAllComments: {},
            focusSearchField: {},
            seedHighlightedSelection: {},
            moveHighlightedSelection: { _ in },
            openHighlightedSelection: { false }
        )

        XCTAssertFalse(TimelineCommentSubmenuActionExecutionSupport.execute(.none, environment: falseEnvironment))
        XCTAssertFalse(TimelineCommentSubmenuActionExecutionSupport.execute(.openHighlightedSelection, environment: falseEnvironment))

        let trueEnvironment = TimelineCommentSubmenuActionExecutionEnvironment(
            dismissTagSubmenu: {},
            dismissLinkPopover: {},
            exitAllComments: {},
            closeSubmenu: {},
            openAllComments: {},
            focusSearchField: {},
            seedHighlightedSelection: {},
            moveHighlightedSelection: { _ in },
            openHighlightedSelection: { true }
        )

        XCTAssertTrue(TimelineCommentSubmenuActionExecutionSupport.execute(.openHighlightedSelection, environment: trueEnvironment))
    }
}
