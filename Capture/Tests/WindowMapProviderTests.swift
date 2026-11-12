import CoreGraphics
import XCTest
import Shared
@testable import Capture

final class WindowMapProviderTests: XCTestCase {

    private let display = CGRect(x: 0, y: 0, width: 1000, height: 500)
    private let retinaFrame = CGSize(width: 2000, height: 1000)

    private func entry(
        _ id: CGWindowID,
        pid: pid_t? = 100,
        title: String? = "Window",
        bounds: CGRect,
        layer: Int = 0,
        alpha: Double = 1
    ) -> WindowMapProvider.WindowEntry {
        WindowMapProvider.WindowEntry(
            windowID: id,
            ownerPID: pid,
            ownerName: "App\(pid ?? 0)",
            title: title,
            bounds: bounds,
            layer: layer,
            alpha: alpha
        )
    }

    private func build(
        _ entries: [WindowMapProvider.WindowEntry],
        display: CGRect? = nil,
        excluded: Set<CGWindowID> = [],
        redacted: Set<CGWindowID> = [],
        frontmostPID: pid_t? = 100
    ) -> [CapturedWindow] {
        WindowMapProvider.build(
            entries: entries,
            displayBounds: display ?? self.display,
            frameSize: retinaFrame,
            excludedWindowIDs: excluded,
            redactedWindowIDs: redacted,
            frontmostPID: frontmostPID,
            bundleIDForPID: { "bundle.\($0)" }
        )
    }

    func testScalesPointsToFramePixelsAndKeepsStackingOrder() {
        let windows = build([
            entry(1, bounds: CGRect(x: 10, y: 20, width: 300, height: 200)),
            entry(2, pid: 200, bounds: CGRect(x: 400, y: 0, width: 600, height: 500))
        ])

        XCTAssertEqual(windows.map(\.windowID), [1, 2])
        XCTAssertEqual(windows.map(\.zOrder), [0, 1])
        XCTAssertEqual(windows[0].bounds, CGRect(x: 20, y: 40, width: 600, height: 400))
        XCTAssertEqual(windows[1].bounds, CGRect(x: 800, y: 0, width: 1200, height: 1000))
        XCTAssertEqual(windows[1].bundleID, "bundle.200")
    }

    func testConvertsSecondaryDisplayCoordinatesAndClipsToFrame() {
        let secondary = CGRect(x: 1000, y: -200, width: 1000, height: 500)
        let windows = build(
            [entry(1, bounds: CGRect(x: 900, y: -250, width: 300, height: 200))],
            display: secondary
        )

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].bounds, CGRect(x: 0, y: 0, width: 400, height: 300))
    }

    func testDropsExcludedTransparentOffscreenAndTinyWindows() {
        let windows = build(
            [
                entry(1, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
                entry(2, bounds: CGRect(x: 200, y: 0, width: 100, height: 100), alpha: 0),
                entry(3, bounds: CGRect(x: 2000, y: 0, width: 100, height: 100)),
                entry(4, bounds: CGRect(x: 0, y: 300, width: 1, height: 1)),
                entry(5, bounds: CGRect(x: 600, y: 0, width: 100, height: 100))
            ],
            excluded: [5]
        )

        XCTAssertEqual(windows.map(\.windowID), [1])
    }

    func testDropsWindowsFullyCoveredByAnOpaqueWindowInFront() {
        let windows = build([
            entry(1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 500)),
            entry(2, pid: 200, bounds: CGRect(x: 100, y: 100, width: 200, height: 200)),
            entry(3, pid: 300, bounds: CGRect(x: 100, y: 100, width: 200, height: 200), alpha: 0.5)
        ])

        XCTAssertEqual(windows.map(\.windowID), [1])
    }

    func testTranslucentWindowDoesNotHideWindowsBehindIt() {
        let windows = build([
            entry(1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 500), alpha: 0.5),
            entry(2, pid: 200, bounds: CGRect(x: 100, y: 100, width: 200, height: 200))
        ])

        XCTAssertEqual(windows.map(\.windowID), [1, 2])
    }

    /// Dock and Notification Center are screen-sized windows above layer 0 that report
    /// alpha 1. They must neither appear in the map nor hide the app windows below them.
    func testFullScreenSystemOverlaysAreDroppedAndDoNotHideAppWindows() {
        let windows = build([
            entry(1, pid: 900, bounds: CGRect(x: 0, y: 0, width: 1000, height: 500), layer: 21),
            entry(2, pid: 901, bounds: CGRect(x: 0, y: 0, width: 1000, height: 500), layer: 20),
            entry(3, pid: 902, bounds: CGRect(x: 0, y: 0, width: 1000, height: 15), layer: 24),
            entry(4, pid: 100, bounds: CGRect(x: 0, y: 20, width: 400, height: 300))
        ])

        XCTAssertEqual(windows.map(\.windowID), [3, 4])
    }

    func testSmallNonNormalLayerWindowDoesNotHideWindowBehindIt() {
        let windows = build([
            entry(1, pid: 900, bounds: CGRect(x: 0, y: 0, width: 500, height: 400), layer: 8),
            entry(2, pid: 100, bounds: CGRect(x: 100, y: 100, width: 200, height: 200))
        ])

        XCTAssertEqual(windows.map(\.windowID), [1, 2])
    }

    func testRedactedWindowKeepsBoundsButLosesTitle() {
        // Capture puts redacted windows in both the excluded and redacted sets.
        let windows = build(
            [entry(1, title: "Secret", bounds: CGRect(x: 0, y: 0, width: 100, height: 100))],
            excluded: [1],
            redacted: [1]
        )

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].bounds, CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertNil(windows[0].title)
    }

    func testFocusedIsTopmostNormalLayerWindowOfFrontmostApp() {
        let windows = build(
            [
                entry(1, pid: 100, bounds: CGRect(x: 0, y: 0, width: 1000, height: 20), layer: 25),
                entry(2, pid: 200, bounds: CGRect(x: 0, y: 30, width: 200, height: 200)),
                entry(3, pid: 100, bounds: CGRect(x: 300, y: 30, width: 200, height: 200)),
                entry(4, pid: 100, bounds: CGRect(x: 600, y: 30, width: 200, height: 200))
            ],
            frontmostPID: 100
        )

        XCTAssertEqual(windows.filter(\.isFocused).map(\.windowID), [3])
    }

    func testFullScreenToolbarStripIsNotTheFocusedWindow() {
        // A full-screen AppKit window has an untitled toolbar window stacked above it.
        let windows = build(
            [
                entry(1, pid: 100, title: nil, bounds: CGRect(x: 0, y: 0, width: 1000, height: 45)),
                entry(2, pid: 100, title: "solo.rtf", bounds: CGRect(x: 0, y: 0, width: 1000, height: 500))
            ],
            frontmostPID: 100
        )

        XCTAssertEqual(windows.filter(\.isFocused).map(\.windowID), [2])
    }

    func testUntitledWindowIsFocusedWhenFrontmostAppHasNoTitledWindow() {
        let windows = build(
            [
                entry(1, pid: 100, title: nil, bounds: CGRect(x: 0, y: 0, width: 300, height: 300)),
                entry(2, pid: 100, title: "", bounds: CGRect(x: 400, y: 0, width: 300, height: 300))
            ],
            frontmostPID: 100
        )

        XCTAssertEqual(windows.filter(\.isFocused).map(\.windowID), [1])
    }

    func testRedactedFrontWindowKeepsFocus() {
        let windows = build(
            [
                entry(1, pid: 100, title: "Secret", bounds: CGRect(x: 0, y: 0, width: 300, height: 300)),
                entry(2, pid: 100, title: "Notes", bounds: CGRect(x: 400, y: 0, width: 300, height: 300))
            ],
            excluded: [1],
            redacted: [1],
            frontmostPID: 100
        )

        XCTAssertEqual(windows.filter(\.isFocused).map(\.windowID), [1])
    }

    func testOwningWindowUsesFrontmostWindowAtRegionCenter() {
        let windows = build([
            entry(1, bounds: CGRect(x: 0, y: 0, width: 300, height: 300)),
            entry(2, pid: 200, bounds: CGRect(x: 0, y: 0, width: 1000, height: 500), alpha: 0.9)
        ])

        XCTAssertEqual(WindowMap.owningWindowIndex(for: CGRect(x: 100, y: 100, width: 50, height: 10), in: windows), 0)
        XCTAssertEqual(WindowMap.owningWindowIndex(for: CGRect(x: 900, y: 100, width: 50, height: 10), in: windows), 1)
        XCTAssertNil(WindowMap.owningWindowIndex(for: CGRect(x: 2500, y: 100, width: 50, height: 10), in: windows))
    }
}
