import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

final class DashboardWindowTitleFormatterTests: XCTestCase {
    func testSupportedBrowserBreakdownTreatsCometAsBrowser() {
        let app = AppUsageData(
            appBundleID: "ai.perplexity.comet",
            appName: "Comet",
            duration: 120,
            uniqueItemCount: 2,
            percentage: 0.25
        )

        XCTAssertTrue(app.isBrowser)
        XCTAssertEqual(app.uniqueItemLabel, "2 websites")
    }

    func testSupportedBrowserBreakdownTreatsChromeCanaryAsBrowser() {
        let app = AppUsageData(
            appBundleID: "com.google.Chrome.canary",
            appName: "Chrome Canary",
            duration: 120,
            uniqueItemCount: 1,
            percentage: 0.25
        )

        XCTAssertTrue(app.isBrowser)
        XCTAssertEqual(app.uniqueItemLabel, "1 website")
    }

    func testStripsWebPrefixForChromePWAAppShimBundle() {
        let result = DashboardWindowTitleFormatter.displayTitle(
            for: "ChatGPT Web - New Chat",
            appBundleID: "com.google.Chrome.app.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )

        XCTAssertEqual(result, "New Chat")
    }

    func testStripsUnreadBadgeAfterWebPrefix() {
        let result = DashboardWindowTitleFormatter.displayTitle(
            for: "Notion Web - (4) Project Roadmap",
            appBundleID: "com.google.Chrome.app.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )

        XCTAssertEqual(result, "Project Roadmap")
    }

    func testStripsDomainPrefixForChromePWAAppShimBundle() {
        let result = DashboardWindowTitleFormatter.displayTitle(
            for: "timetracking.live - Weekly Report",
            appBundleID: "com.google.Chrome.app.cccccccccccccccccccccccccccccccc"
        )

        XCTAssertEqual(result, "Weekly Report")
    }

    func testKeepsRegularChromeTabTitlesUntouched() {
        let result = DashboardWindowTitleFormatter.displayTitle(
            for: "Feature request - GitHub",
            appBundleID: "com.google.Chrome"
        )

        XCTAssertEqual(result, "Feature request - GitHub")
    }

    func testKeepsNonChromeTitlesUntouched() {
        let result = DashboardWindowTitleFormatter.displayTitle(
            for: "Terminal - zsh",
            appBundleID: "com.apple.Terminal"
        )

        XCTAssertEqual(result, "Terminal - zsh")
    }
}
