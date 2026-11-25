import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

final class DashboardWindowTitleFormatterTests: XCTestCase {
    func testPrefixGroupsAggregateEveryWindowAndPreserveOriginalTargets() {
        let windows = [
            WindowUsageData(windowName: "Workspace - Plan - Draft", duration: 30, percentage: 0.3),
            WindowUsageData(windowName: "Workspace - Review", duration: 20, percentage: 0.2),
            WindowUsageData(windowName: "Workspace", duration: 10, percentage: 0.1),
            WindowUsageData(windowName: "Music", duration: 40, percentage: 0.4)
        ]
        let groups = DashboardWindowGrouping.groups(windows, appBundleID: "com.example.workspace")
        XCTAssertEqual(groups.map(\.title), ["Workspace", "Music"])
        XCTAssertEqual(groups.map(\.duration), [60, 40])
        XCTAssertEqual(groups[0].percentage, 0.6, accuracy: 0.0001)
        XCTAssertEqual(groups[0].windows.map(\.id), Array(windows.prefix(3)).map(\.id))
        XCTAssertEqual(groups.flatMap(\.windows).count, windows.count)
    }

    func testPlainTitlesStayLeafRowsWhileHyphenPrefixesExpand() {
        let windows = [
            WindowUsageData(windowName: "Workspace - Plan", duration: 20, percentage: 0.5),
            WindowUsageData(windowName: "Music", duration: 20, percentage: 0.5)
        ]
        let groups = DashboardWindowGrouping.groups(windows, appBundleID: "com.example.workspace")
        XCTAssertTrue(groups.first { $0.title == "Workspace" }!.isExpandable)
        XCTAssertFalse(groups.first { $0.title == "Music" }!.isExpandable)
    }

    func testPrefixUsesOnlyFirstSpacedHyphenAndPreservesOtherHyphens() {
        let titles = ["  Work - Detail - More  ", "check-in", " - Detail", "Work - ", "", "Music"]
        XCTAssertEqual(titles.map(DashboardWindowGrouping.prefix),
                       ["Work", "check-in", "- Detail", "Work -", "Untitled Window", "Music"])
    }

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
