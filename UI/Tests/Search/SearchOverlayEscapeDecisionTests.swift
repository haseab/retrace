import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class SearchOverlayEscapeDecisionTests: XCTestCase {
    func testExpandedOverlayEscShouldCollapseWithoutSubmittedSearch() {
        XCTAssertFalse(
            SearchViewModel.shouldDismissExpandedOverlayOnEscape(
                committedSearchQuery: "",
                hasSearchResultsPayload: false
            )
        )
    }

    func testExpandedOverlayEscShouldDismissWhenCommittedQueryExists() {
        XCTAssertTrue(
            SearchViewModel.shouldDismissExpandedOverlayOnEscape(
                committedSearchQuery: "meeting notes",
                hasSearchResultsPayload: false
            )
        )
    }

    func testExpandedOverlayEscShouldDismissWhenResultsPayloadExists() {
        XCTAssertTrue(
            SearchViewModel.shouldDismissExpandedOverlayOnEscape(
                committedSearchQuery: "",
                hasSearchResultsPayload: true
            )
        )
    }
}
