import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class SystemMonitorPerformanceNudgeTests: XCTestCase {
    func testPerformanceNudgeShowsForBalancedWithoutPowerLimits() {
        let viewModel = SystemMonitorViewModel(coordinator: AppCoordinator())
        viewModel.ocrEnabled = true
        viewModel.isPausedForBattery = false
        viewModel.ocrQueueDepth = 100
        viewModel.ocrProcessingLevel = 3
        viewModel.pauseOnBatterySetting = false
        viewModel.pauseOnLowPowerModeSetting = false

        XCTAssertTrue(viewModel.shouldShowPerformanceNudge)
    }

    func testPerformanceNudgeHiddenWhenOnlyWhilePluggedInEnabled() {
        let viewModel = SystemMonitorViewModel(coordinator: AppCoordinator())
        viewModel.ocrEnabled = true
        viewModel.isPausedForBattery = false
        viewModel.ocrQueueDepth = 100
        viewModel.ocrProcessingLevel = 3
        viewModel.pauseOnBatterySetting = true
        viewModel.pauseOnLowPowerModeSetting = false

        XCTAssertFalse(viewModel.shouldShowPerformanceNudge)
    }

    func testPerformanceNudgeHiddenWhenLowPowerPauseEnabled() {
        let viewModel = SystemMonitorViewModel(coordinator: AppCoordinator())
        viewModel.ocrEnabled = true
        viewModel.isPausedForBattery = false
        viewModel.ocrQueueDepth = 100
        viewModel.ocrProcessingLevel = 3
        viewModel.pauseOnBatterySetting = false
        viewModel.pauseOnLowPowerModeSetting = true

        XCTAssertFalse(viewModel.shouldShowPerformanceNudge)
    }

    func testPerformanceNudgeHiddenForLightAndEfficiencyModes() {
        for level in [1, 2] {
            let viewModel = SystemMonitorViewModel(coordinator: AppCoordinator())
            viewModel.ocrEnabled = true
            viewModel.isPausedForBattery = false
            viewModel.ocrQueueDepth = 100
            viewModel.ocrProcessingLevel = level
            viewModel.pauseOnBatterySetting = false
            viewModel.pauseOnLowPowerModeSetting = false

            XCTAssertFalse(viewModel.shouldShowPerformanceNudge, "Level \(level) should suppress the nudge")
        }
    }
}
