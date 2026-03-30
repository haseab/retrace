import XCTest
import Shared
@testable import Retrace

final class CaptureIntervalSettingsTests: XCTestCase {
    func testMouseClickCaptureDefaultsToDisabledUntilPermissionGranted() {
        XCTAssertFalse(SettingsDefaults.captureOnMouseClick)
        XCTAssertFalse(CaptureConfig().captureOnMouseClick)
    }

    func testAutomaticCaptureConfigurationRequiresAtLeastOneTrigger() {
        XCTAssertTrue(
            SettingsView.hasAutomaticCaptureTrigger(
                captureIntervalSeconds: 2,
                captureOnWindowChange: false,
                captureOnMouseClick: false
            )
        )
        XCTAssertTrue(
            SettingsView.hasAutomaticCaptureTrigger(
                captureIntervalSeconds: 0,
                captureOnWindowChange: true,
                captureOnMouseClick: false
            )
        )
        XCTAssertTrue(
            SettingsView.hasAutomaticCaptureTrigger(
                captureIntervalSeconds: 0,
                captureOnWindowChange: false,
                captureOnMouseClick: true
            )
        )
        XCTAssertFalse(
            SettingsView.hasAutomaticCaptureTrigger(
                captureIntervalSeconds: 0,
                captureOnWindowChange: false,
                captureOnMouseClick: false
            )
        )
    }

    func testDisablingIntervalIsRejectedWhenItWouldTurnOffAllAutomaticTriggers() {
        XCTAssertTrue(
            SettingsView.shouldRejectCaptureIntervalSelection(
                0,
                captureOnWindowChange: false,
                captureOnMouseClick: false
            )
        )
        XCTAssertFalse(
            SettingsView.shouldRejectCaptureIntervalSelection(
                0,
                captureOnWindowChange: true,
                captureOnMouseClick: false
            )
        )
    }

    func testDisablingEventDrivenTriggerIsRejectedWhenIntervalIsOffAndOtherTriggerIsOff() {
        XCTAssertTrue(
            SettingsView.shouldRejectEventDrivenTriggerDisable(
                captureIntervalSeconds: 0,
                otherEventDrivenTriggerEnabled: false
            )
        )
        XCTAssertFalse(
            SettingsView.shouldRejectEventDrivenTriggerDisable(
                captureIntervalSeconds: 2,
                otherEventDrivenTriggerEnabled: false
            )
        )
        XCTAssertFalse(
            SettingsView.shouldRejectEventDrivenTriggerDisable(
                captureIntervalSeconds: 0,
                otherEventDrivenTriggerEnabled: true
            )
        )
    }

    func testCaptureIntervalDisplayTextUsesNoneLabelWhenDisabled() {
        XCTAssertEqual(SettingsView.captureIntervalDisplayText(for: 0), "None")
    }

    func testCaptureIntervalPickerPlacesDisabledOptionAfterTimedIntervals() {
        XCTAssertEqual(CaptureIntervalPicker.intervals, [2, 5, 10, 15, 30, 60, 0])
        XCTAssertEqual(
            CaptureIntervalPicker.intervals.map(CaptureIntervalPicker.intervalLabel),
            ["2s", "5s", "10s", "15s", "30s", "1m", "None"]
        )
    }

    func testEventDrivenCaptureStorageHeuristicAddsRequestedWindowChangeAndClickOverheads() {
        let windowChangeOnly = SettingsView.eventDrivenCaptureStorageHeuristicGB(
            captureOnWindowChange: true,
            captureOnMouseClick: false
        )
        XCTAssertEqual(windowChangeOnly.lowGB, 0.5, accuracy: 0.0001)
        XCTAssertEqual(windowChangeOnly.highGB, 2.0, accuracy: 0.0001)

        let mouseClickOnly = SettingsView.eventDrivenCaptureStorageHeuristicGB(
            captureOnWindowChange: false,
            captureOnMouseClick: true
        )
        XCTAssertEqual(mouseClickOnly.lowGB, 0.25, accuracy: 0.0001)
        XCTAssertEqual(mouseClickOnly.highGB, 1.0, accuracy: 0.0001)
    }

    func testCaptureStorageEstimateIncludesEventDrivenHeuristicsWhenIntervalIsOff() {
        XCTAssertEqual(
            SettingsView.captureStorageEstimateText(
                videoQuality: 0.5,
                captureIntervalSeconds: 0,
                captureOnWindowChange: true,
                captureOnMouseClick: true
            ),
            "Estimated: ~0.8-3.0 GB per month"
        )
    }

    func testCaptureStorageEstimateAddsEventDrivenHeuristicsOnTopOfTimerEstimate() {
        XCTAssertEqual(
            SettingsView.captureStorageEstimateText(
                videoQuality: 0.5,
                captureIntervalSeconds: 2,
                captureOnWindowChange: true,
                captureOnMouseClick: true
            ),
            "Estimated: ~6.8-17.0 GB per month"
        )
    }

    func testCaptureStorageEstimateClampsOutOfRangeVideoQuality() {
        XCTAssertEqual(
            SettingsView.captureStorageEstimateText(
                videoQuality: -5,
                captureIntervalSeconds: 2,
                captureOnWindowChange: false,
                captureOnMouseClick: false
            ),
            SettingsView.captureStorageEstimateText(
                videoQuality: 0,
                captureIntervalSeconds: 2,
                captureOnWindowChange: false,
                captureOnMouseClick: false
            )
        )
        XCTAssertEqual(
            SettingsView.captureStorageEstimateText(
                videoQuality: 5,
                captureIntervalSeconds: 2,
                captureOnWindowChange: false,
                captureOnMouseClick: false
            ),
            SettingsView.captureStorageEstimateText(
                videoQuality: 1,
                captureIntervalSeconds: 2,
                captureOnWindowChange: false,
                captureOnMouseClick: false
            )
        )
    }

    func testUsesDefaultShortcutReturnsTrueForMatchingDefaultShortcut() {
        XCTAssertTrue(
            SettingsView.usesDefaultShortcut(
                SettingsShortcutKey(from: .defaultTimeline),
                for: .timeline
            )
        )
    }

    func testUsesDefaultShortcutReturnsFalseForEmptyShortcut() {
        XCTAssertFalse(
            SettingsView.usesDefaultShortcut(
                .empty,
                for: .dashboard
            )
        )
    }

    func testUsesDefaultShortcutReturnsFalseForCustomShortcut() {
        XCTAssertFalse(
            SettingsView.usesDefaultShortcut(
                SettingsShortcutKey(key: "K", modifiers: [.command, .shift]),
                for: .comment
            )
        )
    }

    func testCanClearShortcutReturnsFalseForEmptyShortcut() {
        XCTAssertFalse(SettingsView.canClearShortcut(.empty))
    }

    func testCanClearShortcutReturnsTrueForAssignedShortcut() {
        XCTAssertTrue(
            SettingsView.canClearShortcut(
                SettingsShortcutKey(from: .defaultRecording)
            )
        )
    }
}
