import CoreGraphics
import XCTest
import Shared
@testable import Retrace

final class TimelineFilterStateSupportTests: XCTestCase {
    func testNormalizedCriteriaClearsSelectedSourcesBeforeComparison() {
        let criteria = FilterCriteria(
            selectedApps: Set(["com.apple.Safari"]),
            selectedSources: Set([.native, .rewind])
        )

        let normalized = TimelineFilterStateSupport.normalizedCriteria(criteria)

        XCTAssertEqual(normalized.selectedApps, Set(["com.apple.Safari"]))
        XCTAssertNil(normalized.selectedSources)
    }

    func testPrepareApplyTreatsSourceOnlyDifferencesAsNoReload() {
        let current = FilterCriteria(selectedSources: Set([.native]))
        let pending = FilterCriteria(selectedSources: Set([.rewind]))

        let preparation = TimelineFilterStateSupport.prepareApply(current: current, pending: pending)

        XCTAssertFalse(preparation.requiresReload)
        XCTAssertEqual(preparation.normalizedCurrentCriteria, .none)
        XCTAssertEqual(preparation.normalizedPendingCriteria, .none)
    }

    func testToggledAppAddsAndRemovesBundleID() {
        let afterAdd = TimelineFilterStateSupport.toggledApp("com.apple.Safari", in: .none)
        XCTAssertEqual(afterAdd.selectedApps, Set(["com.apple.Safari"]))

        let afterRemove = TimelineFilterStateSupport.toggledApp("com.apple.Safari", in: afterAdd)
        XCTAssertNil(afterRemove.selectedApps)
    }

    func testToggledTagAddsAndRemovesTagID() {
        let afterAdd = TimelineFilterStateSupport.toggledTag(42, in: .none)
        XCTAssertEqual(afterAdd.selectedTags, Set([42]))

        let afterRemove = TimelineFilterStateSupport.toggledTag(42, in: afterAdd)
        XCTAssertNil(afterRemove.selectedTags)
    }

    func testSettingDateRangesSanitizesEmptyEntriesCapsAtFiveAndBackfillsLegacyFields() {
        let base = Date(timeIntervalSince1970: 1_700_100_000)
        let ranges = [
            DateRangeCriterion(start: nil, end: nil),
            DateRangeCriterion(start: base, end: nil),
            DateRangeCriterion(start: base.addingTimeInterval(100), end: base.addingTimeInterval(200)),
            DateRangeCriterion(start: base.addingTimeInterval(300), end: nil),
            DateRangeCriterion(start: nil, end: base.addingTimeInterval(400)),
            DateRangeCriterion(start: base.addingTimeInterval(500), end: base.addingTimeInterval(600)),
            DateRangeCriterion(start: base.addingTimeInterval(700), end: base.addingTimeInterval(800))
        ]

        let updated = TimelineFilterStateSupport.settingDateRanges(ranges, in: .none)

        XCTAssertEqual(updated.effectiveDateRanges.count, 5)
        XCTAssertEqual(updated.startDate, base)
        XCTAssertNil(updated.endDate)
        XCTAssertEqual(updated.effectiveDateRanges.first, DateRangeCriterion(start: base, end: nil))
        XCTAssertEqual(updated.effectiveDateRanges.last, DateRangeCriterion(start: base.addingTimeInterval(500), end: base.addingTimeInterval(600)))
    }

    func testShowingAppsDropdownStoresAnchorAndClosesCalendarEditing() {
        let anchor = CGRect(x: 10, y: 20, width: 30, height: 40)
        let state = TimelineFilterStateSupport.showingDropdown(
            type: .apps,
            anchorFrame: anchor,
            filterAnchorFrames: [.tags: CGRect(x: 1, y: 2, width: 3, height: 4)],
            isDateRangeCalendarEditing: true
        )

        XCTAssertEqual(state.activeFilterDropdown, .apps)
        XCTAssertEqual(state.filterDropdownAnchorFrame, anchor)
        XCTAssertEqual(state.filterAnchorFrames[.apps], anchor)
        XCTAssertTrue(state.isFilterDropdownOpen)
        XCTAssertFalse(state.isDateRangeCalendarEditing)
    }

    func testShowingAdvancedDropdownKeepsPopoverStateClosed() {
        let anchor = CGRect(x: 5, y: 6, width: 7, height: 8)
        let state = TimelineFilterStateSupport.showingDropdown(
            type: .advanced,
            anchorFrame: anchor,
            filterAnchorFrames: [:],
            isDateRangeCalendarEditing: true
        )

        XCTAssertEqual(state.activeFilterDropdown, .advanced)
        XCTAssertFalse(state.isFilterDropdownOpen)
        XCTAssertFalse(state.isDateRangeCalendarEditing)
    }

    func testShowingDateRangeDropdownPreservesCalendarEditingState() {
        let anchor = CGRect(x: 1, y: 1, width: 10, height: 10)
        let state = TimelineFilterStateSupport.showingDropdown(
            type: .dateRange,
            anchorFrame: anchor,
            filterAnchorFrames: [:],
            isDateRangeCalendarEditing: true
        )

        XCTAssertEqual(state.activeFilterDropdown, .dateRange)
        XCTAssertTrue(state.isFilterDropdownOpen)
        XCTAssertTrue(state.isDateRangeCalendarEditing)
    }

    func testDismissingDropdownResetsVisibilityButPreservesAnchorCache() {
        let anchor = CGRect(x: 99, y: 88, width: 77, height: 66)
        let state = TimelineFilterStateSupport.dismissingDropdown(
            anchorFrame: anchor,
            filterAnchorFrames: [.comments: anchor]
        )

        XCTAssertEqual(state.activeFilterDropdown, .none)
        XCTAssertEqual(state.filterDropdownAnchorFrame, anchor)
        XCTAssertEqual(state.filterAnchorFrames[.comments], anchor)
        XCTAssertFalse(state.isFilterDropdownOpen)
        XCTAssertFalse(state.isDateRangeCalendarEditing)
    }
}
