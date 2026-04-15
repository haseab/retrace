import CoreGraphics
import Shared
import XCTest
@testable import Retrace

final class TimelineFilterDropdownExecutionSupportTests: XCTestCase {
    func testExecuteAppSelectionTogglesWhenBundleIDIsPresent() {
        let recorder = CallRecorder()

        TimelineFilterDropdownExecutionSupport.executeAppSelection(
            "com.apple.Safari",
            environment: makeEnvironment(recorder: recorder)
        )

        XCTAssertEqual(recorder.calls, ["toggleApp(com.apple.Safari)"])
    }

    func testExecuteAppSelectionClearsWhenBundleIDIsNil() {
        let recorder = CallRecorder()

        TimelineFilterDropdownExecutionSupport.executeAppSelection(
            nil,
            environment: makeEnvironment(recorder: recorder)
        )

        XCTAssertEqual(recorder.calls, ["clearPendingAppSelection"])
    }

    func testExecuteTagSelectionClearsWhenTagIDIsNil() {
        let recorder = CallRecorder()

        TimelineFilterDropdownExecutionSupport.executeTagSelection(
            nil,
            environment: makeEnvironment(recorder: recorder)
        )

        XCTAssertEqual(recorder.calls, ["clearPendingTagSelection"])
    }

    func testExecuteAdvanceNavigationShowsNextDropdownAtAnchor() {
        let recorder = CallRecorder()

        TimelineFilterDropdownExecutionSupport.executeAdvanceNavigation(
            from: .visibility,
            environment: makeEnvironment(recorder: recorder)
        )

        XCTAssertEqual(recorder.calls, ["showDropdown(comments, 9.0, 8.0, 7.0, 6.0)"])
    }

    func testExecuteAdvanceNavigationDoesNothingWithoutNextDropdown() {
        let recorder = CallRecorder()

        TimelineFilterDropdownExecutionSupport.executeAdvanceNavigation(
            from: .apps,
            environment: makeEnvironment(recorder: recorder)
        )

        XCTAssertTrue(recorder.calls.isEmpty)
    }

    private func makeEnvironment(
        recorder: CallRecorder
    ) -> TimelineFilterDropdownExecutionEnvironment {
        TimelineFilterDropdownExecutionEnvironment(
            toggleApp: { bundleID in
                recorder.calls.append("toggleApp(\(bundleID))")
            },
            clearPendingAppSelection: {
                recorder.calls.append("clearPendingAppSelection")
            },
            setAppFilterMode: { mode in
                recorder.calls.append("setAppFilterMode(\(mode.rawValue))")
            },
            toggleTag: { tagID in
                recorder.calls.append("toggleTag(\(tagID.value))")
            },
            clearPendingTagSelection: {
                recorder.calls.append("clearPendingTagSelection")
            },
            setTagFilterMode: { mode in
                recorder.calls.append("setTagFilterMode(\(mode.rawValue))")
            },
            setHiddenFilter: { filter in
                recorder.calls.append("setHiddenFilter(\(filter.rawValue))")
            },
            setCommentFilter: { filter in
                recorder.calls.append("setCommentFilter(\(filter.rawValue))")
            },
            setDateRanges: { ranges in
                recorder.calls.append("setDateRanges(\(ranges.count))")
            },
            setDateRangeCalendarEditingState: { isEditing in
                recorder.calls.append("setDateRangeCalendarEditingState(\(isEditing))")
            },
            recordKeyboardShortcut: { shortcut in
                recorder.calls.append("recordKeyboardShortcut(\(shortcut))")
            },
            dismissDropdown: {
                recorder.calls.append("dismissDropdown")
            },
            showDropdown: { dropdown, anchorFrame in
                recorder.calls.append("showDropdown(\(self.dropdownName(dropdown)), \(anchorFrame.origin.x), \(anchorFrame.origin.y), \(anchorFrame.size.width), \(anchorFrame.size.height))")
            },
            anchorFrameProvider: { dropdown in
                XCTAssertEqual(dropdown, .comments)
                return CGRect(x: 9, y: 8, width: 7, height: 6)
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
