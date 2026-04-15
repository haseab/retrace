import XCTest
import AppKit
@testable import Retrace

final class TimelineFilterPanelKeyboardSupportTests: XCTestCase {
    func testEscapeDismissesDropdownWhenDateRangeCalendarIsEditing() {
        XCTAssertEqual(
            TimelineFilterPanelKeyboardSupport.makeEscapeAction(
                activeFilterDropdown: .dateRange,
                isDateRangeCalendarEditing: true
            ),
            .dismissDropdown
        )
    }

    func testEscapeDismissesPanelWhenNoDropdownIsOpen() {
        XCTAssertEqual(
            TimelineFilterPanelKeyboardSupport.makeEscapeAction(
                activeFilterDropdown: .none,
                isDateRangeCalendarEditing: false
            ),
            .dismissPanel
        )
    }

    func testCommandReturnTriggersApplyShortcut() {
        let decision = TimelineFilterPanelKeyboardSupport.makeKeyDecision(
            keyCode: 36,
            modifiers: [.command],
            context: makeContext()
        )

        XCTAssertEqual(
            decision,
            .consume(
                command: .apply,
                shortcutToRecord: "timeline.filter_panel.apply"
            )
        )
    }

    func testRightArrowMovesFromAppsToTagsDropdown() {
        let decision = TimelineFilterPanelKeyboardSupport.makeKeyDecision(
            keyCode: 124,
            modifiers: [],
            context: makeContext(activeFilterDropdown: .apps)
        )

        XCTAssertEqual(
            decision,
            .consume(navigation: .showDropdown(.tags))
        )
    }

    func testRightArrowPreservesNativeCaretMovementInsideAdvancedTextField() {
        let decision = TimelineFilterPanelKeyboardSupport.makeKeyDecision(
            keyCode: 124,
            modifiers: [],
            context: makeContext(activeFilterDropdown: .advanced, advancedFocusedFieldIndex: 1)
        )

        XCTAssertEqual(decision, .passthrough)
    }

    func testDownArrowFromBrowserFieldMovesToLeadingActionButton() {
        let decision = TimelineFilterPanelKeyboardSupport.makeKeyDecision(
            keyCode: 125,
            modifiers: [],
            context: makeContext(
                activeFilterDropdown: .advanced,
                advancedFocusedFieldIndex: 2,
                hasClearButton: true,
                hasApplyButton: true
            )
        )

        XCTAssertEqual(
            decision,
            .consume(
                actionButtonFocus: .set(.clear),
                advancedFocus: .set(-4)
            )
        )
    }

    func testTabFromAdvancedHeaderMovesToLeadingActionButton() {
        let decision = TimelineFilterPanelKeyboardSupport.makeKeyDecision(
            keyCode: 48,
            modifiers: [],
            context: makeContext(
                activeFilterDropdown: .advanced,
                advancedFocusedFieldIndex: 0,
                hasClearButton: false,
                hasApplyButton: true
            )
        )

        XCTAssertEqual(
            decision,
            .consume(
                actionButtonFocus: .set(.apply),
                advancedFocus: .set(-4)
            )
        )
    }

    func testShiftTabFromAppsFocusesTrailingActionButtonAndDismissesDropdown() {
        let decision = TimelineFilterPanelKeyboardSupport.makeKeyDecision(
            keyCode: 48,
            modifiers: [.shift],
            context: makeContext(
                activeFilterDropdown: .apps,
                hasClearButton: true,
                hasApplyButton: true
            )
        )

        XCTAssertEqual(
            decision,
            .consume(
                actionButtonFocus: .set(.apply),
                navigation: .dismissDropdown
            )
        )
    }

    private func makeContext(
        activeFilterDropdown: SimpleTimelineViewModel.FilterDropdownType = .none,
        advancedFocusedFieldIndex: Int = 0,
        isDateRangeCalendarEditing: Bool = false,
        focusedActionButton: TimelineFilterPanelActionButtonFocus? = nil,
        hasClearButton: Bool = true,
        hasApplyButton: Bool = true
    ) -> TimelineFilterPanelKeyboardContext {
        TimelineFilterPanelKeyboardContext(
            activeFilterDropdown: activeFilterDropdown,
            advancedFocusedFieldIndex: advancedFocusedFieldIndex,
            isDateRangeCalendarEditing: isDateRangeCalendarEditing,
            focusedActionButton: focusedActionButton,
            hasClearButton: hasClearButton,
            hasApplyButton: hasApplyButton
        )
    }
}
