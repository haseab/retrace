import XCTest
import CoreGraphics
@testable import Capture

final class WindowOCRGeometryTests: XCTestCase {
    private func window(_ id: UInt32, _ bounds: CGRect, layer: Int = 0) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowBounds as String: bounds.dictionaryRepresentation,
         kCGWindowLayer as String: layer, kCGWindowAlpha as String: 1.0,
         kCGWindowIsOnscreen as String: true]
    }

    func testFullscreenApplicationIsOneCropDespiteStatusItemsAndCoveredWindows() throws {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let items = (0..<24).map { window(UInt32(100 + $0),
            CGRect(x: 600 + $0 * 50, y: 0, width: 50, height: 22), layer: 25) }
        let regions = try XCTUnwrap(WindowOCRGeometry.normalizedRegions(
            windows: items + [window(1, screen), window(2, screen),
                             window(3, CGRect(x: 200, y: 200, width: 800, height: 600))],
            displayBounds: screen, imageSize: screen.size, excludedWindowIDs: []))
        XCTAssertEqual(regions, [CGRect(x: 0, y: 0, width: 1, height: 1)])
    }

    func testOverlappingWindowsKeepOneFullBoundsCropEachAndNoBackgroundFragments() throws {
        let display = CGRect(x: -100, y: 50, width: 600, height: 400)
        let front = CGRect(x: 100, y: 150, width: 200, height: 100)
        let regions = try XCTUnwrap(WindowOCRGeometry.normalizedRegions(
            windows: [window(1, front), window(2, display)], displayBounds: display,
            imageSize: CGSize(width: 1200, height: 800), excludedWindowIDs: []))
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0], CGRect(x: 1.0 / 3, y: 0.25, width: 1.0 / 3, height: 0.25))
        XCTAssertEqual(regions[1], CGRect(x: 0, y: 0, width: 1, height: 1))
        let onlyFront = try XCTUnwrap(WindowOCRGeometry.normalizedRegions(
            windows: [window(1, front)], displayBounds: display,
            imageSize: display.size, excludedWindowIDs: []))
        XCTAssertEqual(onlyFront.count, 1, "Uncovered desktop must not create more OCR jobs")
    }

    func testExcludedAndAlmostEntirelyCoveredWindowsAreNotSelected() throws {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let regions = try XCTUnwrap(WindowOCRGeometry.normalizedRegions(
            windows: [window(1, CGRect(x: 0, y: 0, width: 1918, height: 1080)), window(2, screen)],
            displayBounds: screen, imageSize: screen.size, excludedWindowIDs: []))
        XCTAssertEqual(regions.count, 1, "A two-pixel sliver is not another useful window")
        let excluded = try XCTUnwrap(WindowOCRGeometry.normalizedRegions(
            windows: [window(1, screen), window(2, screen)], displayBounds: screen,
            imageSize: screen.size, excludedWindowIDs: [1]))
        XCTAssertEqual(excluded, [])
    }

    func testIgnoredUtilitySurfaceDoesNotOccludeRealApplicationWindows() throws {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windows = [window(90, screen),
                       window(1, CGRect(x: 0, y: 30, width: 960, height: 1050)),
                       window(2, CGRect(x: 960, y: 30, width: 960, height: 1050))]
        let regions = try XCTUnwrap(WindowOCRGeometry.normalizedRegions(
            windows: windows, displayBounds: screen, imageSize: screen.size,
            excludedWindowIDs: [], ignoredWindowIDs: [90]))
        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions.map(\.width), [0.5, 0.5])
        let excluded = try XCTUnwrap(WindowOCRGeometry.normalizedRegions(
            windows: windows, displayBounds: screen, imageSize: screen.size,
            excludedWindowIDs: [90], ignoredWindowIDs: [90]))
        XCTAssertEqual(excluded, [], "Privacy exclusions must still block even an ignored utility surface")
    }

    func testSystemOverlaysNeverBecomeApplicationCrops() throws {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let regions = try XCTUnwrap(WindowOCRGeometry.normalizedRegions(
            windows: [window(10, screen, layer: 100),
                      window(11, CGRect(x: 50, y: 50, width: 300, height: 200), layer: 3),
                      window(1, screen)], displayBounds: screen, imageSize: screen.size,
            excludedWindowIDs: []))
        XCTAssertEqual(regions, [CGRect(x: 0, y: 0, width: 1, height: 1)])
    }
}
