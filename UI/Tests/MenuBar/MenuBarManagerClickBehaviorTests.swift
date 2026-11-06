import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

final class MenuBarManagerClickBehaviorTests: XCTestCase {
    @MainActor
    func testFaceBlurConsentPanelUsesStandaloneHeaderDragConfiguration() {
        let panel = MenuBarManager.makeFaceBlurConsentPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320)
        )

        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(panel.level, .modalPanel)
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertEqual(panel.sharingType, .readOnly)
        XCTAssertTrue(panel.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))

        panel.close()
    }

    func testConferenceConsentMenuItemTitleUsesDisabledStatusCopyWithTruncation() {
        let disabledState = ConferenceConsentMenuState(
            callID: "call-1",
            title: "Meet - this-is-a-very-long-conference-window-title",
            lastObservedAt: Date(),
            isBlurBypassedForConsent: true
        )

        XCTAssertEqual(
            MenuBarManager.conferenceConsentMenuItemTitle(
                for: disabledState,
                truncatedTitleLimit: 18
            ),
            "Blurring is disabled for 'Meet - this-is-a-…'"
        )

        let activeState = ConferenceConsentMenuState(
            callID: "call-2",
            title: "Meet - active",
            lastObservedAt: Date(),
            isBlurBypassedForConsent: false
        )
        XCTAssertEqual(
            MenuBarManager.conferenceConsentMenuItemTitle(for: activeState),
            "Disable Face Blurring This Call"
        )
    }

    func testLeftMouseDownOpensStatusMenu() {
        XCTAssertTrue(MenuBarManager.shouldOpenStatusMenu(for: .leftMouseDown))
    }

    func testLeftClickOpensStatusMenu() {
        XCTAssertTrue(MenuBarManager.shouldOpenStatusMenu(for: .leftMouseUp))
    }

    func testRightMouseDownOpensStatusMenu() {
        XCTAssertTrue(MenuBarManager.shouldOpenStatusMenu(for: .rightMouseDown))
    }

    func testRightClickOpensStatusMenu() {
        XCTAssertTrue(MenuBarManager.shouldOpenStatusMenu(for: .rightMouseUp))
    }

    func testUnrelatedEventDoesNotOpenStatusMenu() {
        XCTAssertFalse(MenuBarManager.shouldOpenStatusMenu(for: .keyDown))
    }

    func testMissingEventDefaultsToOpenStatusMenu() {
        XCTAssertTrue(MenuBarManager.shouldOpenStatusMenu(for: nil))
    }

    func testPrimaryActionsPlaceSearchDirectlyUnderTimeline() {
        let actions = MenuBarManager.primaryActions(
            isDashboardFrontAndCenter: false,
            isSystemMonitorFrontAndCenter: false
        )

        XCTAssertEqual(actions.timeline.title, "Open Timeline")
        XCTAssertEqual(actions.search.title, "Search Screen History")
        XCTAssertEqual(actions.dashboard.title, "Open Dashboard")
        XCTAssertEqual(actions.monitor.title, "Open System Monitor")
        XCTAssertEqual(actions.search.imageSystemName, "magnifyingglass")
    }

    func testCaptureFeedbackEventDecisionMatrix() {
        struct TestCase {
            let isRunning: Bool
            let settingEnabled: Bool
            let shouldHideRecordingIndicator: Bool
            let isAnimationInFlight: Bool
            let expectedImmediateAnimation: Bool
            let expectedReplayQueue: Bool
        }

        let cases = [
            TestCase(
                isRunning: true,
                settingEnabled: true,
                shouldHideRecordingIndicator: false,
                isAnimationInFlight: false,
                expectedImmediateAnimation: true,
                expectedReplayQueue: false
            ),
            TestCase(
                isRunning: true,
                settingEnabled: true,
                shouldHideRecordingIndicator: false,
                isAnimationInFlight: true,
                expectedImmediateAnimation: false,
                expectedReplayQueue: true
            ),
            TestCase(
                isRunning: true,
                settingEnabled: true,
                shouldHideRecordingIndicator: true,
                isAnimationInFlight: false,
                expectedImmediateAnimation: false,
                expectedReplayQueue: false
            )
        ]

        for testCase in cases {
            let decision = MenuBarManager.captureFeedbackEventDecision(
                isRunning: testCase.isRunning,
                settingEnabled: testCase.settingEnabled,
                shouldHideRecordingIndicator: testCase.shouldHideRecordingIndicator,
                isAnimationInFlight: testCase.isAnimationInFlight
            )

            XCTAssertEqual(decision.shouldAnimateImmediately, testCase.expectedImmediateAnimation)
            XCTAssertEqual(decision.shouldQueueReplay, testCase.expectedReplayQueue)
        }
    }

    func testQueuedCapturePulseReplayMatrix() {
        struct TestCase {
            let hasQueuedReplay: Bool
            let isRunning: Bool
            let settingEnabled: Bool
            let shouldHideRecordingIndicator: Bool
            let expectedReplay: Bool
        }

        let cases = [
            TestCase(
                hasQueuedReplay: true,
                isRunning: true,
                settingEnabled: true,
                shouldHideRecordingIndicator: false,
                expectedReplay: true
            ),
            TestCase(
                hasQueuedReplay: true,
                isRunning: true,
                settingEnabled: false,
                shouldHideRecordingIndicator: false,
                expectedReplay: false
            )
        ]

        for testCase in cases {
            XCTAssertEqual(
                MenuBarManager.shouldReplayQueuedCapturePulse(
                    hasQueuedReplay: testCase.hasQueuedReplay,
                    isRunning: testCase.isRunning,
                    settingEnabled: testCase.settingEnabled,
                    shouldHideRecordingIndicator: testCase.shouldHideRecordingIndicator
                ),
                testCase.expectedReplay
            )
        }
    }

}
