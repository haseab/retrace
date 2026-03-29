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

    func testExpandedOverlayEscShouldRefocusSearchFieldBeforeDismissWhenQueryExistsAndFieldIsNotFocused() {
        XCTAssertTrue(
            SearchViewModel.shouldRefocusSearchFieldOnEscape(
                committedSearchQuery: "meeting notes",
                hasSearchResultsPayload: false,
                isSearchFieldFocused: false
            )
        )
    }

    func testExpandedOverlayEscShouldRefocusSearchFieldBeforeDismissWhenResultsExistAndFieldIsNotFocused() {
        XCTAssertTrue(
            SearchViewModel.shouldRefocusSearchFieldOnEscape(
                committedSearchQuery: "",
                hasSearchResultsPayload: true,
                isSearchFieldFocused: false
            )
        )
    }

    func testExpandedOverlayEscShouldNotRefocusSearchFieldWhenFieldIsAlreadyFocused() {
        XCTAssertFalse(
            SearchViewModel.shouldRefocusSearchFieldOnEscape(
                committedSearchQuery: "meeting notes",
                hasSearchResultsPayload: true,
                isSearchFieldFocused: true
            )
        )
    }
}
