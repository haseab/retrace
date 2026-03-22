import AppKit
import XCTest
@testable import Retrace

@MainActor
final class QuitConfirmationPresentationTests: XCTestCase {
    func testPreferredQuitConfirmationAnchorWindowPrefersVisibleKeyWindow() {
        let keyWindow = StubQuitConfirmationWindow(isVisible: true)
        let mainWindow = StubQuitConfirmationWindow(isVisible: true)

        let anchor = AppDelegate.preferredQuitConfirmationAnchorWindow(
            keyWindow: keyWindow,
            mainWindow: mainWindow
        )

        XCTAssertTrue(anchor === keyWindow)
    }

    func testPreferredQuitConfirmationAnchorWindowFallsBackToVisibleMainWindow() {
        let hiddenKeyWindow = StubQuitConfirmationWindow(isVisible: false)
        let mainWindow = StubQuitConfirmationWindow(isVisible: true)

        let anchor = AppDelegate.preferredQuitConfirmationAnchorWindow(
            keyWindow: hiddenKeyWindow,
            mainWindow: mainWindow
        )

        XCTAssertTrue(anchor === mainWindow)
    }

    func testPreferredQuitConfirmationAnchorWindowRejectsMiniaturizedWindow() {
        let miniaturizedWindow = StubQuitConfirmationWindow(isVisible: true, isMiniaturized: true)

        let anchor = AppDelegate.preferredQuitConfirmationAnchorWindow(
            keyWindow: nil,
            mainWindow: miniaturizedWindow
        )

        XCTAssertNil(anchor)
    }
}

private final class StubQuitConfirmationWindow: NSWindow {
    private let stubVisible: Bool
    private let stubMiniaturized: Bool

    init(isVisible: Bool, isMiniaturized: Bool = false) {
        self.stubVisible = isVisible
        self.stubMiniaturized = isMiniaturized
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    override var isVisible: Bool {
        stubVisible
    }

    override var isMiniaturized: Bool {
        stubMiniaturized
    }
}
