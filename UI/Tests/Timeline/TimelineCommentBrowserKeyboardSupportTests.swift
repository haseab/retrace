import AppKit
import Foundation
import Shared
import XCTest
@testable import Retrace

final class TimelineCommentBrowserKeyboardSupportTests: XCTestCase {
    func testEscapeDismissesTagSubmenuBeforeOtherActions() {
        let action = TimelineCommentBrowserKeyboardSupport.action(
            for: makeContext(
                keyCode: 53,
                isBrowsingAllComments: true,
                isTagSubmenuVisible: true
            )
        )

        XCTAssertEqual(action, .dismissTagSubmenu)
    }

    func testEscapeReturnsToThreadWhenBrowsingAllComments() {
        let action = TimelineCommentBrowserKeyboardSupport.action(
            for: makeContext(
                keyCode: 53,
                isBrowsingAllComments: true
            )
        )

        XCTAssertEqual(action, .exitAllComments)
    }

    func testOptionAOpensAllCommentsOnlyFromThreadMode() {
        XCTAssertEqual(
            TimelineCommentBrowserKeyboardSupport.action(
                for: makeContext(
                    keyCode: 0,
                    modifiers: [.option],
                    isBrowsingAllComments: false
                )
            ),
            .openAllComments
        )

        XCTAssertEqual(
            TimelineCommentBrowserKeyboardSupport.action(
                for: makeContext(
                    keyCode: 0,
                    modifiers: [.option],
                    isBrowsingAllComments: true
                )
            ),
            .none
        )
    }

    func testTabFocusesSearchThenSeedsSelection() {
        XCTAssertEqual(
            TimelineCommentBrowserKeyboardSupport.action(
                for: makeContext(
                    keyCode: 48,
                    isBrowsingAllComments: true,
                    isSearchFieldFocused: false
                )
            ),
            .focusSearchField
        )

        XCTAssertEqual(
            TimelineCommentBrowserKeyboardSupport.action(
                for: makeContext(
                    keyCode: 48,
                    isBrowsingAllComments: true,
                    isSearchFieldFocused: true
                )
            ),
            .seedHighlightedSelection
        )
    }

    func testArrowAndReturnKeysMapToSelectionActions() {
        XCTAssertEqual(
            TimelineCommentBrowserKeyboardSupport.action(
                for: makeContext(
                    keyCode: 125,
                    isBrowsingAllComments: true
                )
            ),
            .moveHighlightedSelection(delta: 1)
        )

        XCTAssertEqual(
            TimelineCommentBrowserKeyboardSupport.action(
                for: makeContext(
                    keyCode: 126,
                    isBrowsingAllComments: true
                )
            ),
            .moveHighlightedSelection(delta: -1)
        )

        XCTAssertEqual(
            TimelineCommentBrowserKeyboardSupport.action(
                for: makeContext(
                    keyCode: 36,
                    isBrowsingAllComments: true
                )
            ),
            .openHighlightedSelection
        )
    }

    func testSyncedHighlightedIDClearsOutsideAllCommentsAndPrefersAnchorFallback() {
        let resultIDs = ids([1, 2, 3])

        XCTAssertNil(
            TimelineCommentBrowserKeyboardSupport.syncedHighlightedID(
                isBrowsingAllComments: false,
                currentHighlightedID: SegmentCommentID(value: 2),
                resultIDs: resultIDs,
                preferredAnchorID: SegmentCommentID(value: 3)
            )
        )

        XCTAssertEqual(
            TimelineCommentBrowserKeyboardSupport.syncedHighlightedID(
                isBrowsingAllComments: true,
                currentHighlightedID: SegmentCommentID(value: 9),
                resultIDs: resultIDs,
                preferredAnchorID: SegmentCommentID(value: 3)
            ),
            SegmentCommentID(value: 3)
        )
    }

    func testMovedHighlightedIDUsesCurrentThenPreferredAnchorAndClamps() {
        let resultIDs = ids([1, 2, 3, 4])

        XCTAssertEqual(
            TimelineCommentBrowserKeyboardSupport.movedHighlightedID(
                delta: 1,
                currentHighlightedID: SegmentCommentID(value: 2),
                resultIDs: resultIDs,
                preferredAnchorID: SegmentCommentID(value: 4)
            ),
            SegmentCommentID(value: 3)
        )

        XCTAssertEqual(
            TimelineCommentBrowserKeyboardSupport.movedHighlightedID(
                delta: -1,
                currentHighlightedID: nil,
                resultIDs: resultIDs,
                preferredAnchorID: SegmentCommentID(value: 3)
            ),
            SegmentCommentID(value: 2)
        )

        XCTAssertEqual(
            TimelineCommentBrowserKeyboardSupport.movedHighlightedID(
                delta: -1,
                currentHighlightedID: nil,
                resultIDs: resultIDs,
                preferredAnchorID: nil
            ),
            SegmentCommentID(value: 1)
        )
    }

    func testSeededHighlightedIDPreservesExistingSelectionAndUsesAnchorOtherwise() {
        let resultIDs = ids([1, 2, 3, 4])

        XCTAssertEqual(
            TimelineCommentBrowserKeyboardSupport.seededHighlightedID(
                isBrowsingAllComments: true,
                currentHighlightedID: SegmentCommentID(value: 4),
                resultIDs: resultIDs,
                preferredAnchorID: SegmentCommentID(value: 2)
            ),
            SegmentCommentID(value: 4)
        )

        XCTAssertEqual(
            TimelineCommentBrowserKeyboardSupport.seededHighlightedID(
                isBrowsingAllComments: true,
                currentHighlightedID: nil,
                resultIDs: resultIDs,
                preferredAnchorID: SegmentCommentID(value: 2)
            ),
            SegmentCommentID(value: 2)
        )
    }

    func testResolvedOpenTargetFallsBackToFirstVisibleResult() {
        let resultIDs = ids([5, 6, 7])

        XCTAssertEqual(
            TimelineCommentBrowserKeyboardSupport.resolvedOpenTarget(
                isBrowsingAllComments: true,
                highlightedID: SegmentCommentID(value: 6),
                resultIDs: resultIDs
            ),
            TimelineCommentBrowserOpenTarget(
                targetID: SegmentCommentID(value: 6),
                resolvedHighlightedID: SegmentCommentID(value: 6)
            )
        )

        XCTAssertEqual(
            TimelineCommentBrowserKeyboardSupport.resolvedOpenTarget(
                isBrowsingAllComments: true,
                highlightedID: nil,
                resultIDs: resultIDs
            ),
            TimelineCommentBrowserOpenTarget(
                targetID: SegmentCommentID(value: 5),
                resolvedHighlightedID: SegmentCommentID(value: 5)
            )
        )
    }

    private func makeContext(
        keyCode: UInt16,
        charactersIgnoringModifiers: String? = nil,
        modifiers: NSEvent.ModifierFlags = [],
        isBrowsingAllComments: Bool,
        hasPendingDeleteConfirmation: Bool = false,
        isTagSubmenuVisible: Bool = false,
        isLinkPopoverPresented: Bool = false,
        isSearchFieldFocused: Bool = false
    ) -> TimelineCommentBrowserKeyboardContext {
        TimelineCommentBrowserKeyboardContext(
            keyCode: keyCode,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifiers: modifiers,
            isBrowsingAllComments: isBrowsingAllComments,
            hasPendingDeleteConfirmation: hasPendingDeleteConfirmation,
            isTagSubmenuVisible: isTagSubmenuVisible,
            isLinkPopoverPresented: isLinkPopoverPresented,
            isSearchFieldFocused: isSearchFieldFocused
        )
    }

    private func ids(_ values: [Int64]) -> [SegmentCommentID] {
        values.map(SegmentCommentID.init(value:))
    }
}
