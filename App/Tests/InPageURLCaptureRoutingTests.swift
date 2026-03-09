import XCTest
@testable import App

final class InPageURLCaptureRoutingTests: XCTestCase {
    func testHostBrowserBundleIDMapsExactChromiumBrowser() {
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "com.google.Chrome"),
            "com.google.Chrome"
        )
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "company.thebrowser.Browser"),
            "company.thebrowser.Browser"
        )
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "company.thebrowser.dia"),
            "company.thebrowser.dia"
        )
    }

    func testHostBrowserBundleIDMapsChromiumAppShimToHostBrowser() {
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "com.google.Chrome.app.cadlkienfkclaiaibeoongdcgmdikeeg"),
            "com.google.Chrome"
        )
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "com.brave.Browser.app.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            "com.brave.Browser"
        )
        XCTAssertEqual(
            AppCoordinator.inPageURLHostBrowserBundleID(for: "company.thebrowser.dia.app.ffffffffffffffffffffffffffffffff"),
            "company.thebrowser.dia"
        )
    }

    func testHostBrowserBundleIDRejectsUnsupportedBundleIDs() {
        XCTAssertNil(AppCoordinator.inPageURLHostBrowserBundleID(for: "com.apple.Safari"))
        XCTAssertNil(AppCoordinator.inPageURLHostBrowserBundleID(for: "com.example.notabrowser"))
    }
}
