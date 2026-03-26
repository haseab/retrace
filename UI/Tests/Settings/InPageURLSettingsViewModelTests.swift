import XCTest
@testable import Retrace

final class InPageURLSettingsViewModelTests: XCTestCase {
    func testChromiumHostBrowserBundleIDReturnsHostBundleIDForWebApp() {
        let prefixes = ["com.google.Chrome", "company.thebrowser.Browser"]

        XCTAssertEqual(
            InPageURLSettingsViewModel.chromiumHostBrowserBundleID(
                for: "com.google.Chrome.app.12345",
                hostBundleIDPrefixes: prefixes
            ),
            "com.google.Chrome"
        )
    }

    func testChromiumHostBrowserBundleIDReturnsExactHostBundleID() {
        let prefixes = ["com.google.Chrome", "company.thebrowser.Browser"]

        XCTAssertEqual(
            InPageURLSettingsViewModel.chromiumHostBrowserBundleID(
                for: "company.thebrowser.Browser",
                hostBundleIDPrefixes: prefixes
            ),
            "company.thebrowser.Browser"
        )
    }

    func testIsChromiumWebAppBundleIDOnlyMatchesHostedAppPattern() {
        let prefixes = ["com.google.Chrome"]

        XCTAssertTrue(
            InPageURLSettingsViewModel.isChromiumWebAppBundleID(
                "com.google.Chrome.app.12345",
                hostBundleIDPrefixes: prefixes
            )
        )
        XCTAssertFalse(
            InPageURLSettingsViewModel.isChromiumWebAppBundleID(
                "com.google.Chrome",
                hostBundleIDPrefixes: prefixes
            )
        )
    }
}
