import CoreGraphics
import XCTest
@testable import Retrace

final class TimelineFilterPanelActionSupportTests: XCTestCase {
    func testDropdownToggleDismissesWhenSameDropdownIsTapped() {
        let action = TimelineFilterPanelActionSupport.makeDropdownToggleAction(
            tappedDropdown: .apps,
            activeDropdown: .apps,
            anchorFrame: CGRect(x: 10, y: 20, width: 30, height: 40)
        )

        XCTAssertEqual(action, .dismissDropdown)
    }

    func testDropdownToggleShowsTappedDropdownWhenDifferentDropdownIsActive() {
        let action = TimelineFilterPanelActionSupport.makeDropdownToggleAction(
            tappedDropdown: .comments,
            activeDropdown: .tags,
            anchorFrame: CGRect(x: 10, y: 20, width: 30, height: 40)
        )

        XCTAssertEqual(
            action,
            .showDropdown(.comments, anchorFrame: CGRect(x: 10, y: 20, width: 30, height: 40))
        )
    }

    func testEscapeDismissDropdownMapsToNavigationAction() {
        XCTAssertEqual(
            TimelineFilterPanelActionSupport.makeNavigationAction(for: .dismissDropdown),
            .dismissDropdown
        )
    }

    func testResolveKeyboardDecisionMapsApplyAndDropdownAnchor() {
        let resolved = TimelineFilterPanelActionSupport.resolveKeyboardDecision(
            .consume(
                navigation: .showDropdown(.dateRange),
                command: .apply,
                shortcutToRecord: "timeline.filter_panel.apply"
            ),
            hasApplyButton: false,
            anchorFrameProvider: { dropdown in
                XCTAssertEqual(dropdown, .dateRange)
                return CGRect(x: 3, y: 4, width: 5, height: 6)
            }
        )

        XCTAssertEqual(
            resolved,
            TimelineFilterPanelResolvedKeyboardActions(
                shortcutToRecord: "timeline.filter_panel.apply",
                command: .apply(dismissPanel: false),
                navigation: .showDropdown(.dateRange, anchorFrame: CGRect(x: 3, y: 4, width: 5, height: 6))
            )
        )
    }

    func testResolveKeyboardDecisionMapsClearAndDismissPanel() {
        let resolved = TimelineFilterPanelActionSupport.resolveKeyboardDecision(
            .consume(
                navigation: .dismissPanel,
                command: .clear
            ),
            hasApplyButton: true,
            anchorFrameProvider: { _ in
                XCTFail("Anchor should not be requested for dismiss navigation")
                return .zero
            }
        )

        XCTAssertEqual(
            resolved,
            TimelineFilterPanelResolvedKeyboardActions(
                shortcutToRecord: nil,
                command: .clear,
                navigation: .dismissPanel
            )
        )
    }
}
