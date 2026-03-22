import App
import Shared
import XCTest
@testable import Retrace

@MainActor
final class SearchViewModelAvailableAppsTests: XCTestCase {
    func testAvailableAppsDeduplicatesDuplicateBundleIDsAndPrefersInstalledEntries() {
        let viewModel = SearchViewModel(coordinator: AppCoordinator())
        viewModel.installedApps = [
            AppInfo(bundleID: "com.apple.Safari", name: "Safari"),
            AppInfo(bundleID: "com.google.Chrome", name: "Chrome")
        ]
        viewModel.otherApps = [
            AppInfo(bundleID: "com.apple.Safari", name: "Safari (DB)"),
            AppInfo(bundleID: "com.microsoft.edgemac", name: "Edge")
        ]

        XCTAssertEqual(
            viewModel.availableApps.map(\.bundleID),
            ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac"]
        )
        XCTAssertEqual(
            viewModel.availableApps.first(where: { $0.bundleID == "com.apple.Safari" })?.name,
            "Safari"
        )
    }
}
