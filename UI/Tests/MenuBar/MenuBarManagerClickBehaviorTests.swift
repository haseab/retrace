import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

final class MenuBarManagerClickBehaviorTests: XCTestCase {
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
