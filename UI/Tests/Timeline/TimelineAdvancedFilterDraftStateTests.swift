import XCTest
import Shared
@testable import Retrace

@MainActor
final class TimelineAdvancedFilterDraftStateTests: XCTestCase {
    func testCommitWindowNameDraftDeduplicatesAndClearsOpposingExcludeTerm() {
        let draftState = TimelineAdvancedFilterDraftState()
        draftState.windowNameExcludeTerms = ["Safari"]
        draftState.windowNameFilterMode = .include
        draftState.windowInputText = "  Safari  "

        draftState.commitWindowNameDraft()

        XCTAssertEqual(draftState.windowNameIncludeTerms, ["Safari"])
        XCTAssertTrue(draftState.windowNameExcludeTerms.isEmpty)
        XCTAssertEqual(draftState.windowInputText, "")
    }

    func testApplyMetadataFiltersEncodesWindowAndBrowserTerms() {
        let draftState = TimelineAdvancedFilterDraftState()
        draftState.windowNameIncludeTerms = ["Safari"]
        draftState.windowNameExcludeTerms = ["Private"]
        draftState.browserUrlIncludeTerms = ["openai.com"]

        var criteria = FilterCriteria.none
        draftState.applyMetadataFilters(to: &criteria)

        let decodedWindow = TimelineAdvancedFilterDraftState.decodeMetadataFilter(criteria.windowNameFilter)
        let decodedBrowser = TimelineAdvancedFilterDraftState.decodeMetadataFilter(criteria.browserUrlFilter)

        XCTAssertEqual(decodedWindow.includeTerms, ["Safari"])
        XCTAssertEqual(decodedWindow.excludeTerms, ["Private"])
        XCTAssertEqual(decodedBrowser.includeTerms, ["openai.com"])
        XCTAssertTrue(decodedBrowser.excludeTerms.isEmpty)
    }

    func testSyncRestoresLegacyExcludePayload() {
        let draftState = TimelineAdvancedFilterDraftState()
        let legacyPayload = TimelineAdvancedFilterDraftState.EncodedMetadataFilterPayload(
            includeTerms: nil,
            excludeTerms: nil,
            mode: .exclude,
            terms: ["docs", "api"]
        )
        let data = try! JSONEncoder().encode(legacyPayload)
        let encoded = TimelineAdvancedFilterDraftState.metadataFilterPrefix + data.base64EncodedString()

        draftState.sync(from: FilterCriteria(browserUrlFilter: encoded))

        XCTAssertTrue(draftState.browserUrlIncludeTerms.isEmpty)
        XCTAssertEqual(draftState.browserUrlExcludeTerms, ["docs", "api"])
        XCTAssertEqual(draftState.browserUrlFilterMode, .exclude)
    }
}
