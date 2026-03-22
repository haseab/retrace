import Shared
import XCTest
@testable import Retrace

final class SpotlightSearchOverlayRecentEntryAppMapTests: XCTestCase {
    func testRecentEntryAppNameMapDeduplicatesDuplicateBundleIDsWithoutTrapping() {
        let appNameMap = SpotlightSearchOverlay.recentEntryAppNameMap(from: [
            AppInfo(bundleID: "com.apple.Safari", name: "Safari"),
            AppInfo(bundleID: "com.apple.Safari", name: "Safari Copy"),
            AppInfo(bundleID: "com.google.Chrome", name: "Chrome")
        ])

        XCTAssertEqual(appNameMap.count, 2)
        XCTAssertEqual(appNameMap["com.apple.Safari"], "Safari")
        XCTAssertEqual(appNameMap["com.google.Chrome"], "Chrome")
    }
}
