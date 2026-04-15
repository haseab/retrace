import XCTest
@testable import Retrace

@MainActor
final class TimelineFilterPanelInteractionControllerTests: XCTestCase {
    func testApplyDecisionUpdatesPublishedFocusState() {
        let controller = TimelineFilterPanelInteractionController()

        controller.apply(
            .consume(
                actionButtonFocus: .set(.apply),
                advancedFocus: .set(2)
            )
        )

        XCTAssertEqual(controller.focusedActionButton, .apply)
        XCTAssertEqual(controller.advancedFocusedFieldIndex, 2)
    }

    func testReconcileFocusFallsBackToRemainingButton() {
        let controller = TimelineFilterPanelInteractionController()
        controller.focusedActionButton = .clear

        controller.reconcileActionButtonFocus(
            hasClearButton: false,
            hasApplyButton: true
        )

        XCTAssertEqual(controller.focusedActionButton, .apply)
    }

    func testReconcileFocusClearsWhenNoButtonsRemain() {
        let controller = TimelineFilterPanelInteractionController()
        controller.focusedActionButton = .apply

        controller.reconcileActionButtonFocus(
            hasClearButton: false,
            hasApplyButton: false
        )

        XCTAssertNil(controller.focusedActionButton)
    }

    func testResetTransientStateClearsFocusAndAdvancedIndex() {
        let controller = TimelineFilterPanelInteractionController()
        controller.focusedActionButton = .clear
        controller.advancedFocusedFieldIndex = 2

        controller.resetTransientState()

        XCTAssertNil(controller.focusedActionButton)
        XCTAssertEqual(controller.advancedFocusedFieldIndex, 0)
    }
}
