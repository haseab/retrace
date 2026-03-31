import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class LaunchMenuRoutingTests: XCTestCase {
    func testDashboardTitleMapsToDashboardContent() {
        XCTAssertEqual(LaunchMenuRouting.content(forDashboardWindowTitle: "Dashboard"), .dashboard)
    }

    func testSettingsTitleMapsToSettingsContent() {
        XCTAssertEqual(LaunchMenuRouting.content(forDashboardWindowTitle: "Settings - General"), .settings)
    }

    func testChangelogTitleMapsToChangelogContent() {
        XCTAssertEqual(LaunchMenuRouting.content(forDashboardWindowTitle: "Changelog"), .changelog)
    }

    func testSystemMonitorTitleMapsToMonitorContent() {
        XCTAssertEqual(LaunchMenuRouting.content(forDashboardWindowTitle: "System Monitor"), .monitor)
    }
}
