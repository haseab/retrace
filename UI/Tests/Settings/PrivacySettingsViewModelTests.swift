import XCTest
@testable import Retrace

final class PrivacySettingsViewModelTests: XCTestCase {
    func testDecodeExcludedAppsReturnsEmptyArrayForInvalidJSON() {
        XCTAssertEqual(
            PrivacySettingsViewModel.decodeExcludedApps(from: "{not-json}"),
            []
        )
    }

    func testEncodeAndDecodeExcludedAppsRoundTrip() {
        let apps = [
            ExcludedAppInfo(bundleID: "com.apple.Safari", name: "Safari", iconPath: "/Applications/Safari.app"),
            ExcludedAppInfo(bundleID: "com.google.Chrome", name: "Chrome", iconPath: nil)
        ]

        let encoded = PrivacySettingsViewModel.encodeExcludedApps(apps)
        let decoded = PrivacySettingsViewModel.decodeExcludedApps(from: encoded)

        XCTAssertEqual(decoded, apps)
    }
}
