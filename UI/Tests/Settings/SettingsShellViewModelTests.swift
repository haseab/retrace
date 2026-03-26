import XCTest
@testable import Retrace

@MainActor
final class SettingsShellViewModelTests: XCTestCase {
    func testInitializerHonorsInitialTabAndScrollTarget() {
        let viewModel = SettingsShellViewModel(
            initialTab: .power,
            initialScrollTargetID: "settings.powerOCRCard"
        )

        XCTAssertEqual(viewModel.selectedTab, .power)
        XCTAssertEqual(viewModel.pendingScrollTargetID, "settings.powerOCRCard")
    }

    func testSearchResultsMatchKeywordsAndTitles() {
        let ocrResults = SettingsShellViewModel.searchResults(for: "ocr")
        let shortcutResults = SettingsShellViewModel.searchResults(for: "shortcut")

        XCTAssertTrue(ocrResults.contains(where: { $0.id == "power.ocrProcessing" }))
        XCTAssertTrue(shortcutResults.contains(where: { $0.id == "general.shortcuts" }))
    }

    func testScheduleSettingsSearchResetClearsQueryAfterDelay() async {
        let viewModel = SettingsShellViewModel()
        viewModel.settingsSearchQuery = "privacy"

        viewModel.scheduleSettingsSearchReset()
        try? await Task.sleep(for: .nanoseconds(Int64(250_000_000)), clock: .continuous)

        XCTAssertEqual(viewModel.settingsSearchQuery, "")
    }

    func testCancelSettingsSearchResetKeepsQuery() async {
        let viewModel = SettingsShellViewModel()
        viewModel.settingsSearchQuery = "power"

        viewModel.scheduleSettingsSearchReset()
        viewModel.cancelSettingsSearchReset()
        try? await Task.sleep(for: .nanoseconds(Int64(250_000_000)), clock: .continuous)

        XCTAssertEqual(viewModel.settingsSearchQuery, "power")
    }
}
