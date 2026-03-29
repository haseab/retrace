import XCTest
@testable import Retrace

final class InPageURLSettingsTests: XCTestCase {
    func testUnsupportedInPageURLReasonsIncludeDuckDuckGoAndSigmaOS() {
        XCTAssertEqual(
            SettingsView.inPageURLUnsupportedReason(for: "com.duckduckgo.macos.browser"),
            "DuckDuckGo does not support in-page URL extraction."
        )
        XCTAssertEqual(
            SettingsView.inPageURLUnsupportedReason(for: "com.sigmaos.sigmaos.macos"),
            "SigmaOS does not support in-page URL extraction."
        )
    }

    func testSigmaOSIsNotASupportedDirectInPageBrowserAndVivaldiIs() {
        XCTAssertFalse(SettingsView.isSupportedDirectInPageURLBrowserBundleID("com.sigmaos.sigmaos.macos"))
        XCTAssertTrue(SettingsView.isSupportedDirectInPageURLBrowserBundleID("com.vivaldi.Vivaldi"))
    }

    func testPrivateModeAutomationTargetsIncludeVivaldiAndSigmaOS() {
        let bundleIDs = SettingsView.privateModeAutomationRequiredBundleIDs
        XCTAssertTrue(bundleIDs.contains("com.vivaldi.Vivaldi"))
        XCTAssertTrue(bundleIDs.contains("com.sigmaos.sigmaos.macos"))
    }

    func testPrivateModeAXCompatibleTargetsIncludeFirefoxFamily() {
        let bundleIDs = SettingsView.privateModeAXCompatibleBundleIDs
        XCTAssertTrue(bundleIDs.contains("org.mozilla.firefox"))
        XCTAssertTrue(bundleIDs.contains("org.mozilla.firefoxbeta"))
        XCTAssertTrue(bundleIDs.contains("org.mozilla.firefoxdeveloperedition"))
        XCTAssertTrue(bundleIDs.contains("org.mozilla.nightly"))
    }
}
