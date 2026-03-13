import XCTest
@testable import Retrace

final class InPageURLSettingsTests: XCTestCase {
    func testUnsupportedInPageURLReasonsIncludeDuckDuckGoAndSigmaOS() {
        XCTAssertEqual(
            SettingsView.inPageURLUnsupportedReason(for: "com.duckduckgo.macos.browser"),
            "DuckDuckGo does not support in-page URL extraction in Retrace."
        )
        XCTAssertEqual(
            SettingsView.inPageURLUnsupportedReason(for: "com.sigmaos.sigmaos.macos"),
            "SigmaOS does not support in-page URL extraction in Retrace."
        )
    }

    func testSigmaOSIsNotASupportedDirectInPageBrowserAndVivaldiIs() {
        XCTAssertFalse(SettingsView.isSupportedDirectInPageURLBrowserBundleID("com.sigmaos.sigmaos.macos"))
        XCTAssertTrue(SettingsView.isSupportedDirectInPageURLBrowserBundleID("com.vivaldi.Vivaldi"))
    }
}
