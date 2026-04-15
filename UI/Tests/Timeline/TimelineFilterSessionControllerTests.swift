import CoreGraphics
import XCTest
import Shared
import App
@testable import Retrace

@MainActor
final class TimelineFilterStoreSessionTests: XCTestCase {
    private let invalidate = {}

    func testOpenPanelNormalizesAppliedCriteriaSyncsPendingAndDismissesDropdown() {
        let store = TimelineFilterStore()
        store.setDateRangeCalendarEditing(true, invalidate: invalidate)
        store.showDropdown(
            .dateRange,
            anchorFrame: CGRect(x: 10, y: 20, width: 30, height: 40),
            invalidate: invalidate
        )

        let appliedCriteria = TimelineFilterStateSupport.normalizedCriteria(
            FilterCriteria(
                selectedApps: Set(["com.apple.Safari"]),
                selectedSources: Set([.native, .rewind])
            )
        )

        store.openPanel(appliedCriteria: appliedCriteria, invalidate: invalidate)

        XCTAssertEqual(store.sessionState.filterCriteria, appliedCriteria)
        XCTAssertEqual(store.sessionState.pendingFilterCriteria, appliedCriteria)
        XCTAssertTrue(store.sessionState.isFilterPanelVisible)
        XCTAssertEqual(store.sessionState.activeFilterDropdown, .none)
        XCTAssertFalse(store.sessionState.isFilterDropdownOpen)
        XCTAssertFalse(store.sessionState.isDateRangeCalendarEditing)
    }

    func testDismissPanelRestoresPendingToAppliedCriteriaAndHidesUI() {
        let store = TimelineFilterStore()
        let appliedCriteria = FilterCriteria(selectedApps: Set(["com.apple.Safari"]))
        store.openPanel(appliedCriteria: appliedCriteria, invalidate: invalidate)
        store.setPendingFilterCriteria(
            FilterCriteria(selectedTags: Set([42])),
            invalidate: invalidate
        )

        store.dismissPanel(appliedCriteria: appliedCriteria, invalidate: invalidate)

        XCTAssertEqual(store.sessionState.filterCriteria, appliedCriteria)
        XCTAssertEqual(store.sessionState.pendingFilterCriteria, appliedCriteria)
        XCTAssertFalse(store.sessionState.isFilterPanelVisible)
        XCTAssertEqual(store.sessionState.activeFilterDropdown, .none)
    }

    func testApplyPendingFiltersAppliesNormalizedCriteriaAndDismissesPanelWhenRequested() {
        let store = TimelineFilterStore()
        store.openPanel(appliedCriteria: .none, invalidate: invalidate)
        store.setPendingFilterCriteria(
            FilterCriteria(
                selectedApps: Set(["com.apple.Safari"]),
                selectedSources: Set([.rewind])
            ),
            invalidate: invalidate
        )

        let result = store.applyPendingFilters(dismissPanel: true, invalidate: invalidate)

        XCTAssertTrue(result.requiresReload)
        XCTAssertEqual(result.resultingCriteria.selectedApps, Set(["com.apple.Safari"]))
        XCTAssertNil(result.resultingCriteria.selectedSources)
        XCTAssertEqual(store.sessionState.filterCriteria, result.resultingCriteria)
        XCTAssertEqual(store.sessionState.pendingFilterCriteria, result.resultingCriteria)
        XCTAssertFalse(store.sessionState.isFilterPanelVisible)
    }

    func testClearWithoutReloadClearsCriteriaDismissesUIAndConsumesReloadFlagOnce() {
        let store = TimelineFilterStore()
        store.openPanel(
            appliedCriteria: FilterCriteria(selectedApps: Set(["com.apple.Safari"])),
            invalidate: invalidate
        )
        store.showDropdown(
            .apps,
            anchorFrame: CGRect(x: 1, y: 2, width: 3, height: 4),
            invalidate: invalidate
        )

        XCTAssertTrue(store.clearWithoutReload(invalidate: invalidate))
        XCTAssertEqual(store.sessionState.filterCriteria, .none)
        XCTAssertEqual(store.sessionState.pendingFilterCriteria, .none)
        XCTAssertFalse(store.sessionState.isFilterPanelVisible)
        XCTAssertEqual(store.sessionState.activeFilterDropdown, .none)
        XCTAssertTrue(store.consumeRequiresFullReloadOnNextRefresh(invalidate: invalidate))
        XCTAssertFalse(store.consumeRequiresFullReloadOnNextRefresh(invalidate: invalidate))
    }
}

@MainActor
final class TimelineFilterSessionViewModelBridgeTests: XCTestCase {
    func testExplicitFilterStateSettersRemainVisibleToControllerBackedClearWithoutReload() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let activeCriteria = FilterCriteria(selectedApps: Set(["com.apple.Safari"]))

        viewModel.setAppliedFilterCriteria(activeCriteria)
        viewModel.replacePendingFilterCriteria(activeCriteria)
        viewModel.setFilterPanelVisible(true)

        viewModel.clearFiltersWithoutReload()

        XCTAssertEqual(viewModel.filterCriteria, FilterCriteria.none)
        XCTAssertEqual(viewModel.pendingFilterCriteria, FilterCriteria.none)
        XCTAssertFalse(viewModel.isFilterPanelVisible)
    }

    func testReplaceAppliedAndPendingFilterCriteriaNormalizesSelectedSources() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let criteria = FilterCriteria(
            selectedApps: Set(["com.apple.Safari"]),
            selectedSources: Set([.native, .rewind])
        )

        viewModel.replaceAppliedAndPendingFilterCriteria(criteria)

        XCTAssertEqual(viewModel.filterCriteria.selectedApps, Set(["com.apple.Safari"]))
        XCTAssertEqual(viewModel.pendingFilterCriteria.selectedApps, Set(["com.apple.Safari"]))
        XCTAssertNil(viewModel.filterCriteria.selectedSources)
        XCTAssertNil(viewModel.pendingFilterCriteria.selectedSources)
    }

    func testSetFilterAnchorFrameUpdatesActiveDropdownAnchor() {
        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())
        let originalFrame = CGRect(x: 10, y: 20, width: 30, height: 40)
        let updatedFrame = CGRect(x: 50, y: 60, width: 70, height: 80)

        viewModel.showFilterDropdown(.apps, anchorFrame: originalFrame)
        viewModel.setFilterAnchorFrame(updatedFrame, for: .apps)

        XCTAssertEqual(viewModel.filterAnchorFrames[.apps], updatedFrame)
        XCTAssertEqual(viewModel.filterDropdownAnchorFrame, updatedFrame)
    }
}
