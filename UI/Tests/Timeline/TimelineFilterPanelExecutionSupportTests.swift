import CoreGraphics
import XCTest
@testable import Retrace

final class TimelineFilterPanelExecutionSupportTests: XCTestCase {
    func testApplyCommandClearsFocusCommitsDraftsAndAppliesRequestedDismissMode() {
        let recorder = CallRecorder()

        TimelineFilterPanelExecutionSupport.execute(
            .apply(dismissPanel: true),
            environment: makeEnvironment(recorder: recorder)
        )

        XCTAssertEqual(
            recorder.calls,
            [
                "clearActionButtonFocus",
                "commitAdvancedDraftInputs",
                "applyFilters(true)",
            ]
        )
    }

    func testClearCommandClearsFocusDraftsPendingFiltersAndAppliesWithoutDismiss() {
        let recorder = CallRecorder()

        TimelineFilterPanelExecutionSupport.execute(
            .clear,
            environment: makeEnvironment(recorder: recorder)
        )

        XCTAssertEqual(
            recorder.calls,
            [
                "clearActionButtonFocus",
                "clearDraftInputs",
                "clearPendingFilters",
                "applyFilters(false)",
            ]
        )
    }

    func testShowDropdownNavigationRoutesAnchorToEnvironment() {
        let recorder = CallRecorder()

        TimelineFilterPanelExecutionSupport.execute(
            .showDropdown(.comments, anchorFrame: CGRect(x: 1, y: 2, width: 3, height: 4)),
            environment: makeEnvironment(recorder: recorder)
        )

        XCTAssertEqual(recorder.calls, ["showDropdown(comments, 1.0, 2.0, 3.0, 4.0)"])
    }

    func testDismissPanelNavigationRoutesToEnvironment() {
        let recorder = CallRecorder()

        TimelineFilterPanelExecutionSupport.execute(
            .dismissPanel,
            environment: makeEnvironment(recorder: recorder)
        )

        XCTAssertEqual(recorder.calls, ["dismissPanel"])
    }

    private func makeEnvironment(
        recorder: CallRecorder
    ) -> TimelineFilterPanelExecutionEnvironment {
        TimelineFilterPanelExecutionEnvironment(
            clearActionButtonFocus: {
                recorder.calls.append("clearActionButtonFocus")
            },
            commitAdvancedDraftInputs: {
                recorder.calls.append("commitAdvancedDraftInputs")
            },
            clearDraftInputs: {
                recorder.calls.append("clearDraftInputs")
            },
            clearPendingFilters: {
                recorder.calls.append("clearPendingFilters")
            },
            applyFilters: { dismissPanel in
                recorder.calls.append("applyFilters(\(dismissPanel))")
            },
            showDropdown: { dropdown, anchorFrame in
                recorder.calls.append("showDropdown(\(self.dropdownName(dropdown)), \(anchorFrame.origin.x), \(anchorFrame.origin.y), \(anchorFrame.size.width), \(anchorFrame.size.height))")
            },
            dismissDropdown: {
                recorder.calls.append("dismissDropdown")
            },
            dismissPanel: {
                recorder.calls.append("dismissPanel")
            }
        )
    }

    private func dropdownName(_ dropdown: SimpleTimelineViewModel.FilterDropdownType) -> String {
        switch dropdown {
        case .none:
            return "none"
        case .apps:
            return "apps"
        case .tags:
            return "tags"
        case .visibility:
            return "visibility"
        case .comments:
            return "comments"
        case .dateRange:
            return "dateRange"
        case .advanced:
            return "advanced"
        }
    }

    private final class CallRecorder {
        var calls: [String] = []
    }
}
