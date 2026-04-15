import Foundation
import Shared
import XCTest
@testable import Retrace

@MainActor
final class TimelineFilterPanelPresentationSupportTests: XCTestCase {
    func testPresentationUsesNamedAppAndTagLabels() {
        let pendingCriteria = FilterCriteria(
            selectedApps: ["com.apple.Safari"],
            selectedTags: [7]
        )

        let presentation = TimelineFilterPanelPresentationSupport.makePresentation(
            pendingCriteria: pendingCriteria,
            appliedCriteria: .none,
            availableApps: [(bundleID: "com.apple.Safari", name: "Safari")],
            availableTags: [Tag(id: TagID(value: 7), name: "Work")],
            dateFormatter: makeFormatter()
        )

        XCTAssertEqual(presentation.appsLabel, "Safari")
        XCTAssertEqual(presentation.tagsLabel, "Work")
        XCTAssertTrue(presentation.hasClearButton)
        XCTAssertTrue(presentation.hasApplyButton)
    }

    func testPresentationUsesExcludePrefixAndCountLabelForMultipleApps() {
        let pendingCriteria = FilterCriteria(
            selectedApps: ["com.apple.Safari", "com.google.Chrome"],
            appFilterMode: .exclude
        )

        let presentation = TimelineFilterPanelPresentationSupport.makePresentation(
            pendingCriteria: pendingCriteria,
            appliedCriteria: .none,
            availableApps: [],
            availableTags: [],
            dateFormatter: makeFormatter()
        )

        XCTAssertEqual(presentation.appsLabel, "Exclude: 2 Apps")
    }

    func testPresentationFormatsDateRangeAndSuppressesApplyWhenAppliedFiltersExist() {
        let pendingCriteria = FilterCriteria(
            startDate: date(year: 2026, month: 4, day: 10),
            endDate: date(year: 2026, month: 4, day: 12)
        )

        let presentation = TimelineFilterPanelPresentationSupport.makePresentation(
            pendingCriteria: pendingCriteria,
            appliedCriteria: pendingCriteria,
            availableApps: [],
            availableTags: [],
            dateFormatter: makeFormatter()
        )

        XCTAssertEqual(presentation.dateRangeLabel, "Apr 10 - Apr 12")
        XCTAssertTrue(presentation.hasClearButton)
        XCTAssertFalse(presentation.hasApplyButton)
    }

    func testPresentationUsesMultiRangeSummary() {
        let pendingCriteria = FilterCriteria(
            dateRanges: [
                DateRangeCriterion(start: date(year: 2026, month: 4, day: 10), end: nil),
                DateRangeCriterion(start: nil, end: date(year: 2026, month: 4, day: 12))
            ]
        )

        let presentation = TimelineFilterPanelPresentationSupport.makePresentation(
            pendingCriteria: pendingCriteria,
            appliedCriteria: .none,
            availableApps: [],
            availableTags: [],
            dateFormatter: makeFormatter()
        )

        XCTAssertEqual(presentation.dateRangeLabel, "2 date ranges")
    }

    func testCommittedPendingCriteriaMergesAdvancedDraftMetadata() {
        let draftState = TimelineAdvancedFilterDraftState()
        draftState.windowInputText = "Quarterly Plan"
        draftState.browserInputText = "docs.example.com"

        let committed = TimelineFilterPanelPresentationSupport.committedPendingCriteria(
            from: .none,
            draftState: draftState
        )

        let decodedWindowFilter = TimelineAdvancedFilterDraftState.decodeMetadataFilter(committed.windowNameFilter)
        let decodedBrowserFilter = TimelineAdvancedFilterDraftState.decodeMetadataFilter(committed.browserUrlFilter)

        XCTAssertEqual(decodedWindowFilter.includeTerms, ["Quarterly Plan"])
        XCTAssertEqual(decodedBrowserFilter.includeTerms, ["docs.example.com"])
    }

    private func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d"
        return formatter
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return components.date!
    }
}
