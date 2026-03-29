import XCTest
@testable import Retrace

final class OnboardingAutomationTargetTests: XCTestCase {
    func testDirectAutomationPreflightTargetsIncludeVivaldi() {
        XCTAssertTrue(
            OnboardingView.automationDirectPreflightTargetBundleIDs.contains("com.vivaldi.Vivaldi")
        )
    }

    func testDirectAutomationPreflightTargetsExcludeAtlas() {
        XCTAssertTrue(OnboardingView.automationDirectPreflightTargetBundleIDs.contains("com.openai.chat"))
        XCTAssertFalse(OnboardingView.automationDirectPreflightTargetBundleIDs.contains("com.openai.atlas"))
    }

    func testAtlasShowsUnsupportedReasonInOnboardingAndSettings() {
        XCTAssertEqual(
            OnboardingView.unsupportedAutomationReason(for: "com.openai.atlas"),
            "ChatGPT Atlas does not support in-page URL extraction."
        )
        XCTAssertEqual(
            SettingsView.inPageURLUnsupportedReason(for: "com.openai.atlas"),
            "ChatGPT Atlas does not support in-page URL extraction."
        )
    }

    func testAtlasIsNotASupportedDirectInPageBrowser() {
        XCTAssertFalse(SettingsView.isSupportedDirectInPageURLBrowserBundleID("com.openai.atlas"))
    }
}
