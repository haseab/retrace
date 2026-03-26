import XCTest
import AppKit
import Combine
import Shared
import App
@testable import Retrace

@MainActor
final class DeveloperFrameIDToggleTests: XCTestCase {
    func testToggleFrameIDBadgeVisibilityFromDevMenuPersistsShowFrameIDsSetting() {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        let originalValue = defaults.object(forKey: "showFrameIDs")
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: "showFrameIDs")
            } else {
                defaults.removeObject(forKey: "showFrameIDs")
            }
        }

        defaults.set(false, forKey: "showFrameIDs")

        let viewModel = SimpleTimelineViewModel(coordinator: AppCoordinator())

        viewModel.toggleFrameIDBadgeVisibilityFromDevMenu()
        XCTAssertTrue(defaults.bool(forKey: "showFrameIDs"))
        XCTAssertTrue(viewModel.showFrameIDs)

        viewModel.toggleFrameIDBadgeVisibilityFromDevMenu()
        XCTAssertFalse(defaults.bool(forKey: "showFrameIDs"))
        XCTAssertFalse(viewModel.showFrameIDs)
    }
}
