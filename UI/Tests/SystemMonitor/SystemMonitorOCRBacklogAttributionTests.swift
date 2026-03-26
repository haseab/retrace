import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class SystemMonitorOCRBacklogAttributionTests: XCTestCase {
    func testOCRBacklogAttributionShowsWhenOCRIsActivelyProcessing() {
        let viewModel = SystemMonitorViewModel(coordinator: AppCoordinator())
        viewModel.ocrEnabled = true
        viewModel.isPausedForBattery = false
        viewModel.ocrQueueDepth = 1
        viewModel.ocrProcessingCount = 2

        XCTAssertTrue(viewModel.shouldShowOCRBacklogAttribution)
    }

    func testOCRBacklogAttributionShowsEvenWithNoBacklogWhenOCRIsActivelyProcessing() {
        let viewModel = SystemMonitorViewModel(coordinator: AppCoordinator())
        viewModel.ocrEnabled = true
        viewModel.isPausedForBattery = false
        viewModel.ocrQueueDepth = 0
        viewModel.ocrProcessingCount = 1

        XCTAssertTrue(viewModel.shouldShowOCRBacklogAttribution)
    }

    func testOCRBacklogAttributionHiddenWhenOCRIsNotActivelyProcessing() {
        let viewModel = SystemMonitorViewModel(coordinator: AppCoordinator())
        viewModel.ocrEnabled = true
        viewModel.isPausedForBattery = false
        viewModel.ocrQueueDepth = 24
        viewModel.ocrProcessingCount = 0

        XCTAssertFalse(viewModel.shouldShowOCRBacklogAttribution)
    }

    func testOCRBacklogAttributionHiddenWhenOnlyRewriteIsActive() {
        let viewModel = SystemMonitorViewModel(coordinator: AppCoordinator())
        viewModel.ocrEnabled = true
        viewModel.isPausedForBattery = false
        viewModel.ocrQueueDepth = 0
        viewModel.ocrProcessingCount = 0
        viewModel.rewriteProcessingCount = 2

        XCTAssertFalse(viewModel.shouldShowOCRBacklogAttribution)
    }
}
